//
//  ReplayTests.swift
//  BraidKitTests
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation
import MLX
import Testing
@testable import BraidKit

/// A Thread created in the work area (braid thread create …), when there is one, loaded behind the
/// commons it runs with (`liveCommonsNode`).
nonisolated(unsafe) var liveThreadProblem = ""
nonisolated(unsafe) private var liveCommons: LocalNode? = nil
let liveThread: (WorkArea, Pack, LoadedThread)? = {
    do {
        guard let area = WorkArea.resolve() else { liveThreadProblem = "no work area"; return nil }
        let config = try BraidConfig.load(from: area.configFile)
        guard let record = config.pack else { liveThreadProblem = "no pack in braid.toml"; return nil }
        let pack = try Pack.load(from: area.pack(sha256: record.sha256))
        guard let first = try ThreadStore.list(in: area).first else { liveThreadProblem = "no threads"; return nil }
        let commons = try ThreadStore.commons(pack: pack, scheme: .residual(afterBlocks: pack.config.tapAfterBlocks))
        liveCommons = commons
        return (area, pack, try ThreadStore.load(first.name, in: area, pack: pack, commons: commons))
    } catch {
        liveThreadProblem = "\(error)"
        return nil
    }
}()
/// The commons the live Thread was loaded behind: the trunk it runs.
var liveCommonsNode: LocalNode? { _ = liveThread; return liveCommons }

extension BraidMLXSuites {
    @Suite("KV-free replay", .enabled(if: mlxTests), .serialized)
    struct ReplayTests {
        @Test("a live thread is loadable from the work area")
        func fixture() {
            let loaded = liveThread
            print("REPLAY FIXTURE: \(loaded == nil ? liveThreadProblem : "ok")")
            #expect(loaded != nil, Comment(rawValue: liveThreadProblem))
        }

        @Test("any corpus position's key recomputes from the nearest checkpoint (or the zero state) within 1e-4 of the stored key")
        func keyRecomputes() throws {
            guard let (area, pack, loaded) = liveThread else { return }
            let tokenizer = try BraidTokenizer(folder: pack.tokenizerFolder)
            let snapshot = try CorpusSnapshot.load(from: area.thread(loaded.info.name).snapshot(hash: loaded.version.snapshotHash))
            let corpus = TokenizedCorpus(snapshot: snapshot, tokenizer: tokenizer, paragraphBreak: tokenizer.paragraphBreak, threadID: loaded.info.threadID)
            let index = loaded.node.index!
            var rng = SplitMix64(seed: 42)
            var sample = Set((0..<48).map { _ in Int(rng.next() % UInt64(index.count)) })
            // Every partition's first and last entry too.
            var seenRow: Set<Int32> = []
            for e in 0..<index.count where !seenRow.contains(index.keyRow[e]) { seenRow.insert(index.keyRow[e]); sample.insert(e) }
            var worst: Float = 0
            var farthest = 0
            for entry in sample.sorted().prefix(96) {
                let target = TokenPosition(row: Int(index.keyRow[entry]), offset: Int(index.keyOffset[entry]))
                let (replayed, distance) = try Replay.key(at: target, index: index, corpus: corpus, trunk: loaded.node.trunk, pack: pack)
                let stored = index.key(entry: entry)
                let cosine = (replayed * stored).sum()
                eval(cosine)
                worst = max(worst, 1 - cosine.item(Float.self))
                farthest = max(farthest, distance)
            }
            #expect(worst <= 1e-4, "1 − cos \(worst)")
            print("replay: \(sample.count) positions, worst 1 − cos \(worst), farthest scan \(farthest) tokens, checkpoints \(index.checkpoints.checkpoints.count)")
        }

        @Test("exact search agrees with a brute-force cosine over the whole index")
        func searchIsExact() throws {
            guard let (_, _, loaded) = liveThread else { return }
            let index = loaded.node.index!
            let queries = concatenated([index.key(entry: 3).reshaped([1, -1]), index.key(entry: index.count / 2).reshaped([1, -1])], axis: 0)
            let hits = index.query(queries, k: 16)
            for (q, row) in hits.enumerated() {
                let all = (0..<index.count).map { e -> (Int, Float) in
                    let c = (index.key(entry: e) * queries[q]).sum()
                    eval(c)
                    return (e, c.item(Float.self))
                }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
                #expect(row.map { Int($0.entry) } == all.prefix(16).map(\.0))
                #expect(row.first?.entry == Int32(q == 0 ? 3 : index.count / 2))
            }
        }
    }
}
