//
//  SegmentKeysTests.swift
//  BraidKitTests
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The per-position key halves for the pooled-state schemes, computed by stepping one block
//        over a chunked forward's tap, equal the reference that steps the whole language module
//        token by token; a segment split in two with the state carried equals the whole; the last
//        key equals the last row. Tiny random language module, no pack.
//

import Foundation
import MLX
import Testing
@testable import BraidKit

extension BraidMLXSuites {
    @Suite("Segment keys", .enabled(if: mlxTests), .serialized)
    struct SegmentKeysTests {
        static let config = Mamba2Config(hiddenSize: 16, numHiddenLayers: 3, numHeads: 2, headDim: 4, stateSize: 4, nGroups: 1, convKernel: 4, vocabSize: 32, cut: 1)

        /// The whole language module stepped token by token: the reference for every scheme.
        static func reference(languageModule: LanguageModule, segment: [Int32], state: StateStack?, scheme: KeyScheme) -> (final: MLXArray, mid: MLXArray) {
            var current = state ?? StateStack.zeros(config: languageModule.config, batch: 1)
            var finals: [MLXArray] = [], mids: [MLXArray] = []
            for token in segment {
                let previous = current
                let out = languageModule.step(token: MLXArray([token]), state: current, reset: nil, taps: scheme.taps)
                current = out.state
                finals.append(out.final)
                mids.append(ProvenanceKey.mid(scheme: scheme, output: out, previousState: previous))
            }
            return (concatenated(finals, axis: 0), concatenated(mids, axis: 0))
        }

        static func maxAbs(_ a: MLXArray, _ b: MLXArray) -> Float {
            let d = abs(a - b).max()
            eval(d)
            return d.item(Float.self)
        }

        @Test("pooled-state and state-delta halves equal the stepped language module at every position", arguments: [KeyScheme.pooledState(layer: 1), .stateDelta(layer: 1), .pooledState(layer: 2), .residual(afterBlocks: 2)])
        func matchesReference(scheme: KeyScheme) {
            MLXRandom.seed(7)
            let languageModule = LanguageModule(Self.config)
            let segment: [Int32] = (0..<23).map { Int32(($0 * 7 + 3) % 32) }
            let fast = SegmentKeys.run(languageModule: languageModule, segment: segment, state: nil, scheme: scheme)
            let slow = Self.reference(languageModule: languageModule, segment: segment, state: nil, scheme: scheme)
            #expect(fast.final.shape == slow.final.shape && fast.mid.shape == slow.mid.shape, "\(fast.final.shape) \(fast.mid.shape) vs \(slow.final.shape) \(slow.mid.shape)")
            let scale = max(1, abs(slow.mid).max().item(Float.self))
            #expect(Self.maxAbs(fast.final, slow.final) <= 1e-4)
            #expect(Self.maxAbs(fast.mid, slow.mid) <= 1e-4 * scale, "mid differs by \(Self.maxAbs(fast.mid, slow.mid)) (scale \(scale))")
            // The last key equals the last row of the per-position keys.
            let keys = ProvenanceKey.make(mid: fast.mid, final: fast.final)
            let last = SegmentKeys.lastKey(languageModule: languageModule, segment: segment, state: nil, scheme: scheme, alpha: ProvenanceKey.alpha)
            #expect(Self.maxAbs(keys[segment.count - 1], last) <= 1e-4)
        }

        @Test("a segment split in two with the state carried equals the whole", arguments: [KeyScheme.pooledState(layer: 1), .stateDelta(layer: 2), .residual(afterBlocks: 2)])
        func splitEqualsWhole(scheme: KeyScheme) {
            MLXRandom.seed(11)
            let languageModule = LanguageModule(Self.config)
            let segment: [Int32] = (0..<30).map { Int32(($0 * 5 + 1) % 32) }
            let whole = SegmentKeys.run(languageModule: languageModule, segment: segment, state: nil, scheme: scheme)
            let first = SegmentKeys.run(languageModule: languageModule, segment: Array(segment[0..<13]), state: nil, scheme: scheme)
            let second = SegmentKeys.run(languageModule: languageModule, segment: Array(segment[13...]), state: first.state, scheme: scheme)
            let joined = concatenated([first.mid, second.mid], axis: 0)
            let scale = max(1, abs(whole.mid).max().item(Float.self))
            #expect(Self.maxAbs(joined, whole.mid) <= 1e-4 * scale, "split differs by \(Self.maxAbs(joined, whole.mid))")
            #expect(Self.maxAbs(concatenated([first.final, second.final], axis: 0), whole.final) <= 1e-4)
        }
    }
}
