//
//  ReplacementBench.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: `braid bench replacement`: the owner's replacement criterion, read from saved reports.
//        Sessions A ran the live gate memory-only (κ 0) with the shadow β4 logged beside the module's
//        e_t; sessions B ran κ > 0 (0.5) on the same prompts, braid and pack. R1: on the trace bench's
//        told and source answer tokens, the holder's share in B ≥ the holder's share under the shadow
//        β4 logged in A. R2: G1–G3 pass in B, with the largest gate within 0.05 and the all-asked rate
//        within 5 points of A's. R3: `braid verify`'s memory-recursion replay passes on every B session
//        (the logs carry `mod`, so the replay re-enters the module's evidence: the clamp held).
//  PIN:  Fixed before any numbers (the plan, "Replacement criterion"). It reads; it decides nothing
//        and deletes nothing. When R1–R3 hold the owner's rule is applied on main.
//

import BraidCore
import Foundation

/// What `braid verify` found on one session (read from `<session>.verify.json`).
public struct SessionVerification: Codable, Sendable, Equatable {
    public var session: String
    /// Whether the verify report was there.
    public var verified: Bool
    public var status: String?
    public var generations: Int?
    /// Issues by check (memory, shares, weights, p, Hknn, shadow, trace, body, …).
    public var issues: [String: Int]

    public init(session: String, verified: Bool, status: String?, generations: Int?, issues: [String: Int]) {
        self.session = session
        self.verified = verified
        self.status = status
        self.generations = generations
        self.issues = issues
    }

    /// `X.jsonl` → `X.verify.json`, as `braid verify` writes it.
    public static func reportURL(session: URL) -> URL { session.deletingPathExtension().appendingPathExtension("verify.json") }

    public static func read(session: URL) -> SessionVerification {
        guard let report = try? JSONCoding.read(VerifyReport.self, from: reportURL(session: session)) else {
            return SessionVerification(session: session.path, verified: false, status: nil, generations: nil, issues: [:])
        }
        var issues: [String: Int] = [:]
        for issue in report.issues { issues[issue.check, default: 0] += 1 }
        return SessionVerification(session: session.path, verified: true, status: report.status.rawValue, generations: report.generations, issues: issues)
    }
}

public struct ReplacementReport: Codable, Sendable {
    public var bench = "replacement"
    public var createdAt: Date
    /// The reports read: trace A and B, gaming A and B.
    public var inputs: [String: String]
    public var moduleGainA: Double?
    public var moduleGainB: Double?
    public var sessions: [SessionVerification]
    public var rules: [BenchRule]
    public var reported: [String: Float]
    public var summary: String
}

public enum ReplacementBench {
    public static let holderSet = "holder · told+source"

    public static func run(traceA: TraceReport, traceB: TraceReport, gamingA: GamingReport, gamingB: GamingReport, inputs: [String: String]) -> ReplacementReport {
        let sessions = ((traceB.sessions ?? []) + (gamingB.sessions ?? [])).map { SessionVerification.read(session: URL(fileURLWithPath: $0)) }
        let verdict = evaluate(traceA: traceA, traceB: traceB, gamingA: gamingA, gamingB: gamingB, sessions: sessions)
        return ReplacementReport(createdAt: BenchFormat.wholeSecond(), inputs: inputs, moduleGainA: traceA.gate?.moduleGain, moduleGainB: traceB.gate?.moduleGain,
                                 sessions: sessions, rules: verdict.rules, reported: verdict.reported, summary: verdict.summary)
    }

    /// The share every Thread was open at the first generated token, and the mean largest Thread gate, of one gaming set.
    static func guardReading(_ report: GamingReport, _ set: GamingSet) -> (open: Double, largest: Double, prompts: Int) {
        let rows = report.rows.filter { $0.set == set }
        return (BenchFormat.share(rows.map(\.allOpen)), Stats.mean(rows.map { Double($0.largestGate) }), rows.count)
    }

    // MARK: - The rule (pure)

    public static func evaluate(traceA: TraceReport, traceB: TraceReport, gamingA: GamingReport, gamingB: GamingReport, sessions: [SessionVerification]) -> BenchVerdict {
        func num(_ value: Double?, _ digits: Int = 7) -> String { BenchFormat.num(value, digits) }
        var rules: [BenchRule] = []
        var reported: [String: Float] = [:]
        // A is κ 0 and B is κ > 0 on the same braid and prompts.
        var setup: [String] = []
        let kappaA = traceA.gate?.moduleGain ?? -1
        let kappaB = traceB.gate?.moduleGain ?? -1
        if kappaA != 0 { setup.append("trace A ran κ \(kappaA), not 0") }
        if kappaB <= 0 { setup.append("trace B ran κ \(kappaB), not above 0") }
        if gamingA.gate.moduleGain != 0 { setup.append("gaming A ran κ \(gamingA.gate.moduleGain), not 0") }
        if gamingB.gate.moduleGain <= 0 { setup.append("gaming B ran κ \(gamingB.gate.moduleGain), not above 0") }
        if traceA.threads != traceB.threads || traceA.dataset != traceB.dataset { setup.append("trace A and B ran on different braids or datasets") }
        if gamingA.threads != gamingB.threads || gamingA.dataset != gamingB.dataset || gamingA.copyPair != gamingB.copyPair { setup.append("gaming A and B ran on different braids") }
        if traceA.texts.map(\.label) != traceB.texts.map(\.label) { setup.append("trace A and B scored different texts") }
        if gamingA.rows.map(\.label) != gamingB.rows.map(\.label) { setup.append("gaming A and B asked different prompts") }
        let consistent = setup.isEmpty

        // R1.
        let a = traceA.arms.first { $0.set == holderSet }
        let b = traceB.arms.first { $0.set == holderSet }
        let shadowA = a?.shadow.map(Double.init)
        let liveB = b?.live.map(Double.init)
        let r1 = consistent && shadowA != nil && liveB != nil && liveB! >= shadowA! && a?.answerTokens == b?.answerTokens
        rules.append(BenchRule(
            id: "R1 the module amplifies as the shadow did", passes: r1,
            detail: "the holder's share of \(b?.answerTokens ?? 0) told and source answer tokens in B (κ \(kappaB)) \(num(liveB)) against the shadow β4's in A \(num(shadowA)) "
                + "(A's live \(num(a?.live.map(Double.init))), B's shadow \(num(b?.shadow.map(Double.init))))" + (consistent ? "" : "; " + setup.joined(separator: "; "))))
        if let shadowA, let liveB { reported["R1 B live − A shadow"] = Float(liveB - shadowA) }

        // R2.
        let gamingRules = ["G1 unknown subjects", "G2 generic text", "G3 copy braid"]
        var r2Failures: [String] = []
        for id in gamingRules {
            guard let rule = gamingB.rules.first(where: { $0.id == id }) else { r2Failures.append("\(id) not in B"); continue }
            if rule.skipped { r2Failures.append("\(id) skipped in B") } else if !rule.passes { r2Failures.append("\(id) fails in B") }
        }
        var moves: [String] = []
        for set in [GamingSet.unknown, .generic] {
            let ra = guardReading(gamingA, set)
            let rb = guardReading(gamingB, set)
            let gateMove = abs(rb.largest - ra.largest)
            let openMove = abs(rb.open - ra.open)
            reported["R2 \(set.rawValue): largest gate B − A"] = Float(rb.largest - ra.largest)
            reported["R2 \(set.rawValue): every Thread open B − A"] = Float(rb.open - ra.open)
            if gateMove > 0.05 + 1e-9 { r2Failures.append(String(format: "%@: the largest gate moved %.3f", set.rawValue, gateMove)) }
            if openMove > 0.05 + 1e-9 { r2Failures.append(String(format: "%@: the all-asked rate moved %.0f points", set.rawValue, openMove * 100)) }
            moves.append(String(format: "%@ largest gate %.3f → %.3f, all asked %.0f%% → %.0f%%", set.rawValue, ra.largest, rb.largest, ra.open * 100, rb.open * 100))
        }
        if !consistent { r2Failures.append(contentsOf: setup) }
        rules.append(BenchRule(
            id: "R2 the guards hold in B", passes: r2Failures.isEmpty,
            detail: moves.joined(separator: "; ") + (r2Failures.isEmpty ? "" : "; " + r2Failures.joined(separator: "; "))))

        // R3.
        let missing = sessions.filter { !$0.verified }
        let memory = sessions.reduce(0) { $0 + ($1.issues["memory"] ?? 0) }
        var other: [String: Int] = [:]
        for session in sessions { for (check, count) in session.issues where check != "memory" { other[check, default: 0] += count } }
        let r3 = !sessions.isEmpty && missing.isEmpty && memory == 0
        var detail = "\(sessions.count - missing.count) of \(sessions.count) B sessions verified; \(memory) memory-recursion issues"
        if !missing.isEmpty { detail += "; no verify report for " + missing.map { URL(fileURLWithPath: $0.session).lastPathComponent }.joined(separator: ", ") + " (run braid verify on it)" }
        if !other.isEmpty { detail += "; other checks: " + other.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") }
        rules.append(BenchRule(id: "R3 the clamp held", passes: r3, detail: detail))

        // Trace is gate-independent: A's and B's readings must be the same.
        var largest: Float = 0
        for (x, y) in zip(traceA.texts, traceB.texts) {
            for (u, v) in zip(x.readings, y.readings) where u.thread == v.thread { largest = max(largest, abs(u.trace - v.trace)) }
        }
        reported["trace readings: largest |A − B|"] = largest

        let failed = rules.filter { !$0.passes }.map(\.id)
        let summary = failed.isEmpty ? "R1 to R3 hold: by the owner's rule the entropy path takes over steering and the shadow β4 is deleted (to be applied on main)"
            : "failed: \(failed.joined(separator: ", ")); the live gate stays memory-only and the shadow β4 stays logged"
        return BenchVerdict(rules: rules, reported: reported, summary: summary)
    }
}
