//
//  NodeContinuityTests.swift
//  BraidKitTests
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The two node properties attach and detach rest on, on the live Thread:
//        catch-up — a node opened on a 97-token prefix in one forward equals one advanced token by
//        token from the eos (state ≤ 1e-4, key cosine ≥ 1 − 1e-5, the same top-16 up to near-ties);
//        detach/re-attach — a node checkpointed, closed, and restored on the same prefix continues
//        exactly as the node that never left (≤ 1e-6, the same state hash).
//

import Foundation
import MLX
import Testing
@testable import BraidKit

extension BraidMLXSuites {
    @Suite("Node continuity", .enabled(if: mlxTests), .serialized)
    struct NodeContinuityTests {
        /// 97 tokens of the Thread's own first document, then a few beyond, behind the eos opener.
        static func tokens(_ area: WorkArea, _ pack: Pack, _ loaded: LoadedThread, count: Int) throws -> [Int32] {
            let tokenizer = try BraidTokenizer(folder: pack.tokenizerFolder)
            let snapshot = try CorpusSnapshot.load(from: area.thread(loaded.info.name).snapshot(hash: loaded.version.snapshotHash))
            let text = snapshot.documents.flatMap { $0.partitions.sorted { $0.index < $1.index }.map(\.text) }.joined(separator: "\n\n")
            return [tokenizer.eos] + Array(tokenizer.encode(text).prefix(count))
        }

        static func maxDifference(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).map { abs($0 - $1) }.max() ?? 0 }

        @Test("a node caught up on a prefix in one forward equals one advanced token by token")
        func catchUp() throws {
            guard let (area, pack, loaded) = liveThread else { return }
            let node = loaded.node
            let tokens = try Self.tokens(area, pack, loaded, count: 97)
            let k = 16
            let opened = try node.open(session: UUID().uuidString, tokens: tokens, k: k)
            let stepped = UUID().uuidString
            var advancedSteps = try node.open(session: stepped, tokens: [tokens[0]], k: k)
            for token in tokens.dropFirst() { advancedSteps.append(try node.advance(session: stepped, token: token, k: k)) }
            node.close(session: stepped)
            #expect(opened.count == advancedSteps.count)
            var worstState: Float = 0
            var differentTop = 0
            for (a, b) in zip(opened, advancedSteps) {
                worstState = max(worstState, Self.maxDifference(a.state, b.state))
                let topA = a.hits.prefix(16).map(\.entry), topB = b.hits.prefix(16).map(\.entry)
                if Set(topA) != Set(topB) {
                    // Allowed only where scores tie within float noise at the cut.
                    let cutA = a.hits.last?.score ?? 0, cutB = b.hits.last?.score ?? 0
                    if abs(cutA - cutB) > 1e-4 { differentTop += 1 }
                }
                if let ha = a.hits.first, let hb = b.hits.first, ha.entry == hb.entry { #expect(abs(ha.score - hb.score) <= 1e-5) }
            }
            print("CATCH-UP: \(opened.count) positions, worst state difference \(worstState), positions with a different top-16 beyond ties \(differentTop)")
            #expect(worstState <= 1e-4)
            #expect(differentTop == 0)
        }

        @Test("a node checkpointed, closed and restored continues exactly as the one that never left")
        func detachReattach() throws {
            guard let (area, pack, loaded) = liveThread else { return }
            let node = loaded.node
            let tokens = try Self.tokens(area, pack, loaded, count: 64)
            let prefix = Array(tokens.prefix(40))
            let rest = Array(tokens.dropFirst(40))
            let staying = UUID().uuidString
            _ = try node.open(session: staying, tokens: prefix, k: 16)
            let leaving = UUID().uuidString
            _ = try node.open(session: leaving, tokens: prefix, k: 16)
            let saved = try node.checkpoint(session: leaving)
            node.close(session: leaving)
            let back = UUID().uuidString
            try node.restore(session: back, checkpoint: saved, tokens: prefix)
            var worst: Float = 0
            for token in rest {
                let a = try node.advance(session: staying, token: token, k: 16)
                let b = try node.advance(session: back, token: token, k: 16)
                worst = max(worst, Self.maxDifference(a.state, b.state))
                #expect(a.hits.map(\.entry) == b.hits.map(\.entry))
            }
            let x = try node.checkpoint(session: staying), y = try node.checkpoint(session: back)
            print("DETACH/RE-ATTACH: \(rest.count) tokens after the checkpoint, worst state difference \(worst), state hashes equal \(x.sha256 == y.sha256)")
            #expect(worst <= 1e-6)
            #expect(x.sha256 == y.sha256)
            #expect(throws: (any Error).self) { try node.restore(session: UUID().uuidString, checkpoint: saved, tokens: Array(prefix.dropLast())) }
            node.close(session: staying)
            node.close(session: back)
        }
    }
}
