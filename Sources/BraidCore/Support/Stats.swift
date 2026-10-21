//
//  Stats.swift
//  BraidCore
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The handful of summary statistics the benches, the trajectory module and the reports
//        use: mean, quantiles, AUROC, Pearson, Spearman, ranks, Cohen's κ, Welch's z.
//

import Foundation

public enum Stats {
    public static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    public static func mean(_ values: [Float]) -> Float { Float(mean(values.map(Double.init))) }

    public static func variance(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let m = mean(values)
        return values.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(values.count - 1)
    }

    /// Linear-interpolated quantile of `values` at `q` in [0, 1]. Sorts a copy.
    public static func quantile(_ values: [Double], _ q: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let position = min(max(q, 0), 1) * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
    }

    /// Area under the ROC curve for scores against binary labels (Mann–Whitney U with average
    /// ranks for ties). Nil when either class is empty.
    public static func auroc(scores: [Double], labels: [Bool]) -> Double? {
        precondition(scores.count == labels.count)
        let positives = labels.filter { $0 }.count
        let negatives = labels.count - positives
        guard positives > 0, negatives > 0 else { return nil }
        let r = ranks(scores)
        var positiveRankSum = 0.0
        for index in labels.indices where labels[index] { positiveRankSum += r[index] }
        let u = positiveRankSum - Double(positives) * Double(positives + 1) / 2
        return u / (Double(positives) * Double(negatives))
    }

    /// 1-based ranks of `values`, ties sharing their average rank.
    public static func ranks(_ values: [Double]) -> [Double] {
        let order = values.indices.sorted { values[$0] < values[$1] }
        var ranks = [Double](repeating: 0, count: values.count)
        var i = 0
        while i < order.count {
            var j = i
            while j + 1 < order.count, values[order[j + 1]] == values[order[i]] { j += 1 }
            let average = Double(i + j) / 2 + 1
            for k in i...j { ranks[order[k]] = average }
            i = j + 1
        }
        return ranks
    }

    public static func spearman(_ x: [Double], _ y: [Double]) -> Double? {
        guard x.count == y.count, x.count >= 3 else { return nil }
        return pearson(ranks(x), ranks(y))
    }

    public static func pearson(_ x: [Double], _ y: [Double]) -> Double? {
        guard x.count == y.count, x.count >= 3, x.allSatisfy(\.isFinite), y.allSatisfy(\.isFinite) else { return nil }
        guard let xMin = x.min(), let xMax = x.max(), xMin < xMax, let yMin = y.min(), let yMax = y.max(), yMin < yMax else { return nil }
        let mx = mean(x), my = mean(y)
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for i in x.indices {
            let dx = x[i] - mx, dy = y[i] - my
            sxy += dx * dy
            sxx += dx * dx
            syy += dy * dy
        }
        guard sxx > 0, syy > 0 else { return nil }
        let r = sxy / (sxx * syy).squareRoot()
        return r.isFinite ? min(max(r, -1), 1) : nil
    }

    /// Ordinary least-squares slope of `values` against their indices; nil below two points.
    public static func slope(_ values: [Double]) -> Double? {
        guard values.count >= 2 else { return nil }
        let n = Double(values.count)
        let mx = (n - 1) / 2
        let my = mean(values)
        var sxy = 0.0, sxx = 0.0
        for (i, y) in values.enumerated() {
            let dx = Double(i) - mx
            sxy += dx * (y - my)
            sxx += dx * dx
        }
        return sxx > 0 ? sxy / sxx : nil
    }

    /// Cohen's κ between two binary series of equal length; nil when either is constant and they agree trivially.
    public static func cohenKappa(_ a: [Bool], _ b: [Bool]) -> Double? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        let n = Double(a.count)
        var agree = 0.0, aTrue = 0.0, bTrue = 0.0
        for (x, y) in zip(a, b) {
            if x == y { agree += 1 }
            if x { aTrue += 1 }
            if y { bTrue += 1 }
        }
        let po = agree / n
        let pe = (aTrue / n) * (bTrue / n) + (1 - aTrue / n) * (1 - bTrue / n)
        guard pe < 1 else { return nil }
        return (po - pe) / (1 - pe)
    }

    /// Welch's z (the t statistic with large-sample normal reading) for mean(a) − mean(b); nil below two per side.
    public static func welchZ(_ a: [Double], _ b: [Double]) -> Double? {
        guard a.count >= 2, b.count >= 2 else { return nil }
        let se = (variance(a) / Double(a.count) + variance(b) / Double(b.count)).squareRoot()
        guard se > 0 else { return nil }
        return (mean(a) - mean(b)) / se
    }
}

/// SplitMix64: a small, seedable generator for sampling and seeded draws, the same stream everywhere.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
