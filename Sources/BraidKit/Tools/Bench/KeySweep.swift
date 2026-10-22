//
//  KeySweep.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The key sweep (step 4's instrument): the same trained Thread re-indexed under each key
//        scheme, then two retrieval-only measurements per scheme. The document-identity probe asks,
//        for a seeded sample of entries, whether an entry's own key finds another position of its own
//        document once its ±near neighbours are excluded. The fact arms ask whether the key at a fact
//        prompt's last token (the answer's predictor) retrieves the fact's partition, the answer's
//        very position, and the answer token — for the corpus-exact prompt, the dataset's question
//        stem and a paraphrase. Rules fixed here; the trace bench's T1–T3 per variant join when its
//        text sets exist. Nothing here changes a default: the report names a winner and whether the
//        +0.02 rule would ship it, and the owner decides.
//

import BraidCore
import Foundation
import MLX

public struct KeySweepOptions: Sendable {
    public var arms: [KeyScheme]
    public var defaultScheme: KeyScheme = .residual(afterBlocks: 12)
    /// Entries sampled for the document-identity probe.
    public var sample = 2000
    /// Same-document entries within ±near positions are not counted as finds.
    public var near = 8
    public var k = 16
    public var tau: Float = 0.05
    public var seed: UInt64 = 42
    /// Facts measured (0 = all located).
    public var factLimit = 0

    public static let defaultArms: [KeyScheme] = [
        .residual(afterBlocks: 6), .residual(afterBlocks: 8), .residual(afterBlocks: 12), .residual(afterBlocks: 16),
        .pooledState(layer: 8), .pooledState(layer: 12), .pooledState(layer: 16),
        .stateDelta(layer: 8), .stateDelta(layer: 12), .stateDelta(layer: 16),
    ]

    public init(arms: [KeyScheme] = KeySweepOptions.defaultArms) { self.arms = arms }
}

public struct ProbeReport: Codable, Sendable, Equatable {
    public var sampled: Int
    /// Fraction whose nearest non-neighbour entry is in the same document.
    public var sameDocument: Float
    /// Fraction whose nearest non-neighbour entry is in the same partition.
    public var samePartition: Float
    public var meanTopScore: Float
}

public struct RetrievalReport: Codable, Sendable, Equatable {
    public var count: Int
    /// The top hit's value sits on the fact's partition.
    public var partitionAt1: Float
    /// The top hit's value is the answer's first token at its own position.
    public var offsetAt1: Float
    /// The top hit's value token is the answer's first token (anywhere).
    public var answerAt1: Float
    /// Any of the top k hits sits on the fact's partition.
    public var partitionAtK: Float
    /// Mean softmax(s/τ) mass on the answer's first token.
    public var meanAnswerMass: Float
}

public struct KeySweepArmReport: Codable, Sendable, Equatable {
    public var scheme: String
    public var keyDims: Int
    public var entries: Int
    public var buildSeconds: Double
    public var probe: ProbeReport
    public var prompt: RetrievalReport?
    public var stem: RetrievalReport?
    public var paraphrase: RetrievalReport?
    /// T1–T3 of the trace bench for this variant, when its text sets exist. Nil = not run.
    public var qualifies: Bool?
}

public struct KeySweepReport: Codable, Sendable, Equatable {
    public var bench = "sweep-key"
    public var createdAt: Date
    public var thread: String
    public var source: String
    public var pack: String
    public var blocksSHA256: String
    public var documents: Int
    public var factsLocated: Int
    public var factsUnaligned: Int
    public var arms: [KeySweepArmReport]
    public var defaultScheme: String
    /// Highest prompt partition@1, ties by offset@1, then the earlier arm.
    public var winner: String?
    /// Winner ≠ default and its prompt partition@1 ≥ the default's + 0.02.
    public var ships: Bool
    public var rule: String
    public var notes: [String]
}

public enum KeySweep {
    public static let rule = "winner = highest prompt partition@1 (ties: offset@1, then arm order); ships only if ≥ +0.02 absolute over the default; a variant qualifies only when T1–T3 pass (pending the trace bench's text sets)"

    /// Runs every arm on `thread`, writing each arm's index under `directory/<scheme>/index`.
    public static func run(thread: LoadedThread, pack: Pack, tokenizer: BraidTokenizer, snapshot: CorpusSnapshot, facts: [Fact], options: KeySweepOptions,
                           into directory: URL, progress: (String) -> Void = { _ in }) throws -> KeySweepReport {
        let corpus = TokenizedCorpus(snapshot: snapshot, tokenizer: tokenizer, paragraphBreak: tokenizer.paragraphBreak, threadID: thread.info.threadID)
        let reed = pack.reed(tokens: tokenizer.vocabSize)
        let (located, unaligned) = FactLocator.locate(facts, corpus: corpus, byteOffsets: { tokenizer.byteOffsets($0) })
        let measured = options.factLimit > 0 ? Array(located.prefix(options.factLimit)) : located
        var arms: [KeySweepArmReport] = []
        var notes: [String] = []
        if measured.isEmpty { notes.append("no facts located: the fact arms are absent") }
        for scheme in options.arms {
            let armDirectory = directory.appendingPathComponent(scheme.description, isDirectory: true)
            let indexDirectory = armDirectory.appendingPathComponent("index", isDirectory: true)
            try FileManager.default.createDirectory(at: indexDirectory, withIntermediateDirectories: true)
            var build = IndexBuildOptions(scheme: scheme)
            build.checkpoints.strideTokens = Int.max / 4                                               // no checkpoints: nothing replays here
            progress("\(scheme): indexing \(corpus.documents.count) documents")
            let started = Date()
            let built = try IndexBuilder.build(languageModule: thread.node.languageModule, reed: reed, corpus: corpus, pack: pack, blocksSHA256: thread.version.blocksSHA256,
                                               threadID: thread.info.threadID, options: build, into: indexDirectory)
            let seconds = Date().timeIntervalSince(started)
            let index = try ProvenanceIndex(directory: indexDirectory)
            progress("\(scheme): \(index.count) entries in \(String(format: "%.1f", seconds)) s; probing")
            let probe = Self.probe(index: index, options: options)
            var arm = KeySweepArmReport(scheme: scheme.description, keyDims: built.info.keyDims, entries: index.count, buildSeconds: seconds, probe: probe)
            if !measured.isEmpty {
                progress("\(scheme): \(measured.count) facts × 3 arms")
                arm.prompt = retrieval(index: index, languageModule: thread.node.languageModule, tokenizer: tokenizer, corpus: corpus, facts: measured, scheme: scheme, options: options) { $0.fact.prompt }
                arm.stem = retrieval(index: index, languageModule: thread.node.languageModule, tokenizer: tokenizer, corpus: corpus, facts: measured, scheme: scheme, options: options) { $0.fact.questions?.first?.stem }
                arm.paraphrase = retrieval(index: index, languageModule: thread.node.languageModule, tokenizer: tokenizer, corpus: corpus, facts: measured, scheme: scheme, options: options) { $0.fact.paraphrases.first }
            }
            arms.append(arm)
            Memory.clearCache()
        }
        // The winner, by the rule.
        func rank(_ a: KeySweepArmReport) -> (Float, Float) { (a.prompt?.partitionAt1 ?? -1, a.prompt?.offsetAt1 ?? -1) }
        var winner: KeySweepArmReport? = nil
        for arm in arms where arm.prompt != nil {
            if let current = winner { if rank(arm) > rank(current) { winner = arm } } else { winner = arm }
        }
        let defaultArm = arms.first { $0.scheme == options.defaultScheme.description }
        var ships = false
        if let winner, let defaultArm, winner.scheme != defaultArm.scheme, let w = winner.prompt?.partitionAt1, let d = defaultArm.prompt?.partitionAt1 {
            ships = w >= d + 0.02
        }
        if defaultArm == nil { notes.append("the default scheme \(options.defaultScheme) was not among the arms; nothing ships against it") }
        notes.append("T1–T3 per variant not run: qualifies is nil for every arm")
        return KeySweepReport(createdAt: Date(), thread: thread.info.name, source: thread.info.source, pack: pack.sha256, blocksSHA256: thread.version.blocksSHA256,
                              documents: corpus.documents.count, factsLocated: located.count, factsUnaligned: unaligned.count, arms: arms,
                              defaultScheme: options.defaultScheme.description, winner: winner?.scheme, ships: ships, rule: rule, notes: notes)
    }

    /// The document-identity probe: an entry's own key against the index, its ±near same-document
    /// neighbours and itself excluded; is the nearest remaining entry in the same document?
    public static func probe(index: ProvenanceIndex, options: KeySweepOptions) -> ProbeReport {
        guard index.count > 0 else { return ProbeReport(sampled: 0, sameDocument: 0, samePartition: 0, meanTopScore: 0) }
        // Each entry's document, as an integer id.
        var documentIDs: [String: Int] = [:]
        let documentOf: [Int] = (0 ..< index.count).map { e in
            let id = index.partition(row: Int(index.keyRow[e]))?.documentID ?? "?"
            if let n = documentIDs[id] { return n }
            documentIDs[id] = documentIDs.count
            return documentIDs.count - 1
        }
        var rng = SplitMix64(seed: options.seed)
        let sampled: [Int] = index.count <= options.sample ? Array(0 ..< index.count) : (0 ..< options.sample).map { _ in Int(rng.next() % UInt64(index.count)) }
        var sameDocument = 0, samePartition = 0
        var topScores: Double = 0
        let batch = 256
        var start = 0
        while start < sampled.count {
            let slice = Array(sampled[start ..< min(start + batch, sampled.count)])
            let queries = index.keys[MLXArray(slice.map { Int32($0) })]
            let hits = index.query(queries, k: 2 * options.near + options.k + 1)
            for (i, e) in slice.enumerated() {
                let own = documentOf[e]
                guard let found = hits[i].first(where: { hit in
                    let f = Int(hit.entry)
                    return f != e && !(documentOf[f] == own && abs(f - e) <= options.near)
                }) else { continue }
                if documentOf[Int(found.entry)] == own { sameDocument += 1 }
                if index.keyRow[Int(found.entry)] == index.keyRow[e] { samePartition += 1 }
                topScores += Double(found.score)
            }
            start += batch
        }
        let n = max(1, sampled.count)
        return ProbeReport(sampled: sampled.count, sameDocument: Float(sameDocument) / Float(n), samePartition: Float(samePartition) / Float(n), meanTopScore: Float(topScores / Double(n)))
    }

    /// Retrieval at a fact prompt's last token for the texts `text` yields (nil skips the fact).
    static func retrieval(index: ProvenanceIndex, languageModule: LanguageModule, tokenizer: BraidTokenizer, corpus: TokenizedCorpus, facts: [LocatedFact], scheme: KeyScheme,
                          options: KeySweepOptions, text: (LocatedFact) -> String?) -> RetrievalReport? {
        var count = 0
        var partition1 = 0, offset1 = 0, answer1 = 0, partitionK = 0
        var mass: Double = 0
        for fact in facts {
            guard let prompt = text(fact), !prompt.isEmpty else { continue }
            let tokens: [Int32] = [tokenizer.eos] + tokenizer.encode(" " + prompt)
            let key = SegmentKeys.lastKey(languageModule: languageModule, segment: tokens, state: nil, scheme: scheme, alpha: index.info.alpha)
            let hits = index.query(key.reshaped([1, -1]), k: options.k)[0]
            guard let top = hits.first else { continue }
            count += 1
            let answerToken = corpus.partitions[fact.row].tokens[fact.answerToken]
            if Int(top.row) == fact.row { partition1 += 1 }
            if Int(top.row) == fact.row && Int(top.offset) == fact.answerToken { offset1 += 1 }
            if top.value == answerToken { answer1 += 1 }
            if hits.contains(where: { Int($0.row) == fact.row }) { partitionK += 1 }
            let scaled = hits.map { Double($0.score / options.tau) }
            let peak = scaled.max() ?? 0
            let weights = scaled.map { exp($0 - peak) }
            let total = weights.reduce(0, +)
            mass += zip(hits, weights).filter { $0.0.value == answerToken }.map { $0.1 }.reduce(0, +) / max(total, 1e-30)
        }
        guard count > 0 else { return nil }
        let n = Float(count)
        return RetrievalReport(count: count, partitionAt1: Float(partition1) / n, offsetAt1: Float(offset1) / n, answerAt1: Float(answer1) / n,
                               partitionAtK: Float(partitionK) / n, meanAnswerMass: Float(mass / Double(count)))
    }
}
