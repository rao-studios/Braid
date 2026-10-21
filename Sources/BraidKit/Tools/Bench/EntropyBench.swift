//
//  EntropyBench.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: `braid bench entropy`: whether the entropy path calls what the trace calls. On the trace
//        bench's texts, per Thread per position from 24: a coherent run (H_knn ≤ ln 2 for ≥ 24
//        consecutive positions, the module's call) against in-trace (the chain has followed one
//        document for ≥ 24 tokens, the trace's call). E1: Cohen's κ between the two ≥ 0.6 on the
//        holders of held, told and source texts. E2: the coherent fraction ≤ 0.10 on ≥ 90% of the
//        null texts. E3 (reported only): which calls first, and where they disagree, the module's
//        four-way labels.
//  PIN:  Rules fixed before any numbers (the plan's bench table, E1–E3). The nulls are the trace
//        bench's: shuffled and collage (their Thread), voice, voice-shuffled and generic (every
//        Thread), told and source (every Thread but the holder); a null text counts by its largest
//        coherent fraction. `evaluate` is pure over the saved readings; the session log is kept.
//

import BraidCore
import Foundation

public struct EntropyReading: Codable, Sendable, Equatable {
    public var thread: String
    /// From `from` on: the share of positions inside a coherent run, and in trace.
    public var coherent: Float
    public var inTrace: Float
    /// Positions from `from`: [coherent ∧ in trace, coherent only, in trace only, neither].
    public var agreement: [Int]
    /// The first position where a coherent run reaches its length, and where the chain reaches the phrase.
    public var coherentCall: Int?
    public var traceCall: Int?
    /// The module's labels where the two disagree (positions from `from`).
    public var coherentOnlyLabels: [String: Int]
    public var traceOnlyLabels: [String: Int]

    public init(thread: String, coherent: Float, inTrace: Float, agreement: [Int], coherentCall: Int?, traceCall: Int?,
                coherentOnlyLabels: [String: Int] = [:], traceOnlyLabels: [String: Int] = [:]) {
        self.thread = thread
        self.coherent = coherent
        self.inTrace = inTrace
        self.agreement = agreement
        self.coherentCall = coherentCall
        self.traceCall = traceCall
        self.coherentOnlyLabels = coherentOnlyLabels
        self.traceOnlyLabels = traceOnlyLabels
    }
}

public struct EntropyText: Codable, Sendable, Equatable {
    public var kind: BenchTextKind
    public var label: String
    public var owner: String?
    public var near: String?
    public var tokens: Int
    public var readings: [EntropyReading]

    public init(kind: BenchTextKind, label: String, owner: String?, near: String?, tokens: Int, readings: [EntropyReading]) {
        self.kind = kind
        self.label = label
        self.owner = owner
        self.near = near
        self.tokens = tokens
        self.readings = readings
    }

    public func reading(_ thread: String?) -> EntropyReading? {
        guard let thread else { return nil }
        return readings.first { $0.thread == thread }
    }
}

public struct EntropyReport: Codable, Sendable {
    public var bench = "entropy"
    public var createdAt: Date
    public var dataset: String
    public var threads: [String: String]
    public var gate: GateSettings
    public var module: ModuleSettings
    public var phrase: Int
    public var from: Int
    public var sizes: BenchTextSizes
    public var texts: [EntropyText]
    public var rules: [BenchRule]
    public var reported: [String: Float]
    public var summary: String
    public var sessions: [String]? = nil
}

public enum EntropyBench {
    public static let from = TraceBench.from

    public static func run(braid: BenchBraid, world: BenchWorld, sizes: BenchTextSizes = BenchTextSizes(), progress: ((String) -> Void)? = nil) throws -> EntropyReport {
        let threads = try braid.benchThreads(world: world) { progress?("warning: \($0)") }
        let texts = BenchTexts.build(world: world, threads: threads, tokenizer: braid.tokenizer, byteOffsets: braid.tokenizer.byteOffsets,
                                     paragraphBreak: braid.tokenizer.paragraphBreak, sizes: sizes)
        progress?("texts: " + BenchTexts.census(texts))
        try braid.keepSession()
        defer { braid.finishSession() }
        let module = braid.settings.module ?? ModuleSettings()
        let phrase = braid.settings.trace.phrase
        var results: [EntropyText] = []
        let started = Date()
        for (i, text) in texts.enumerated() {
            if i % 25 == 0 { progress?(String(format: "scoring %d/%d (%.0f s)", i, texts.count, Date().timeIntervalSince(started))) }
            let generation = try braid.score(text.tokens)
            results.append(EntropyText(kind: text.kind, label: text.label, owner: text.owner, near: text.near, tokens: text.tokens.count,
                                       readings: readings(generation, names: braid.names, commons: braid.commonsIndex, settings: module, phrase: phrase)))
            if i % 8 == 7 { braid.relax() }
        }
        let verdict = evaluate(texts: results)
        return EntropyReport(createdAt: BenchFormat.wholeSecond(), dataset: world.name, threads: braid.threadRecords, gate: braid.settings.gate, module: module,
                             phrase: phrase, from: from, sizes: sizes, texts: results, rules: verdict.rules, reported: verdict.reported, summary: verdict.summary,
                             sessions: braid.sessions.map(\.path))
    }

    /// Every Thread's reading of one scoring.
    public static func readings(_ generation: Generation, names: [String], commons: Int?, settings: ModuleSettings, phrase: Int) -> [EntropyReading] {
        let series = TrajectoryModule.series(generation.steps, commons: commons)
        let positions = generation.steps.filter { $0.source != .ctx && $0.threads != nil }
        return names.indices.compactMap { t -> EntropyReading? in
            guard t != commons, t < series.count else { return nil }
            let lengths = positions.map { step in t < (step.threads?.count ?? 0) ? step.threads![t].trace?.length ?? 0 : 0 }
            return reading(thread: names[t], series: series[t], lengths: lengths, settings: settings, phrase: phrase)
        }
    }

    /// One Thread's reading from its series and its chain lengths (aligned, one per position).
    public static func reading(thread: String, series: ThreadSeries, lengths: [Int], settings: ModuleSettings, phrase: Int) -> EntropyReading {
        let all = TrajectoryModule.readAll(series, settings: settings)
        let n = min(all.count, lengths.count)
        var agreement = [0, 0, 0, 0]
        var coherentOnly: [String: Int] = [:]
        var traceOnly: [String: Int] = [:]
        var coherentCount = 0
        var traceCount = 0
        for i in from ..< max(from, n) {
            let coherent = all[i].coherent
            let inTrace = lengths[i] >= phrase
            if coherent { coherentCount += 1 }
            if inTrace { traceCount += 1 }
            switch (coherent, inTrace) {
            case (true, true): agreement[0] += 1
            case (true, false): agreement[1] += 1; coherentOnly[all[i].label.rawValue, default: 0] += 1
            case (false, true): agreement[2] += 1; traceOnly[all[i].label.rawValue, default: 0] += 1
            case (false, false): agreement[3] += 1
            }
        }
        let counted = max(n - from, 0)
        return EntropyReading(thread: thread, coherent: counted > 0 ? Float(coherentCount) / Float(counted) : 0,
                              inTrace: counted > 0 ? Float(traceCount) / Float(counted) : 0, agreement: agreement,
                              coherentCall: coherentCall(series.hknn, settings: settings), traceCall: lengths.firstIndex { $0 >= phrase },
                              coherentOnlyLabels: coherentOnly, traceOnlyLabels: traceOnly)
    }

    /// The first position at which `coherentRun` consecutive positions have H_knn ≤ `coherent`: the
    /// entropy path's call, made causally at the run's last position.
    public static func coherentCall(_ hknn: [Double], settings: ModuleSettings) -> Int? {
        var run = 0
        for (i, h) in hknn.enumerated() {
            run = h <= settings.coherent ? run + 1 : 0
            if run >= settings.coherentRun { return i }
        }
        return nil
    }

    /// Cohen's κ from a 2×2 table [both, first only, second only, neither]; nil when chance agreement is 1.
    public static func kappa(_ table: [Int]) -> Double? {
        guard table.count == 4 else { return nil }
        let n = Double(table.reduce(0, +))
        guard n > 0 else { return nil }
        let (a, b, c, d) = (Double(table[0]), Double(table[1]), Double(table[2]), Double(table[3]))
        let observed = (a + d) / n
        let chance = ((a + b) / n) * ((a + c) / n) + ((c + d) / n) * ((b + d) / n)
        guard chance < 1 else { return nil }
        return (observed - chance) / (1 - chance)
    }

    /// The null texts and, per text, the largest coherent fraction among its null readings.
    public static func nulls(_ texts: [EntropyText]) -> [(text: EntropyText, coherent: Float)] {
        texts.compactMap { text in
            let readings: [EntropyReading]
            switch text.kind {
            case .shuffled, .collage: readings = text.reading(text.owner).map { [$0] } ?? []
            case .voice, .voiceShuffled, .generic: readings = text.readings
            case .told, .source: readings = text.readings.filter { $0.thread != text.owner }
            case .held: return nil
            }
            guard !readings.isEmpty else { return nil }
            return (text, readings.map(\.coherent).max() ?? 0)
        }
    }

    public static func rescore(_ report: EntropyReport) -> EntropyReport {
        var rescored = report
        let verdict = evaluate(texts: report.texts)
        rescored.rules = verdict.rules
        rescored.reported = verdict.reported
        rescored.summary = verdict.summary
        return rescored
    }

    // MARK: - The rule (pure)

    /// E1: Cohen's κ, pooled over the positions from 24 of the holders of held, told and source texts,
    /// between "inside a coherent run" and "in trace" ≥ 0.6. E2: the coherent fraction ≤ 0.10 on ≥ 90%
    /// of the null texts. E3 is reported only.
    public static func evaluate(texts: [EntropyText]) -> BenchVerdict {
        let share = BenchFormat.share
        func pct(_ value: Double) -> String { BenchFormat.pct(value) }
        func num(_ value: Double?) -> String { BenchFormat.num(value) }
        var rules: [BenchRule] = []
        var reported: [String: Float] = [:]
        func pooled(_ readings: [EntropyReading]) -> [Int] {
            readings.reduce([0, 0, 0, 0]) { sum, reading in zip(sum, reading.agreement).map { $0 + $1 } }
        }
        let holderKinds: [BenchTextKind] = [.held, .told, .source]
        let holders = texts.filter { holderKinds.contains($0.kind) }.compactMap { $0.reading($0.owner) }
        let table = pooled(holders)
        let k = kappa(table)
        rules.append(BenchRule(
            id: "E1 coherent run is the trace", passes: !holders.isEmpty && (k ?? -1) >= 0.6,
            detail: "Cohen's κ \(num(k)) (needs 0.6) over \(table.reduce(0, +)) positions of \(holders.count) holders of held, told and source: "
                + "both \(table[0]), coherent only \(table[1]), in trace only \(table[2]), neither \(table[3])"))
        for kind in holderKinds {
            let mine = texts.filter { $0.kind == kind }.compactMap { $0.reading($0.owner) }
            if let value = kappa(pooled(mine)) { reported["E1 \(kind.rawValue): κ"] = Float(value) }
            reported["E1 \(kind.rawValue): holder's coherent fraction (mean)"] = Float(Stats.mean(mine.map { Double($0.coherent) }))
            reported["E1 \(kind.rawValue): holder in trace (mean)"] = Float(Stats.mean(mine.map { Double($0.inTrace) }))
        }

        let nullTexts = nulls(texts)
        let quiet = share(nullTexts.map { $0.coherent <= 0.10 })
        rules.append(BenchRule(
            id: "E2 nobody's text is not coherent", passes: !nullTexts.isEmpty && quiet >= 0.9,
            detail: "coherent fraction ≤ 0.10 on \(pct(quiet)) of \(nullTexts.count) null texts (needs 90%)"))
        for kind in BenchTextKind.allCases where kind != .held {
            let mine = nullTexts.filter { $0.text.kind == kind }
            guard !mine.isEmpty else { continue }
            reported["E2 \(kind.rawValue): coherent ≤ 0.10"] = Float(share(mine.map { $0.coherent <= 0.10 }))
            reported["E2 \(kind.rawValue): coherent fraction (mean)"] = Float(Stats.mean(mine.map { Double($0.coherent) }))
        }

        // E3: who calls first, and the module's labels where they disagree.
        let called = holders.filter { $0.coherentCall != nil && $0.traceCall != nil }
        let leads = called.map { Double($0.coherentCall! - $0.traceCall!) }
        reported["E3 holders with both calls"] = Float(called.count)
        reported["E3 holders with neither call"] = Float(holders.filter { $0.coherentCall == nil && $0.traceCall == nil }.count)
        reported["E3 holders: trace only called"] = Float(holders.filter { $0.coherentCall == nil && $0.traceCall != nil }.count)
        reported["E3 holders: coherent only called"] = Float(holders.filter { $0.coherentCall != nil && $0.traceCall == nil }.count)
        if !leads.isEmpty {
            reported["E3 lead/lag: coherent call − trace call (mean positions)"] = Float(Stats.mean(leads))
            reported["E3 lead/lag: coherent call − trace call (median positions)"] = Float(Stats.quantile(leads, 0.5))
            reported["E3 lead/lag: the entropy path calls first"] = Float(share(leads.map { $0 < 0 }))
        }
        let nullReadings = texts.flatMap { text -> [EntropyReading] in
            switch text.kind {
            case .shuffled, .collage: return text.reading(text.owner).map { [$0] } ?? []
            case .voice, .voiceShuffled, .generic: return text.readings
            case .told, .source: return text.readings.filter { $0.thread != text.owner }
            case .held: return []
            }
        }
        for (group, readings) in [("holders", holders), ("nulls", nullReadings)] {
            let t = pooled(readings)
            reported["E3 \(group): coherent ∧ ¬trace positions"] = Float(t[1])
            reported["E3 \(group): trace ∧ ¬coherent positions"] = Float(t[2])
            var coherentOnly: [String: Int] = [:]
            var traceOnly: [String: Int] = [:]
            for reading in readings {
                for (label, count) in reading.coherentOnlyLabels { coherentOnly[label, default: 0] += count }
                for (label, count) in reading.traceOnlyLabels { traceOnly[label, default: 0] += count }
            }
            for label in ["retrieval", "stitched", "unknown", "commons", "silent"] {
                reported["E3 \(group): coherent ∧ ¬trace labelled \(label)"] = Float(coherentOnly[label] ?? 0)
                reported["E3 \(group): trace ∧ ¬coherent labelled \(label)"] = Float(traceOnly[label] ?? 0)
            }
        }

        let failed = rules.filter { !$0.passes }.map(\.id)
        return BenchVerdict(rules: rules, reported: reported, summary: failed.isEmpty ? "E1 and E2 pass" : "failed: " + failed.joined(separator: ", "))
    }
}
