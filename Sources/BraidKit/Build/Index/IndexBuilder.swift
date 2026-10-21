//
//  IndexBuilder.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Builds a provenance index: every document whole from a zero state (eos ‖ partitions joined
//        by the break ‖ eos), in state-carrying segments whose boundaries are the checkpoint
//        positions (DocumentSegments). Each segment is run through the trunk at most 1,024 tokens at
//        a time, scored by the reed against the next token, keyed, and recorded (DocumentEntries);
//        the state after it is saved as a checkpoint. The replay recomputes any key from the
//        nearest checkpoint.
//

import BraidCore
import Foundation
import MLX

public struct IndexBuildOptions: Sendable {
    public var scheme: KeyScheme
    public var alpha: Float = ProvenanceKey.alpha
    public var checkpoints = CheckpointPolicy()
    /// The most tokens the trunk runs at once. A longer segment runs in pieces with the state carried
    /// and no checkpoint between them, so a segment's memory stays near 1 GB however long it is.
    public var pieceTokens = 1024
    /// Documents whose entries are left out of the index (the stitched bench's withheld set).
    public var exclude: Set<String> = []
    public init(scheme: KeyScheme) { self.scheme = scheme }
}

public struct IndexBuildResult {
    public var directory: URL
    public var info: IndexInfo
    public var memorised: Float
    public var meanLoss: Float
}

public enum IndexBuilder {
    /// Writes the index into `directory`. `blocksSHA256` names the thread weights the trunk holds.
    public static func build(trunk: Trunk, reed: MLXReed, corpus: TokenizedCorpus, pack: Pack, blocksSHA256: String, threadID: String?, options: IndexBuildOptions,
                             into directory: URL, progress: (Int, Int) -> Void = { _, _ in }) throws -> IndexBuildResult {
        let config = trunk.config
        let checkpointDirectory = directory.appendingPathComponent(IndexFiles.checkpointDirectory, isDirectory: true)
        var documents: [DocumentEntries] = []
        for (d, document) in corpus.documents.enumerated() {
            progress(d, corpus.documents.count)
            guard document.tokens.count >= 3 else { continue }
            let segments = DocumentSegments(document, corpus: corpus, policy: options.checkpoints)
            documents.append(try indexDocument(document, in: segments, trunk: trunk, reed: reed, corpus: corpus, pack: pack, options: options, checkpointDirectory: checkpointDirectory))
            Memory.clearCache()
        }
        let arrays = IndexFiles.Arrays(joining: documents, keyDims: options.scheme.keyDims(config: config))
        var info = indexInfo(for: documents, entries: arrays.values.count, trunk: trunk, pack: pack, corpus: corpus, options: options, blocksSHA256: blocksSHA256, threadID: threadID)
        let checkpoints = documents.flatMap(\.checkpoints)
        let manifest = CheckpointManifest(policy: options.checkpoints, checkpoints: checkpoints, totalBytes: checkpoints.count * StateStack.byteCount(config: config))
        try IndexFiles.write(arrays: arrays, info: &info, partitions: corpus.partitionRefs, sharedNgrams: corpus.sharedNgrams, manifest: manifest, to: directory)
        return IndexBuildResult(directory: directory, info: info, memorised: info.evalMemorisedFraction, meanLoss: info.evalLoss)
    }

    /// One document keyed from a zero state, segment by segment: each segment run through the trunk
    /// a piece at a time, each piece scored, keyed and recorded, and the state after the segment
    /// saved unless it is the document's last.
    static func indexDocument(_ document: TokenizedDocument, in segments: DocumentSegments, trunk: Trunk, reed: MLXReed, corpus: TokenizedCorpus, pack: Pack,
                              options: IndexBuildOptions, checkpointDirectory: URL) throws -> DocumentEntries {
        var entries = DocumentEntries()
        var state: StateStack? = nil
        for segment in segments.ranges {
            for piece in pieces(of: segment, tokens: options.pieceTokens) {
                let out = SegmentKeys.run(trunk: trunk, segment: Array(document.tokens[piece]), state: state, scheme: options.scheme)
                let (loss, entropy) = score(out.final, at: piece, of: document, reed: reed, eos: corpus.eos)
                let keys = ProvenanceKey.make(mid: out.mid, final: out.final, alpha: options.alpha)
                eval(keys, loss, entropy)
                entries.record(piece, of: document, keys: keys, loss: loss.asArray(Float.self), entropy: entropy.asArray(Float.self), eos: corpus.eos,
                               indexed: !options.exclude.contains(document.documentID))
                state = out.state
            }
            if let state, segment.upperBound < document.tokens.count - 1 {
                entries.checkpoints.append(try saveCheckpoint(state, after: segment.upperBound, of: document, in: checkpointDirectory, pack: pack))
            }
        }
        return entries
    }

    /// A segment cut into runs of at most `tokens`, in order; one run when the segment is that short.
    private static func pieces(of segment: ClosedRange<Int>, tokens: Int) -> [ClosedRange<Int>] {
        stride(from: segment.lowerBound, through: segment.upperBound, by: tokens).map { $0 ... min($0 + tokens - 1, segment.upperBound) }
    }

    /// How well the Thread already predicts each position's next token: the reed's loss on it and
    /// the predictive entropy, from the normed final state ([q, D]).
    private static func score(_ final: MLXArray, at segment: ClosedRange<Int>, of document: TokenizedDocument, reed: MLXReed, eos: Int32) -> (loss: MLXArray, entropy: MLXArray) {
        let logits = reed.logits(array: final)
        return MLXReed.tokenStats(logits: logits, targets: MLXArray(nextTokens(segment, of: document, eos: eos)))
    }

    /// Targets: the token after each position (the first token of the next segment for the last
    /// position, and eos after the document's closing eos).
    private static func nextTokens(_ segment: ClosedRange<Int>, of document: TokenizedDocument, eos: Int32) -> [Int32] {
        segment.map { $0 + 1 < document.tokens.count ? document.tokens[$0 + 1] : eos }
    }

    /// A checkpoint at a partition boundary: the state after `position`, bound to its prefix, saved
    /// in the index's checkpoints folder, and its record.
    private static func saveCheckpoint(_ state: StateStack, after position: Int, of document: TokenizedDocument, in directory: URL, pack: Pack) throws -> CheckpointRef {
        var stack = state
        stack.prefixSHA256 = NodeCheckpoint.prefixHash(Array(document.tokens[0...position]))
        let name = CheckpointRef.fileName(documentID: document.documentID, position: position)
        try stack.save(to: directory.appendingPathComponent(name), packSHA256: pack.sha256)
        let sha = try ContentHash.sha256Hex(fileAt: directory.appendingPathComponent(name))
        return CheckpointRef(documentID: document.documentID, position: position, file: name, sha256: sha, prefixSHA256: stack.prefixSHA256!)
    }

    /// index.json's record: what the index is bound to (the thread blocks, the pack, its seam,
    /// vocabulary and tokenizer, the corpus), its eval, and the documents it withholds.
    private static func indexInfo(for documents: [DocumentEntries], entries: Int, trunk: Trunk, pack: Pack, corpus: TokenizedCorpus, options: IndexBuildOptions,
                                  blocksSHA256: String, threadID: String?) -> IndexInfo {
        let config = trunk.config
        let eval = DocumentEntries.Eval(documents)
        var info = IndexInfo(keyScheme: options.scheme, alpha: options.alpha, keyDims: options.scheme.keyDims(config: config), count: entries,
                             documents: corpus.documents.count, partitions: corpus.partitions.count, blocksSHA256: blocksSHA256, packSHA256: pack.sha256,
                             seamSHA256: trunk.seamSHA256, vocabularySHA256: pack.info.vocabularySHA256, corpusHash: "", tokenizerSHA256: pack.info.tokenizerSHA256,
                             threadID: threadID, evalLoss: eval.loss, evalEntropy: eval.entropy, evalMemorisedFraction: eval.memorised, cut: config.cut,
                             paragraphBreak: corpus.paragraphBreak, eos: corpus.eos, checkpointsSHA256: "", indexSHA256: "",
                             createdAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)))
        info.corpusHash = ContentHash.corpusHash(corpus.partitions.map { ContentHash.CorpusEntry(documentID: $0.ref.documentID, partitionIndex: $0.ref.partitionIndex, textSHA256: $0.ref.textSHA256) })
        let withheld = Set(corpus.documents.map(\.documentID)).intersection(options.exclude)
        info.excluded = withheld.isEmpty ? nil : withheld.sorted()
        return info
    }
}
