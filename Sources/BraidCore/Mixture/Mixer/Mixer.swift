//
//  Mixer.swift
//  BraidCore
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Each strand as its own kNN-LM at one position (softmax(score/τ_t) over its own hits, its
//        reed's distribution), the mixture over the open strands, the choice (the near-tie rule),
//        the exact shares, the candidates, and the retrieval entropy.
//  PIN:  Every number that chooses a token or sets a share is Double on the CPU, as RaoLM's are;
//        no score is ever compared across two strands' key spaces. share_t = w′_t·p_t(y)/p(y);
//        a token's shares sum to 1.
//

import Foundation

/// One strand's own kNN-LM at one position.
public struct Expert: Sendable {
    public var hits: [Hit]
    /// softmax(score/τ_t) over this strand's own hits.
    public var weights: [Double]
    public var knn: [Int: Double]
    /// The reed's distribution from this strand's normed state; nil when it was not asked.
    public var plm: [Double]?
    /// λ_t: the request's λ scaled by the strand's own; 0 for the commons.
    public var lambda: Double

    public init(hits: [Hit], tau: Double, logits: [Float]?, lambda: Double) {
        self.hits = hits
        weights = Mixer.weights(hits.map { Double($0.score) }, tau: tau)
        var knn: [Int: Double] = [:]
        for (i, hit) in hits.enumerated() { knn[Int(hit.value), default: 0] += weights[i] }
        self.knn = knn
        plm = logits.map { Mixer.softmax($0) }
        self.lambda = min(max(lambda, 0), 1)
    }

    /// p_t(y) = λ_t·p_knn,t(y) + (1−λ_t)·p_lm,t(y); nil without the reed.
    public func probability(of token: Int) -> Double? {
        guard let plm else { return nil }
        return lambda * (knn[token] ?? 0) + (1 - lambda) * (token < plm.count ? plm[token] : 0)
    }

    /// What retrieval alone guarantees of p_t(y), for a strand whose reed was not asked.
    public func lowerBound(of token: Int) -> Double { lambda * (knn[token] ?? 0) }

    public var bestScore: Float? { hits.map(\.score).max() }

    /// H(p_knn,t): the entropy of the strand's retrieval distribution over tokens (≤ ln k).
    public var knnEntropy: Double { Mixer.entropy(knn.values) }

    /// H(p_lm,t) on the CPU; nil when not asked. The GPU path (BraidKit) may supply it instead.
    public var lmEntropy: Double? { plm.map { Mixer.entropy($0) } }
}

/// The mixture at one position.
public struct Mixture: Sendable {
    /// w′: the gate renormalised over the open, asked strands (0 elsewhere).
    public var weights: [Double]
    public var open: [Bool]
    public var mixed: [Double]
    /// Σ_t w′_t·λ_t.
    public var lambda: Double
    public var reedWeights: [Double]
    public var knnWeights: [Double]
}

public enum Mixer {
    /// softmax(score/τ) over a strand's hits, τ floored at 1e-4.
    public static func weights(_ scores: [Double], tau: Double) -> [Double] {
        guard let top = scores.max() else { return [] }
        let t = max(tau, 1e-4)
        let exps = scores.map { exp(($0 - top) / t) }
        let total = exps.reduce(0, +)
        return exps.map { $0 / total }
    }

    /// Numerically stable softmax of logits / temperature (temperature ≤ 0 means 1), in Double.
    public static func softmax(_ logits: [Float], temperature: Double = 1) -> [Double] {
        let t = temperature > 0 ? temperature : 1
        guard let top = logits.max() else { return [] }
        var exps = [Double](repeating: 0, count: logits.count)
        var total = 0.0
        for i in logits.indices {
            let e = exp((Double(logits[i]) - Double(top)) / t)
            exps[i] = e
            total += e
        }
        return exps.map { $0 / total }
    }

    public static func entropy<S: Sequence>(_ probabilities: S) -> Double where S.Element == Double {
        var h = 0.0
        for p in probabilities where p > 0 { h -= p * log(p) }
        return h
    }

    /// p = Σ_t w′_t·(λ_t·p_knn,t + (1−λ_t)·p_lm,t) over the open strands with a reed, w′ the gate
    /// renormalised over them. Written as (1−λ̄)·Σ reedW·p_lm + λ̄·Σ knnW·p_knn, which is the same sum.
    public static func mix(experts: [Expert], gates: [Double], open: [Bool], vocabulary: Int) -> Mixture {
        let usable = experts.indices.map { open[$0] && experts[$0].plm != nil }
        let weights = Gate.renormalised(gates, open: usable)
        let active = experts.indices.filter { weights[$0] > 0 }
        var l = 0.0
        var reedWeights = weights
        var knnWeights = weights
        if let first = active.first, active.allSatisfy({ experts[$0].lambda == experts[first].lambda }) {
            l = experts[first].lambda
        } else if !active.isEmpty {
            l = min(max(active.reduce(0.0) { $0 + weights[$1] * experts[$1].lambda }, 0), 1)
            reedWeights = experts.indices.map { t in l < 1 && weights[t] > 0 ? weights[t] * (1 - experts[t].lambda) / (1 - l) : 0 }
            knnWeights = experts.indices.map { t in l > 0 && weights[t] > 0 ? weights[t] * experts[t].lambda / l : 0 }
        }
        var mixed = [Double](repeating: 0, count: vocabulary)
        for t in active {
            let h = reedWeights[t] * (1 - l)
            if h > 0, let p = experts[t].plm { for i in 0..<min(p.count, vocabulary) { mixed[i] += h * p[i] } }
            let q = knnWeights[t] * l
            if q > 0 { for (token, value) in experts[t].knn where token >= 0 && token < vocabulary { mixed[token] += q * value } }
        }
        return Mixture(weights: weights, open: usable, mixed: mixed, lambda: l, reedWeights: reedWeights, knnWeights: knnWeights)
    }

    /// Two tokens whose probabilities are within this fraction of the larger are tied.
    public static let tieBand = 1e-6

    public static func argmax(_ values: [Double]) -> Int {
        var best = 0
        for i in values.indices where values[i] > values[best] { best = i }
        return best
    }

    /// The likeliest token, except at a near-tie: among the tokens within `tieBand` of the
    /// likeliest, the one whose cited text is oldest wins (`age`: smaller is older; nil counts as
    /// newest), then the lower token id. With no near-tie this is `argmax`, exactly.
    public static func choose(_ values: [Double], age: (Int) -> Int64?) -> Int {
        let top = argmax(values)
        guard top < values.count, values[top] > 0 else { return top }
        let floor = values[top] - values[top] * tieBand
        var tied: [Int] = []
        for (token, value) in values.enumerated() where value >= floor { tied.append(token) }
        guard tied.count > 1 else { return top }
        return tied.min { a, b in
            let (ageA, ageB) = (age(a) ?? .max, age(b) ?? .max)
            return ageA != ageB ? ageA < ageB : a < b
        } ?? top
    }

    /// The creation time of the text a token would be cited to: of the hits that predicted it,
    /// the heaviest one's partition.
    public static func citedAge(_ token: Int, experts: [Expert], mixture: Mixture, createdAt: (Int, Int32) -> Int64?) -> Int64? {
        var best: (weight: Double, strand: Int, row: Int32)?
        for t in experts.indices where mixture.weights[t] > 0 {
            for (i, hit) in experts[t].hits.enumerated() where Int(hit.value) == token {
                let weight = mixture.weights[t] * experts[t].weights[i]
                if best == nil || weight > best!.weight { best = (weight, t, hit.row) }
            }
        }
        return best.flatMap { createdAt($0.strand, $0.row) }
    }

    /// A sample from a tempered distribution, top-k (0 = all), with the shared generator.
    public static func sample(_ values: [Double], topK: Int, rng: inout SplitMix64) -> Int {
        var candidates = values.indices.filter { values[$0] > 0 }
        if topK > 0, candidates.count > topK {
            candidates.sort { values[$0] > values[$1] }
            candidates = Array(candidates.prefix(topK))
        }
        let total = candidates.reduce(0.0) { $0 + values[$1] }
        guard total > 0, let last = candidates.last else { return argmax(values) }
        var draw = Double(rng.next() >> 11) / Double(1 << 53) * total
        for token in candidates {
            draw -= values[token]
            if draw <= 0 { return token }
        }
        return last
    }

    /// share_t(y) = w′_t·p_t(y)/p(y): what each strand supplied to the token. Sums to 1.
    public static func shares(_ mixture: Mixture, experts: [Expert], token: Int) -> [Double] {
        let total = token < mixture.mixed.count ? mixture.mixed[token] : 0
        let parts = experts.indices.map { t -> Double in
            guard mixture.weights[t] > 0, let p = experts[t].probability(of: token) else { return 0 }
            return mixture.weights[t] * p
        }
        return experts.indices.map { t in total > 0 ? parts[t] / total : mixture.weights[t] }
    }

    /// The mixture's `count` likeliest tokens, each split by strand as a chosen token is.
    public static func candidates(_ mixture: Mixture, experts: [Expert], count: Int = 3) -> [(token: Int, prob: Double, parts: [Double])] {
        var top: [(token: Int, prob: Double)] = []
        for (token, prob) in mixture.mixed.enumerated() where prob > 0 {
            guard top.count < count || prob > (top.last?.prob ?? 0) else { continue }
            let at = top.firstIndex { prob > $0.prob } ?? top.count
            top.insert((token, prob), at: at)
            if top.count > count { top.removeLast() }
        }
        return top.map { candidate in
            let parts = experts.indices.map { t -> Double in
                guard mixture.weights[t] > 0, let p = experts[t].probability(of: candidate.token) else { return 0 }
                return mixture.weights[t] * p / candidate.prob
            }
            return (candidate.token, candidate.prob, parts)
        }
    }

    /// Bounds on the mixture's entropy from the two stored entropies and the weights: a derived
    /// view, exact only on replay. lower = λ̄·Σ knnW·H_knn + (1−λ̄)·Σ reedW·H_lm;
    /// upper = lower + λ̄·H(knnW) + (1−λ̄)·H(reedW) + H_b(λ̄).
    public static func mixtureEntropyBounds(reedWeights: [Double], knnWeights: [Double], lambda: Double, hlm: [Double?], hknn: [Double]) -> (lower: Double, upper: Double) {
        var lower = 0.0
        for t in reedWeights.indices {
            if let h = hlm[t] { lower += (1 - lambda) * reedWeights[t] * h }
            lower += lambda * knnWeights[t] * hknn[t]
        }
        let hb = lambda > 0 && lambda < 1 ? -(lambda * log(lambda) + (1 - lambda) * log(1 - lambda)) : 0
        let upper = lower + lambda * entropy(knnWeights) + (1 - lambda) * entropy(reedWeights) + hb
        return (lower, upper)
    }
}
