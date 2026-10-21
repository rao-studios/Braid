//
//  ReedTests.swift
//  BraidKitTests
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The reed's token stats against an f64 reference over the tokenizer's tokens: the loss and
//        the predictive entropy, with padding rows past the vocabulary at −∞ (the pack has 11).
//        Before 2026-10-19 the entropy was NaN at every position (0·−∞ at those rows). Tiny random
//        embedding, no pack.
//

import Foundation
import MLX
import Testing
@testable import BraidKit

extension BraidMLXSuites {
    @Suite("The reed", .enabled(if: mlxTests), .serialized)
    struct ReedTests {
        /// The f64 loss and entropy of one logits row over its finite entries.
        static func reference(_ row: [Float], target: Int) -> (loss: Double, entropy: Double) {
            let finite = row.filter { $0.isFinite }.map(Double.init)
            let m = finite.max()!
            let lse = m + log(finite.reduce(0) { $0 + exp($1 - m) })
            return (lse - Double(row[target]), lse - finite.reduce(0) { $0 + exp($1 - lse) * $1 })
        }

        @Test("loss and entropy equal the f64 reference over the real tokens, padding rows included")
        func tokenStatsMatchReference() {
            MLXRandom.seed(5)
            let (hidden, vocabulary, tokens, n) = (8, 40, 33, 24)
            let reed = MLXReed(embedding: MLXRandom.normal([vocabulary, hidden]), vocabularySHA256: "", tokens: tokens)
            let states = MLXRandom.normal([n, hidden]) * 3
            let targets = (0 ..< n).map { Int32(($0 * 7 + 2) % tokens) }
            let logits = reed.logits(array: states)
            let (loss, entropy) = MLXReed.tokenStats(logits: logits, targets: MLXArray(targets))
            eval(logits, loss, entropy)
            let l = loss.asArray(Float.self), h = entropy.asArray(Float.self)
            var worstLoss = 0.0, worstEntropy = 0.0
            for i in 0 ..< n {
                let (rl, rh) = Self.reference(logits[i].asArray(Float.self), target: Int(targets[i]))
                worstLoss = max(worstLoss, abs(Double(l[i]) - rl))
                worstEntropy = max(worstEntropy, abs(Double(h[i]) - rh))
            }
            let notFinite = h.filter { !$0.isFinite }.count
            #expect(notFinite == 0, "entropy is not finite at \(notFinite) of \(n) rows")
            #expect(worstLoss <= 1e-5 && worstEntropy <= 1e-5, "loss off by \(worstLoss), entropy by \(worstEntropy)")
        }
    }
}
