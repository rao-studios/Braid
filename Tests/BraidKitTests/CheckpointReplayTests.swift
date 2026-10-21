//
//  CheckpointReplayTests.swift
//  BraidKitTests
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The KV-free replay through real checkpoints. The live Thread's documents are shorter than
//        the default 1,024-token stride, so its index holds none; here six of its documents are keyed
//        again with a checkpoint at every partition boundary (in a scratch directory), and:
//        any key recomputes from the nearest checkpoint within 1e-4; a checkpoint's state equals the
//        state a fresh forward from zero reaches over the same prefix; the manifest is bound to
//        index.json; a tampered checkpoint is refused.
//

import Foundation
import MLX
import Testing
@testable import BraidKit

extension BraidMLXSuites {
    @Suite("Checkpoint replay", .enabled(if: mlxTests), .serialized)
    struct CheckpointReplayTests {
        /// Six documents of the live Thread keyed with a checkpoint at every partition, in a scratch directory.
        static func build() throws -> (pack: Pack, loaded: LoadedThread, corpus: TokenizedCorpus, index: ProvenanceIndex, directory: URL)? {
            guard let (area, pack, loaded) = liveThread else { return nil }
            let tokenizer = try BraidTokenizer(folder: pack.tokenizerFolder)
            let full = try CorpusSnapshot.load(from: area.thread(loaded.info.name).snapshot(hash: loaded.version.snapshotHash))
            let several = full.documents.filter { $0.partitions.count >= 2 }.prefix(6)
            let snapshot = CorpusSnapshot(documents: Array(several), slug: full.slug, source: full.source, threadID: full.threadID, owner: full.owner, group: full.group,
                                          documentIDPrefix: full.documentIDPrefix)
            let corpus = TokenizedCorpus(snapshot: snapshot, tokenizer: tokenizer, paragraphBreak: tokenizer.paragraphBreak, threadID: loaded.info.threadID)
            var options = IndexBuildOptions(scheme: loaded.version.keyScheme)
            options.checkpoints.everyPartition = true
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("braid-ckpt-\(UUID().uuidString.prefix(8))", isDirectory: true)
            _ = try IndexBuilder.build(trunk: loaded.node.trunk, reed: pack.reed(tokens: tokenizer.vocabSize), corpus: corpus, pack: pack, blocksSHA256: loaded.version.blocksSHA256,
                                       threadID: loaded.info.threadID, options: options, into: directory)
            return (pack, loaded, corpus, try ProvenanceIndex(directory: directory), directory)
        }

        @Test("keys recompute from the nearest checkpoint; checkpoints equal a fresh forward; tampering is refused")
        func replayThroughCheckpoints() throws {
            guard let (pack, loaded, corpus, index, directory) = try Self.build() else { return }
            defer { try? FileManager.default.removeItem(at: directory) }
            let checkpoints = index.checkpoints.checkpoints
            // Every partition ends at a boundary, the last one included (before the closing eos).
            let boundaries = corpus.documents.reduce(0) { $0 + $1.rows.count }
            #expect(checkpoints.count == boundaries, "a checkpoint at every partition boundary: \(checkpoints.count) of \(boundaries)")

            // Every partition's first and last entry, and 64 seeded ones.
            var sample: Set<Int> = []
            var seen: Set<Int32> = []
            for e in 0 ..< index.count where !seen.contains(index.keyRow[e]) { seen.insert(index.keyRow[e]); sample.insert(e) }
            for e in 1 ..< index.count where index.keyRow[e] != index.keyRow[e - 1] { sample.insert(e - 1) }
            sample.insert(index.count - 1)
            var rng = SplitMix64(seed: 42)
            for _ in 0 ..< 64 { sample.insert(Int(rng.next() % UInt64(index.count))) }
            var worst: Float = 0
            var throughCheckpoint = 0
            var farthest = 0
            for entry in sample.sorted() {
                let target = TokenPosition(row: Int(index.keyRow[entry]), offset: Int(index.keyOffset[entry]))
                let (replayed, distance) = try Replay.key(at: target, index: index, corpus: corpus, trunk: loaded.node.trunk, pack: pack)
                let cosine = (replayed * index.key(entry: entry)).sum()
                eval(cosine)
                worst = max(worst, 1 - cosine.item(Float.self))
                farthest = max(farthest, distance)
                if let document = corpus.document(ofRow: target.row), let position = document.addresses.firstIndex(of: target),
                   checkpoints.contains(where: { $0.documentID == document.documentID && $0.position < position }) { throughCheckpoint += 1 }
            }
            print("CHECKPOINT REPLAY: \(sample.count) positions (\(throughCheckpoint) through a checkpoint), worst 1 − cos \(worst), farthest scan \(farthest) tokens, \(checkpoints.count) checkpoints")
            #expect(worst <= 1e-4, "1 − cos \(worst)")
            #expect(throughCheckpoint > sample.count / 2, "most positions replay from a checkpoint")

            // checkpointEqualsReset (the plan's rule): continuing from a checkpoint gives the same final
            // output, within 1e-4, as continuing from a fresh forward over the same prefix from zero. The
            // raw states are reported relative to their size (segmented and one-shot scans accumulate
            // in a different order).
            let trunk = loaded.node.trunk
            for reference in checkpoints.prefix(6) {
                guard let document = corpus.documents.first(where: { $0.documentID == reference.documentID }),
                      reference.position + 1 < document.tokens.count else { continue }
                let prefix = Array(document.tokens[0 ... reference.position])
                let fresh = trunk.forward(tokens: MLXArray(prefix, [1, prefix.count]), state: nil, resets: nil).state
                let stored = try StateStack.load(from: directory.appendingPathComponent(IndexFiles.checkpointDirectory).appendingPathComponent(reference.file), expecting: trunk.config)
                #expect(stored.prefixSHA256 == NodeCheckpoint.prefixHash(prefix))
                var absolute: Float = 0
                var scale: Float = 0
                for (a, b) in zip(fresh.layers, stored.layers) {
                    let d = abs(a.ssm - b.ssm).max()
                    let m = abs(a.ssm).max()
                    eval(d, m)
                    absolute = Swift.max(absolute, d.item(Float.self))
                    scale = Swift.max(scale, m.item(Float.self))
                }
                let next = MLXArray([document.tokens[reference.position + 1]])
                let fromFresh = trunk.step(token: next, state: fresh, reset: nil).final
                let fromCheckpoint = trunk.step(token: next, state: stored, reset: nil).final
                let finalDifference = abs(fromFresh - fromCheckpoint).max()
                eval(finalDifference)
                let final = finalDifference.item(Float.self)
                print(String(format: "CHECKPOINT %@ @%d: final %.2e · state %.2e absolute, %.2e relative (max |S| %.1f)", String(reference.documentID.suffix(8)), reference.position,
                             final, absolute, absolute / Swift.max(scale, 1e-6), scale))
                #expect(final <= 1e-4, "continuing from \(reference.file) differs from a reset run by \(final)")
                #expect(absolute / Swift.max(scale, 1e-6) <= 1e-4, "\(reference.file): relative state difference \(absolute / Swift.max(scale, 1e-6))")
            }

            // The manifest is bound to index.json: an edited manifest is refused at load.
            let manifestURL = directory.appendingPathComponent(IndexFiles.checkpoints)
            let manifest = try Data(contentsOf: manifestURL)
            try (manifest + Data(" ".utf8)).write(to: manifestURL)
            #expect(throws: (any Error).self) { _ = try ProvenanceIndex(directory: directory) }
            try manifest.write(to: manifestURL)

            // A tampered checkpoint is refused by the replay.
            guard let victim = checkpoints.first, let document = corpus.documents.first(where: { $0.documentID == victim.documentID }),
                  victim.position + 1 < document.addresses.count else { return }
            let fileURL = directory.appendingPathComponent(IndexFiles.checkpointDirectory).appendingPathComponent(victim.file)
            var bytes = try Data(contentsOf: fileURL)
            bytes[bytes.count - 1] ^= 0x01
            try bytes.write(to: fileURL)
            let after = document.addresses[victim.position + 1]
            #expect(throws: (any Error).self) { _ = try Replay.key(at: after, index: index, corpus: corpus, trunk: loaded.node.trunk, pack: pack) }
        }
    }
}
