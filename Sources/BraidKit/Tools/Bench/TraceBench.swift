//
//  TraceBench.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: `braid bench trace`: whether a Thread's trace tells its own text from a pastiche of it, and
//        what the holder earns on told and source answers under the live gate and under the shadow β4.
//        Every text is scored through the cluster with every Thread asked and nothing generated; per
//        Thread per text: the mean trace from token 24, the longest chain, the token-local baselines,
//        and its share of the answer tokens (live and shadow, from the same pass). Rules T1 to T3 are
//        RaoLM's, fixed before any numbers (RaoLM Docs/BRAID.md, "Choosing the trajectory"); the arms
//        carry no threshold. Manner is gone, so M1 to M4 are not here.
//  PIN:  `evaluate` is pure over the saved readings, so `--rescore` re-applies the rules to a report
//        without a model. Nothing is written to a node.
//

import BraidCore
import Foundation

/// One Thread's reading of one text.
public struct TraceReading: Codable, Sendable, Equatable {
    public var thread: String
    /// Mean trace from token `TraceBench.from` on.
    public var trace: Float
    /// The longest chain anywhere in the text, and the longest run that stayed inside one partition.
    public var longest: Int
    public var partitionRun: Int
    /// The longest chain the hits alone show (any rank, no bridges).
    public var wireLongest: Int
    /// Token-local baselines from `from` on: the retrieval mass on the token that came, and the best cosine.
    public var meanPknn: Float
    public var meanBest: Float
    /// This Thread's mean share of the text's answer tokens under the live gate and under the shadow
    /// β4 (nil for a text without answers). The owner's reading is the holder's share.
    public var holderShare: Float?
    public var shadowHolderShare: Float?

    public init(thread: String, trace: Float, longest: Int, partitionRun: Int, wireLongest: Int, meanPknn: Float, meanBest: Float,
                holderShare: Float? = nil, shadowHolderShare: Float? = nil) {
        self.thread = thread
        self.trace = trace
        self.longest = longest
        self.partitionRun = partitionRun
        self.wireLongest = wireLongest
        self.meanPknn = meanPknn
        self.meanBest = meanBest
        self.holderShare = holderShare
        self.shadowHolderShare = shadowHolderShare
    }
}

public struct TraceTextResult: Codable, Sendable, Equatable {
    public var kind: BenchTextKind
    public var label: String
    public var owner: String?
    public var near: String?
    public var tokens: Int
    public var answerTokens: Int
    public var readings: [TraceReading]

    public init(kind: BenchTextKind, label: String, owner: String?, near: String?, tokens: Int, answerTokens: Int, readings: [TraceReading]) {
        self.kind = kind
        self.label = label
        self.owner = owner
        self.near = near
        self.tokens = tokens
        self.answerTokens = answerTokens
        self.readings = readings
    }

    public func reading(_ thread: String?) -> TraceReading? {
        guard let thread else { return nil }
        return readings.first { $0.thread == thread }
    }
}

/// A Thread's share of told and source answer tokens under the live gate and under the shadow β4,
/// pooled over tokens. No threshold.
public struct TraceArmReading: Codable, Sendable, Equatable {
    public var set: String
    public var texts: Int
    public var answerTokens: Int
    public var live: Float?
    public var shadow: Float?
}

public struct TraceReport: Codable, Sendable {
    public var bench = "trace"
    public var createdAt: Date
    public var dataset: String
    /// Per Thread, `v<version>/<index sha256>`.
    public var threads: [String: String]
    public var documents: [String: Int]
    public var memorised: [String: Float]
    public var rule: TraceRule
    public var from: Int
    public var sizes: BenchTextSizes
    public var texts: [TraceTextResult]
    public var rules: [BenchRule]
    public var arms: [TraceArmReading]
    public var reported: [String: Float]
    public var summary: String
    /// The gate the texts were scored under (κ included) and the session log the scoring wrote.
    public var gate: GateSettings? = nil
    public var sessions: [String]? = nil
}

public enum TraceBench {
    /// A text's value is its mean from this token on.
    public static let from = 24
    /// A holder traces its own text at least this; anyone else at most `low`.
    public static let holderFloor: Float = 0.40
    public static let low: Float = 0.10

    public static func run(braid: BenchBraid, world: BenchWorld, sizes: BenchTextSizes = BenchTextSizes(), progress: ((String) -> Void)? = nil) throws -> TraceReport {
        let threads = try braid.benchThreads(world: world) { progress?("warning: \($0)") }
        let texts = BenchTexts.build(world: world, threads: threads, tokenizer: braid.tokenizer, byteOffsets: braid.tokenizer.byteOffsets,
                                     paragraphBreak: braid.tokenizer.paragraphBreak, sizes: sizes)
        progress?("texts: " + BenchTexts.census(texts))
        let documentOfRow = braid.documentOfRow
        try braid.keepSession()
        defer { braid.finishSession() }
        var results: [TraceTextResult] = []
        let started = Date()
        for (i, text) in texts.enumerated() {
            if i % 25 == 0 { progress?(String(format: "scoring %d/%d (%.0f s)", i, texts.count, Date().timeIntervalSince(started))) }
            let generation = try braid.score(text.tokens)
            results.append(result(text, generation: generation, names: braid.names, commons: braid.commonsIndex, eos: braid.tokenizer.eos, documentOfRow: documentOfRow))
            if i % 8 == 7 { braid.relax() }
        }
        let verdict = evaluate(texts: results)
        return TraceReport(createdAt: BenchFormat.wholeSecond(), dataset: world.name, threads: braid.threadRecords, documents: braid.documents, memorised: braid.memorised,
                           rule: braid.settings.trace, from: from, sizes: sizes, texts: results, rules: verdict.rules, arms: arms(texts: results),
                           reported: verdict.reported, summary: verdict.summary, gate: braid.settings.gate, sessions: braid.sessions.map(\.path))
    }

    /// The rules re-applied to a saved report's readings.
    public static func rescore(_ report: TraceReport) -> TraceReport {
        var rescored = report
        let verdict = evaluate(texts: report.texts)
        rescored.rules = verdict.rules
        rescored.reported = verdict.reported
        rescored.summary = verdict.summary
        rescored.arms = arms(texts: report.texts)
        return rescored
    }

    /// One text's readings from its scoring. Step j of the generation holds token j of eos ‖ text (text
    /// position j − 1), and per strand the chain state that expected it, its retrieval mass on it, and
    /// its share of it under the live gate and under the shadow.
    public static func result(_ text: BenchText, generation: Generation, names: [String], commons: Int?, eos: Int32, documentOfRow: [[Int32: String]]) -> TraceTextResult {
        let answerPositions = Set(text.answers.flatMap { $0.start..<($0.start + $0.count) })
        var readings: [TraceReading] = []
        var answerTokens = 0
        for t in names.indices where t != commons {
            var traces: [Double] = [], pknn: [Double] = [], best: [Double] = []
            var longest = 0
            var partitionRun = 0
            var share = 0.0, shadow = 0.0
            var counted = 0
            // hits[p]: the hits of the emission at position p (they expect token p + 1), for the wire audit.
            var hits = [[Hit]](repeating: [], count: text.tokens.count + 1)
            for step in generation.steps {
                guard let records = step.threads, t < records.count else { continue }
                let record = records[t]
                let p = step.index - 1
                if p >= from {
                    traces.append(Double(record.trace?.trace ?? 0))
                    pknn.append(Double(record.pknn))
                    best.append(Double(record.hits.first?.score ?? 0))
                }
                longest = max(longest, record.trace?.length ?? 0)
                partitionRun = max(partitionRun, record.trace?.partitionRun ?? 0)
                if answerPositions.contains(p) {
                    share += Double(record.share)
                    shadow += Double(record.shadowShare)
                    counted += 1
                }
                if p >= 0, p < hits.count { hits[p] = record.hits }
            }
            let wire = TraceAudit.wireLengths(tokens: [eos] + text.tokens, hits: hits, documentOfRow: t < documentOfRow.count ? documentOfRow[t] : [:]).max() ?? 0
            answerTokens = max(answerTokens, counted)
            readings.append(TraceReading(thread: names[t], trace: Float(Stats.mean(traces)), longest: longest, partitionRun: partitionRun, wireLongest: wire,
                                         meanPknn: Float(Stats.mean(pknn)), meanBest: Float(Stats.mean(best)),
                                         holderShare: counted > 0 ? Float(share / Double(counted)) : nil,
                                         shadowHolderShare: counted > 0 ? Float(shadow / Double(counted)) : nil))
        }
        return TraceTextResult(kind: text.kind, label: text.label, owner: text.owner, near: text.near, tokens: text.tokens.count, answerTokens: answerTokens, readings: readings)
    }

    /// The holder's (and the near Thread's) share of told and source answer tokens, pooled over tokens.
    public static func arms(texts: [TraceTextResult]) -> [TraceArmReading] {
        func pooled(_ kinds: [BenchTextKind], set: String, of strand: (TraceTextResult) -> String?) -> TraceArmReading {
            var live = 0.0, shadow = 0.0
            var tokens = 0, count = 0
            for text in texts where kinds.contains(text.kind) && text.answerTokens > 0 {
                guard let reading = text.reading(strand(text)), let l = reading.holderShare, let s = reading.shadowHolderShare else { continue }
                live += Double(l) * Double(text.answerTokens)
                shadow += Double(s) * Double(text.answerTokens)
                tokens += text.answerTokens
                count += 1
            }
            return TraceArmReading(set: set, texts: count, answerTokens: tokens, live: tokens > 0 ? Float(live / Double(tokens)) : nil,
                                   shadow: tokens > 0 ? Float(shadow / Double(tokens)) : nil)
        }
        return [
            pooled([.told, .source], set: "holder · told+source", of: \.owner),
            pooled([.told], set: "holder · told", of: \.owner),
            pooled([.source], set: "holder · source", of: \.owner),
            pooled([.told], set: "near · told", of: \.near),
            pooled([.source], set: "near · source", of: \.near),
        ]
    }

    // MARK: - The rule (pure)

    /// T1: the holder traces its own document as written (≥ 0.40 on ≥ 90% of held), not the same
    /// sentences reordered or a collage (≤ 0.10 on ≥ 90%), AUROC ≥ 0.95. T2: on told and source texts
    /// the holder ≥ 0.40 on ≥ 90%, near and other Threads ≤ 0.10 on ≥ 90%. T3: on voice, voice-shuffled
    /// and generic texts every Thread ≤ 0.10 on ≥ 95% of texts and each class's mean ≤ 0.05.
    public static func evaluate(texts: [TraceTextResult]) -> BenchVerdict {
        func of(_ kinds: [BenchTextKind]) -> [TraceTextResult] { texts.filter { kinds.contains($0.kind) } }
        let share = BenchFormat.share
        func pct(_ value: Double) -> String { BenchFormat.pct(value) }
        var rules: [BenchRule] = []
        var reported: [String: Float] = [:]

        // T1: arc, not phrase.
        let held = of([.held]).compactMap { $0.reading($0.owner) }
        let apart = of([.shuffled, .collage]).compactMap { $0.reading($0.owner) }
        let t1Held = share(held.map { $0.trace >= holderFloor })
        let t1Apart = share(apart.map { $0.trace <= low })
        let t1AUROC = BenchFormat.auroc(held.map { Double($0.trace) }, apart.map { Double($0.trace) })
        rules.append(BenchRule(
            id: "T1 arc, not phrase", passes: !held.isEmpty && !apart.isEmpty && t1Held >= 0.9 && t1Apart >= 0.9 && (t1AUROC ?? 0) >= 0.95,
            detail: "holder ≥ 0.40 on \(pct(t1Held)) of \(held.count) held; ≤ 0.10 on \(pct(t1Apart)) of \(apart.count) shuffled and collage; AUROC \(BenchFormat.num(t1AUROC))"))
        reported["T1 token-local: retrieval mass on the tokens, AUROC"] = BenchFormat.auroc(held.map { Double($0.meanPknn) }, apart.map { Double($0.meanPknn) }).map(Float.init)
        reported["T1 token-local: best cosine, AUROC"] = BenchFormat.auroc(held.map { Double($0.meanBest) }, apart.map { Double($0.meanBest) }).map(Float.init)
        reported["T1 held: holder mean trace"] = Float(Stats.mean(held.map { Double($0.trace) }))
        reported["T1 shuffled and collage: holder mean trace"] = Float(Stats.mean(apart.map { Double($0.trace) }))
        reported["T1 shuffled and collage: holder mean retrieval mass on the tokens"] = Float(Stats.mean(apart.map { Double($0.meanPknn) }))

        // T2: among Threads, the holder of a told or source text traces it and nobody else does.
        let retold = of([.told, .source])
        let holders = retold.compactMap { $0.reading($0.owner) }
        let others = retold.flatMap { text in text.readings.filter { $0.thread != text.owner } }
        let near = retold.compactMap { $0.reading($0.near) }
        let t2Holders = share(holders.map { $0.trace >= holderFloor })
        let t2Others = share(others.map { $0.trace <= low })
        rules.append(BenchRule(
            id: "T2 holder among Threads", passes: !holders.isEmpty && t2Holders >= 0.9 && t2Others >= 0.9,
            detail: "holder ≥ 0.40 on \(pct(t2Holders)) of \(holders.count) told and source; near and other ≤ 0.10 on \(pct(t2Others)) of \(others.count) "
                + "(near alone \(pct(share(near.map { $0.trace <= low }))))"))
        reported["T2 told and source: holder mean trace"] = Float(Stats.mean(holders.map { Double($0.trace) }))
        reported["T2 told and source: near mean trace"] = Float(Stats.mean(near.map { Double($0.trace) }))

        // T3: text in a Thread's voice that nobody holds earns no Thread a trace.
        var t3 = true
        var details: [String] = []
        var falseChain = 0
        for kind in [BenchTextKind.voice, .voiceShuffled, .generic] {
            let group = of([kind])
            let clean = share(group.map { $0.readings.allSatisfy { $0.trace <= low } })
            let mean = Stats.mean(group.flatMap { $0.readings.map { Double($0.trace) } })
            falseChain = max(falseChain, group.flatMap { $0.readings.map(\.longest) }.max() ?? 0)
            if group.isEmpty || clean < 0.95 || mean > 0.05 { t3 = false }
            details.append("\(kind.rawValue): every Thread ≤ 0.10 on \(pct(clean)) of \(group.count), mean \(BenchFormat.num(mean))")
        }
        rules.append(BenchRule(id: "T3 voice earns nothing", passes: t3, detail: details.joined(separator: "; ")))
        reported["T3 longest false chain (tokens)"] = Float(falseChain)

        let readings = texts.flatMap(\.readings)
        reported["wire chain ≤ node chain"] = Float(share(readings.map { $0.wireLongest <= $0.longest }))
        let nodeLongest = Stats.mean(readings.map { Double($0.longest) })
        reported["wire chain / node chain (means)"] = nodeLongest > 0 ? Float(Stats.mean(readings.map { Double($0.wireLongest) }) / nodeLongest) : 0
        reported["held: longest chain (mean)"] = Float(Stats.mean(held.map { Double($0.longest) }))
        reported["held: longest partition-bounded run (mean)"] = Float(Stats.mean(held.map { Double($0.partitionRun) }))

        let failed = rules.filter { !$0.passes }.map(\.id)
        var summary = failed.isEmpty ? "T1 to T3 pass" : "failed: " + failed.joined(separator: ", ")
        if let both = arms(texts: texts).first, both.answerTokens > 0 {
            summary += String(format: "; the holder's share of %d told and source answer tokens: live gate %.3f, shadow β4 %.3f (no threshold)",
                              both.answerTokens, both.live ?? 0, both.shadow ?? 0)
        }
        return BenchVerdict(rules: rules, reported: reported, summary: summary)
    }
}
