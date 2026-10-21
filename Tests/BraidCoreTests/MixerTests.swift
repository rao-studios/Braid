//
//  MixerTests.swift
//  BraidCoreTests
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation
import Testing
@testable import BraidCore

private func hit(_ entry: Int32, _ score: Float, value: Int32, row: Int32 = 0) -> Hit {
    Hit(entry: entry, score: score, value: value, row: row, offset: entry + 1, loss: 0.01)
}

@Suite("The mixer")
struct MixerTests {
    @Test("each strand weighs its hits among itself; the mixture is the gate-weighted kNN-LMs; shares sum to 1")
    func mixture() {
        let a = Expert(hits: [hit(0, 0.99, value: 2), hit(1, 0.50, value: 3)], tau: 0.05, logits: [0, 0, 5, 0], lambda: 0.5)
        let b = Expert(hits: [hit(0, 0.999, value: 3)], tau: 0.05, logits: [0, 0, 0, 5], lambda: 0.5)
        let mix = Mixer.mix(experts: [a, b], gates: [0.98, 0.02], open: [true, true], vocabulary: 4)
        #expect(Mixer.argmax(mix.mixed) == 2)
        #expect(abs(mix.mixed.reduce(0, +) - 1) < 1e-9)
        let shares = Mixer.shares(mix, experts: [a, b], token: 2)
        #expect(abs(shares.reduce(0, +) - 1) < 1e-9 && shares[0] > 0.99)
        #expect(abs(a.weights.reduce(0, +) - 1) < 1e-9 && b.weights == [1])
        #expect(a.probability(of: 2)! > 0.9 && b.lowerBound(of: 3) == 0.5 && b.knnEntropy == 0)
        for lambda in [0.0, 0.25, 0.5, 1.0] {
            let x = Expert(hits: [hit(0, 0.99, value: 2), hit(1, 0.97, value: 2)], tau: 0.05, logits: [0, 0, 6, 0], lambda: lambda)
            let y = Expert(hits: [hit(0, 0.96, value: 3), hit(1, 0.94, value: 2)], tau: 0.05, logits: [0, 0, 0, 6], lambda: lambda)
            let m = Mixer.mix(experts: [x, y], gates: [0.5, 0.5], open: [true, true], vocabulary: 4)
            #expect(abs(m.mixed.reduce(0, +) - 1) < 1e-9, "λ \(lambda)")
            for token in 0..<4 where m.mixed[token] > 0 {
                #expect(abs(Mixer.shares(m, experts: [x, y], token: token).reduce(0, +) - 1) < 1e-9, "λ \(lambda) token \(token)")
            }
        }
    }

    @Test("shares sum to 1 for every strand count and λ, with a commons and closed strands", arguments: [1, 2, 3, 24])
    func sharesAtScale(strands: Int) {
        var rng = SplitMix64(seed: UInt64(strands))
        func uniform() -> Double { Double(rng.next() % 1_000_000) / 1_000_000 }
        let vocabulary = 64
        for lambda in [0.0, 0.25, 0.5, 1.0] {
            // Strand 0 is the commons (λ 0, no hits); the rest are Threads with random hits and logits.
            let experts: [Expert] = (0 ..< strands).map { t in
                let logits = (0 ..< vocabulary).map { _ in Float(uniform() * 6 - 3) }
                if t == 0 { return Expert(hits: [], tau: 0.05, logits: logits, lambda: 0) }
                let hits = (0 ..< 16).map { i in hit(Int32(i), Float(0.5 + uniform() * 0.5), value: Int32(rng.next() % UInt64(vocabulary))) }
                return Expert(hits: hits.sorted { $0.score > $1.score }, tau: 0.05, logits: logits, lambda: lambda)
            }
            var gates = (0 ..< strands).map { _ in uniform() + 1e-3 }
            let total = gates.reduce(0, +)
            gates = gates.map { $0 / total }
            // Every third Thread closed; the commons always open.
            let open = (0 ..< strands).map { $0 == 0 || $0 % 3 != 0 }
            let mix = Mixer.mix(experts: experts, gates: gates, open: open, vocabulary: vocabulary)
            #expect(abs(mix.mixed.reduce(0, +) - 1) < 1e-9, "N \(strands) λ \(lambda)")
            for token in 0 ..< vocabulary where mix.mixed[token] > 0 {
                let shares = Mixer.shares(mix, experts: experts, token: token)
                #expect(abs(shares.reduce(0, +) - 1) < 1e-5, "N \(strands) λ \(lambda) token \(token)")
                for t in experts.indices where !open[t] { #expect(shares[t] == 0) }
            }
        }
    }

    @Test("a closed strand is left out and the others renormalise; a strand without a reed is never mixed")
    func closed() {
        let a = Expert(hits: [hit(0, 0.9, value: 1)], tau: 0.05, logits: [0, 4, 0], lambda: 0.5)
        let b = Expert(hits: [hit(0, 0.9, value: 2)], tau: 0.05, logits: nil, lambda: 0.5)
        let mix = Mixer.mix(experts: [a, b], gates: [0.9, 0.1], open: [true, true], vocabulary: 3)
        #expect(mix.weights == [1, 0] && mix.open == [true, false])
        let shares = Mixer.shares(mix, experts: [a, b], token: 1)
        #expect(shares[1] == 0 && abs(shares[0] - 1) < 1e-12)
        let closed = Mixer.mix(experts: [a, Expert(hits: [], tau: 0.05, logits: [0, 0, 4], lambda: 0.5)], gates: [0.95, 0.05], open: [true, false], vocabulary: 3)
        #expect(closed.weights == [1, 0])
    }

    @Test("one expert is a kNN-LM: λ·p_knn + (1−λ)·p_lm; a mixed λ averages by weight")
    func oneExpert() {
        let hits = [hit(0, 0.93, value: 1), hit(4, 0.91, value: 2), hit(9, 0.80, value: 1)]
        let logits: [Float] = [0.1, 2.0, 1.2, -0.5, 0.3]
        let expert = Expert(hits: hits, tau: 0.05, logits: logits, lambda: 0.5)
        let mix = Mixer.mix(experts: [expert], gates: [1], open: [true], vocabulary: 5)
        let plm = Mixer.softmax(logits)
        for token in 0..<5 {
            let expected = 0.5 * (expert.knn[token] ?? 0) + 0.5 * plm[token]
            #expect(abs(mix.mixed[token] - expected) < 1e-12)
        }
        let commons = Expert(hits: [], tau: 0.05, logits: [1, 0, 0, 0, 0], lambda: 0)
        let two = Mixer.mix(experts: [expert, commons], gates: [0.5, 0.5], open: [true, true], vocabulary: 5)
        #expect(abs(two.lambda - 0.25) < 1e-12 && abs(two.mixed.reduce(0, +) - 1) < 1e-9)
    }

    @Test("near ties: the oldest cited text wins, then the lower token id; no tie is the argmax")
    func chooser() {
        #expect(Mixer.choose([0.1, 0.7, 0.2], age: { _ in nil }) == 1)
        #expect(Mixer.choose([0.5, 0.5 - 1e-9], age: { $0 == 1 ? 10 : 20 }) == 1)
        #expect(Mixer.choose([0.5, 0.5 - 1e-9], age: { _ in nil }) == 0)
        #expect(Mixer.choose([0.5, 0.5 - 1e-9], age: { $0 == 0 ? nil : 5 }) == 1)
    }

    @Test("candidates split by strand and sampling draws from the tempered mixture")
    func candidatesAndSampling() {
        let a = Expert(hits: [hit(0, 0.9, value: 1)], tau: 0.05, logits: [0, 3, 0], lambda: 0.5)
        let b = Expert(hits: [hit(0, 0.9, value: 2)], tau: 0.05, logits: [0, 0, 3], lambda: 0.5)
        let mix = Mixer.mix(experts: [a, b], gates: [0.5, 0.5], open: [true, true], vocabulary: 3)
        let candidates = Mixer.candidates(mix, experts: [a, b], count: 3)
        #expect(candidates.count == 3 && candidates[0].prob >= candidates[1].prob)
        for c in candidates where c.prob > 0 { #expect(abs(c.parts.reduce(0, +) - 1) < 1e-9) }
        var rng = SplitMix64(seed: 1)
        let draws = (0..<300).map { _ in Mixer.sample(mix.mixed, topK: 0, rng: &rng) }
        #expect(draws.contains(1) && draws.contains(2))
        let bounds = Mixer.mixtureEntropyBounds(reedWeights: mix.reedWeights, knnWeights: mix.knnWeights, lambda: mix.lambda, hlm: [a.lmEntropy, b.lmEntropy], hknn: [0, 0])
        let exact = Mixer.entropy(mix.mixed)
        #expect(bounds.lower <= exact + 1e-9 && exact <= bounds.upper + 1e-9)
    }
}
