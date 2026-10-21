//
//  TrajectoryModule.swift
//  BraidCore
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The entropy path. Per strand, over its recorded series of (H_lm, H_knn, trace, lift):
//        the slope of H_knn over a window, a short-horizon forecast, the lift evidence e_t that
//        steers (step 7, through the gate's one clamp), and the stitched signature — H_lm collapsed
//        while H_knn does not concentrate and the lift over the commons is high: knowledge the
//        delta absorbed parametrically that the index does not support.
//  PIN:  Pure and causal: a reading at j uses positions ≤ j only, so the offline module over a log
//        and the live module in a session read the same numbers. Trace never feeds the evidence;
//        it is the ground truth the entropy path is benched against. Directional rules are
//        hypotheses the benches test, not axioms.
//

import Foundation

public struct ModuleSettings: Codable, Sendable, Equatable {
    /// Positions of H_knn the slope is fitted over, and how many must be defined.
    public var window = 8
    public var minimumPoints = 4
    /// Positions ahead the forecast reaches.
    public var horizon = 4
    /// The retrieval k: H_knn ≤ ln k.
    public var k = 16
    /// The stitched signature: H_lm,t ≤ thetaLM·H_lm,c; H_knn,t ≥ thetaKNN·ln k; lift ≥ thetaLift; for ≥ span positions.
    public var thetaLM = 0.5
    public var thetaKNN = 0.5
    public var thetaLift = log(2.0)
    public var span = 8
    /// A "coherent run": H_knn ≤ coherent for ≥ coherentRun positions (the entropy path's call that trace verifies).
    public var coherent = log(2.0)
    public var coherentRun = 24

    public init() {}

    /// The slope that counts as a full collapse or divergence: ln k over a window.
    public var referenceSlope: Double { log(Double(k)) / Double(window) }
}

public enum ModuleLabel: String, Codable, Sendable {
    /// H_lm collapsed and H_knn concentrates: ordinary retrieval.
    case retrieval
    /// H_lm collapsed, H_knn not concentrating, lift high: parametric leakage.
    case stitched
    /// H_lm high, H_knn not concentrating: the strand does not know.
    case unknown
    /// The commons predicts the token at least as well (lift ≤ 0).
    case commons
    /// Too few points, or not asked.
    case silent
}

public struct ModuleReading: Codable, Sendable, Equatable {
    public var slope: Double?
    public var forecast: Double?
    /// e_t ∈ [−1, 1]: collapse → up, divergence above the commons while privately unsure → down.
    public var evidence: Double
    public var label: ModuleLabel
    /// Whether this position is inside a stitched run of ≥ `span` positions.
    public var stitched: Bool
    public var coherent: Bool
}

/// One strand's recorded series over a generation.
public struct ThreadSeries: Sendable, Equatable {
    public var hlm: [Double?]
    public var hknn: [Double]
    public var lift: [Double?]
    public var trace: [Float]
    /// The commons' H_lm at the same positions (nil without a commons).
    public var commonsHLM: [Double?]

    public init(hlm: [Double?], hknn: [Double], lift: [Double?], trace: [Float], commonsHLM: [Double?]) {
        self.hlm = hlm
        self.hknn = hknn
        self.lift = lift
        self.trace = trace
        self.commonsHLM = commonsHLM
    }

    public var count: Int { hknn.count }
}

public enum TrajectoryModule {
    /// The series of every strand from a generation's steps, read the way the live module reads them:
    /// a strand's own context positions first (its ctx lines: no lift, no commons H_lm), then every
    /// prompt and generated position with strands. Assumes no attach or detach inside the generation.
    public static func series(_ steps: [Step], commons: Int?) -> [ThreadSeries] {
        let positions = steps.filter { $0.source != .ctx && $0.threads != nil }
        guard let first = positions.first?.threads else { return [] }
        let shared = positions.filter { $0.threads!.count == first.count }
        return first.indices.map { t in
            let own = steps.filter { $0.source == .ctx && $0.owner == t }.compactMap { $0.threads?.first }
            return ThreadSeries(
                hlm: own.map { $0.hlm.map(Double.init) } + shared.map { $0.threads![t].hlm.map(Double.init) },
                hknn: own.map { Double($0.hknn) } + shared.map { Double($0.threads![t].hknn) },
                lift: own.map { _ in nil } + shared.map { step in
                    guard let c = commons, t != c, let own = step.threads![t].plm, let base = step.threads![c].plm else { return nil }
                    return log(Double(max(own, 1e-30))) - log(Double(max(base, 1e-30)))
                },
                trace: own.map { $0.trace?.trace ?? 0 } + shared.map { $0.threads![t].trace?.trace ?? 0 },
                commonsHLM: own.map { _ in nil } + shared.map { step in commons.flatMap { step.threads![$0].hlm.map(Double.init) } })
        }
    }

    /// How many context positions strand t's series opens with (the offset of the shared positions).
    public static func contextCount(_ steps: [Step], strand t: Int) -> Int {
        steps.filter { $0.source == .ctx && $0.owner == t && $0.threads != nil }.count
    }

    /// The reading at position j, from positions ≤ j only.
    public static func read(_ s: ThreadSeries, at j: Int, settings: ModuleSettings = ModuleSettings()) -> ModuleReading {
        let start = max(0, j - settings.window + 1)
        let window = Array(s.hknn[start...j])
        var slope: Double?
        var forecast: Double?
        var evidence = 0.0
        if window.count >= settings.minimumPoints, let fitted = Stats.slope(window) {
            slope = fitted
            forecast = min(max(s.hknn[j] + Double(settings.horizon) * fitted, 0), log(Double(settings.k)))
            let collapse = min(max(-fitted / settings.referenceSlope, 0), 1)
            var divergence = min(max(fitted / settings.referenceSlope, 0), 1)
            if let own = s.hlm[j], let base = s.commonsHLM[j] {
                if !(s.hknn[j] > base && own > base) { divergence = 0 }
            } else {
                divergence = 0
            }
            evidence = collapse - divergence
        }
        let lnk = log(Double(settings.k))
        var label = ModuleLabel.silent
        if let own = s.hlm[j], let lift = s.lift[j] {
            let base = s.commonsHLM[j] ?? lnk
            let collapsed = own <= settings.thetaLM * base
            let unsupported = s.hknn[j] >= settings.thetaKNN * lnk
            if lift <= 0 { label = .commons }
            else if collapsed && unsupported && lift >= settings.thetaLift { label = .stitched }
            else if collapsed && !unsupported { label = .retrieval }
            else if !collapsed && unsupported { label = .unknown }
            else { label = .retrieval }
        }
        return ModuleReading(slope: slope, forecast: forecast, evidence: evidence, label: label, stitched: false,
                             coherent: s.hknn[j] <= settings.coherent)
    }

    /// Every position's reading, with stitched runs (≥ span consecutive stitched labels) and
    /// coherent runs (≥ coherentRun consecutive low H_knn) marked.
    public static func readAll(_ s: ThreadSeries, settings: ModuleSettings = ModuleSettings()) -> [ModuleReading] {
        var readings = (0..<s.count).map { read(s, at: $0, settings: settings) }
        markRuns(&readings, settings: settings)
        return readings
    }

    static func markRuns(_ readings: inout [ModuleReading], settings: ModuleSettings) {
        // Stitched: inside any run of ≥ span consecutive stitched labels.
        let stitched = runs(readings.map { $0.label == .stitched }, atLeast: settings.span)
        // Coherent: inside any run of ≥ coherentRun consecutive positions with H_knn ≤ coherent.
        let coherent = runs(readings.map(\.coherent), atLeast: settings.coherentRun)
        for j in readings.indices {
            readings[j].stitched = stitched[j]
            readings[j].coherent = coherent[j]
        }
    }

    /// Marks every position inside a maximal run of `true` of length ≥ `atLeast`.
    static func runs(_ flags: [Bool], atLeast: Int) -> [Bool] {
        var marked = [Bool](repeating: false, count: flags.count)
        var start = 0
        while start < flags.count {
            guard flags[start] else { start += 1; continue }
            var end = start
            while end < flags.count, flags[end] { end += 1 }
            if end - start >= atLeast { for k in start..<end { marked[k] = true } }
            start = end
        }
        return marked
    }

    /// The detector's score for a text: the share of positions from `from` inside a stitched run.
    public static func detectorScore(_ readings: [ModuleReading], from: Int = 24) -> Double {
        let tail = readings.dropFirst(from)
        guard !tail.isEmpty else { return 0 }
        return Double(tail.filter(\.stitched).count) / Double(tail.count)
    }

    /// The share of positions from `from` inside a coherent run (the entropy path's "coherent run" call).
    public static func coherentFraction(_ readings: [ModuleReading], from: Int = 24) -> Double {
        let tail = readings.dropFirst(from)
        guard !tail.isEmpty else { return 0 }
        return Double(tail.filter(\.coherent).count) / Double(tail.count)
    }
}
