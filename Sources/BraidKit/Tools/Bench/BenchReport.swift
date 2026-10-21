//
//  BenchReport.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: What every bench report shares: a rule's verdict (pass, fail, or skipped because the braid
//        has no subject for it), the formatting the tables use, and where a report lands in the
//        work area. The rules themselves live with their bench (TraceBench, GamingBench, LiftBench).
//  PIN:  Rules are fixed before numbers: a report carries its verdicts and `rescore` recomputes them
//        from the saved readings alone, so a rule text and a saved report can be checked against each
//        other. A bench never changes a default.
//

import BraidCore
import Foundation

public struct BenchRule: Codable, Sendable, Equatable {
    public var id: String
    public var passes: Bool
    public var detail: String
    /// The braid has no subject for the rule (G3 without two Threads holding the same documents).
    public var skipped: Bool

    public init(id: String, passes: Bool, detail: String, skipped: Bool = false) {
        self.id = id
        self.passes = passes
        self.detail = detail
        self.skipped = skipped
    }

    enum CodingKeys: String, CodingKey { case id, passes, detail, skipped }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        passes = try c.decode(Bool.self, forKey: .passes)
        detail = try c.decode(String.self, forKey: .detail)
        skipped = try c.decodeIfPresent(Bool.self, forKey: .skipped) ?? false
    }

    public var verdict: String { skipped ? "SKIP" : (passes ? "PASS" : "FAIL") }
}

/// What `evaluate` hands back for every bench.
public struct BenchVerdict: Sendable, Equatable {
    public var rules: [BenchRule]
    /// Measures with no threshold.
    public var reported: [String: Float]
    public var summary: String

    public init(rules: [BenchRule], reported: [String: Float], summary: String) {
        self.rules = rules
        self.reported = reported
        self.summary = summary
    }

    /// Every rule that was not skipped passes.
    public var passes: Bool { rules.filter { !$0.skipped }.allSatisfy(\.passes) }
}

public enum BenchFormat {
    public static func pct(_ value: Double) -> String { String(format: "%.0f%%", value * 100) }
    public static func pct(_ value: Float) -> String { pct(Double(value)) }
    public static func num(_ value: Double?, _ digits: Int = 3) -> String { value.map { String(format: "%.\(digits)f", $0) } ?? "—" }
    public static func num(_ value: Float?, _ digits: Int = 3) -> String { num(value.map(Double.init), digits) }

    /// The share of `flags` that are true (0 when empty).
    public static func share(_ flags: [Bool]) -> Double { flags.isEmpty ? 0 : Double(flags.filter { $0 }.count) / Double(flags.count) }

    public static func auroc(_ positives: [Double], _ negatives: [Double]) -> Double? {
        Stats.auroc(scores: positives + negatives, labels: positives.map { _ in true } + negatives.map { _ in false })
    }

    /// `bench/<name>/<yyyyMMdd-HHmmss>.json` under the work area.
    public static func reportURL(area: WorkArea, bench: String, at date: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return area.bench.appendingPathComponent(bench, isDirectory: true).appendingPathComponent("\(formatter.string(from: date)).json")
    }

    public static func wholeSecond(_ date: Date = Date()) -> Date { Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)) }
}

/// Holders of the same text (a copy braid): RaoLM's Q5b reading, which G3 shares. Over the exactly
/// answered copied facts, each holder's credit summed over the generated content tokens; the copies
/// tie when the spread is within `band` of their sum, and one took the fact whole when another
/// earned nothing.
public enum CopyTie {
    public static let band: Float = 0.10

    public static func tied(_ credits: [Float], band: Float = band) -> Bool {
        let total = credits.reduce(0, +)
        guard total > 0, let top = credits.max(), let low = credits.min() else { return false }
        return (top - low) / total <= band
    }

    public static func takenWhole(_ credits: [Float]) -> Bool {
        guard let top = credits.max(), let low = credits.min() else { return false }
        return low == 0 && top > 0
    }

    /// Each holder's credit summed over a generation's generated content tokens.
    public static func credits(_ generation: Generation, holders: [String]) -> [Float] {
        let tokens = generation.generatedTokens.filter { $0.credit?.role == .content }
        return holders.map { name in tokens.reduce(Float(0)) { $0 + $1.credit(of: name) } }
    }
}
