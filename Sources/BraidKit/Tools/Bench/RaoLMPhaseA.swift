//
//  RaoLMPhaseA.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: `bench trace` phase A: the trace bench's rules applied to RaoLM's own scorings. Each text's
//        readings come from the dump's per-strand traces (RaoLM's trajectories; the chain after the
//        text's last token, which the dump does not hold, from Braid's tracker over the record's
//        hits), and TraceBench.evaluate's T1–T3 verdicts must equal RaoLM's for the same run. Then
//        RaoLM's logs are regated under Braid's live gate — memory plus lift over the commons,
//        Gate.observe at every prompt position with each strand's own probability of the token, the
//        commons RaoLM's commons strand — and the holder's share of the told and source answer
//        tokens must reproduce RaoLM's "no agreement" arm (1.000) within ±0.005. RaoLM's arms are
//        recomputed from their records beside the numbers RaoLM reported.
//  PIN:  Pure: no model, no GPU. Readings use RaoLM's window (the chain after each token from 24 to
//        the last), so they can equal RaoLM's report; Braid's own window (the state that expected
//        each token from 24, which is what the dump logs) is reported beside it. 0.938 is quoted
//        from an older braid's report and never compared.
//

import BraidCore
import Foundation

public enum RaoLMPhaseA {
    /// The plan's rule on the regate.
    public static let regateTolerance: Float = 0.005
    public static let quoted = "0.938: RaoLM's both β4 holder share in /Volumes/T9/rao/projects/raolm/db/braid/bench/trajectory.json (2026-09-30, a different braid: ambient v2, craft v2, veil v1); quoted, never compared"

    /// Braid's readings of a text against RaoLM's report.
    public struct ReadingAgreement: Codable, Sendable, Equatable {
        public var readings = 0
        public var traceEqual = 0
        public var maxTraceDifference: Float = 0
        public var longestEqual = 0
        public var wireLongestEqual = 0
        public var unmatched: [String] = []

        public init() {}
    }

    public struct Verdict: Codable, Sendable, Equatable {
        public var rule: String
        public var braid: Bool
        public var raolm: Bool?
        public var braidDetail: String
        public var raolmDetail: String?

        public var agrees: Bool { raolm == braid }
    }

    /// One of RaoLM's gate arms: what RaoLM reported and what its records give.
    public struct ArmRow: Codable, Sendable, Equatable {
        public var arm: String
        public var reported: Float?
        public var recomputed: Float?
        public var answerTokens: Int
        public var notAskedReported: Float?
        public var notAskedRecomputed: Float?
    }

    /// An arm's logged chains against the base pass's for the same texts: the trajectory is the
    /// node's and does not depend on the gate, so they must be equal (the replay of the base pass then
    /// covers the arms too, whose records lack far more hits).
    public struct ArmChains: Codable, Sendable, Equatable {
        public var arm: String
        public var records = 0
        public var positions = 0
        public var equal = 0
    }

    /// RaoLM's base pass regated under Braid's live gate.
    public struct Regate: Codable, Sendable, Equatable {
        public var texts = 0
        public var positions = 0
        public var answerTokens = 0
        /// The holder's share of the answer tokens: live (memory), and under the shadow β4.
        public var live: Float?
        public var shadow: Float?
        /// RaoLM's "no agreement" arm as reported, and the plan's ±0.005 about it.
        public var reference: Float?
        public var passes = false
        /// Braid's Gate.observe against RaoLM's logged memory at every position of every text of the
        /// base pass, and the live shares against the "no agreement" arm's logged shares.
        public var memoryTexts = 0
        public var memoryPositions = 0
        public var maxMemoryDifference = 0.0
        public var maxShareDifference: Double?
        public var comparedShares = 0

        public init() {}
    }

    public struct Report: Codable, Sendable {
        public var rule: TraceRule
        public var from: Int
        public var verdicts: [Verdict]
        public var readings: ReadingAgreement
        /// Braid's window: the state that expected each token from 24 (the positions the dump logs).
        public var braidWindowVerdicts: [Verdict]
        public var arms: [ArmRow]
        public var armChains: [ArmChains]
        public var regate: Regate
        /// TraceBench.arms over the regated readings (live gate and shadow β4).
        public var braidArms: [TraceArmReading]
        public var reported: [String: Float]
        public var raolmSummary: String?
        public var quoted: String
        public var passes: Bool
    }

    // MARK: - Readings

    /// The chain lengths of one strand, one per step, in RaoLM's window (after token j) or Braid's
    /// (expecting token p: the state after token p − 1).
    static func traceValues(_ lengths: [Int], rule: TraceRule, from: Int, braidWindow: Bool) -> [Double] {
        if braidWindow {
            // Step p's state expects token p: the chain after token p − 1, for p from `from` to n − 1.
            return lengths.indices.compactMap { j in j + 1 >= from && j + 1 < lengths.count ? Double(rule.trace(length: lengths[j])) : nil }
        }
        return lengths.indices.compactMap { j in j >= from ? Double(rule.trace(length: lengths[j])) : nil }
    }

    /// A text's readings, Braid's TraceTextResult, from a scored text and the regate's holder shares.
    public static func result(_ text: RaoLMDumpText, scored: RaoLMCheck.ScoredText, rule: TraceRule, from: Int = TraceBench.from, braidWindow: Bool = false,
                              live: [String: Float] = [:], shadow: [String: Float] = [:], answerTokens: Int = 0) -> TraceTextResult? {
        guard let kind = BenchTextKind(rawValue: text.kind) else { return nil }
        var readings: [TraceReading] = []
        for (t, name) in scored.strands.enumerated() where t != scored.commons {
            guard let lengths = scored.lengths[t] else { continue }
            let values = traceValues(lengths, rule: rule, from: from, braidWindow: braidWindow)
            let later = scored.traceIndex.indices.filter { scored.traceIndex[$0] >= from }
            let best = later.compactMap { scored.best[t][$0] }.map(Double.init)
            readings.append(TraceReading(
                thread: name, trace: Float(Stats.mean(values)), longest: lengths.max() ?? 0, partitionRun: scored.partitionRuns[t],
                wireLongest: scored.wireLongest[t], meanPknn: Float(Stats.mean(later.map { Double(scored.pknn[t][$0]) })), meanBest: Float(Stats.mean(best)),
                holderShare: live[name], shadowHolderShare: shadow[name]))
        }
        return TraceTextResult(kind: kind, label: text.label, owner: text.owner, near: text.near, tokens: scored.tokens.count, answerTokens: answerTokens,
                               readings: readings)
    }

    static func agreement(_ results: [TraceTextResult], report: RaoLMTrajectoryReport?) -> ReadingAgreement {
        var agreement = ReadingAgreement()
        guard let report else { return agreement }
        var byLabel: [String: [RaoLMTrajectoryReport.Text]] = [:]
        for text in report.texts { byLabel[text.kind + "|" + text.label, default: []].append(text) }
        var used: [String: Int] = [:]
        for result in results {
            let key = result.kind.rawValue + "|" + result.label
            let n = used[key, default: 0]
            used[key] = n + 1
            guard let texts = byLabel[key], n < texts.count else { agreement.unmatched.append(result.label); continue }
            let theirs = texts[n]
            for reading in result.readings {
                guard let other = theirs.readings.first(where: { $0.strand == reading.thread }) else { continue }
                agreement.readings += 1
                if reading.trace == other.trace { agreement.traceEqual += 1 }
                agreement.maxTraceDifference = max(agreement.maxTraceDifference, abs(reading.trace - other.trace))
                if reading.longest == other.longest { agreement.longestEqual += 1 }
                if reading.wireLongest == other.wireLongest { agreement.wireLongestEqual += 1 }
            }
        }
        return agreement
    }

    static func verdicts(_ verdict: BenchVerdict, report: RaoLMTrajectoryReport?) -> [Verdict] {
        verdict.rules.map { rule in
            let theirs = report?.evaluation.rules.first { $0.rule == rule.id }
            return Verdict(rule: rule.id, braid: rule.passes, raolm: theirs?.passed, braidDetail: rule.detail, raolmDetail: theirs?.detail)
        }
    }

    // MARK: - The regate

    /// One told or source text regated: per strand its mean live and shadow share of the answer
    /// tokens, and the positions and differences against RaoLM's records.
    struct TextRegate {
        var live: [String: Float] = [:]
        var shadow: [String: Float] = [:]
        var answerTokens = 0
        var positions = 0
        var liveShares: [[Double]] = []
        var maxMemoryDifference = 0.0
    }

    static func regate(_ text: RaoLMDumpText, scored: RaoLMCheck.ScoredText, rule: TraceRule, settings: GateSettings, lambda: Double) -> TextRegate {
        var out = TextRegate()
        let n = scored.strands.count
        guard n > 0 else { return out }
        let answers = Set(text.answerPositions)
        var state = GateState(strands: n, commons: scored.commons, prior: settings.commonsPrior)
        let open = [Bool](repeating: true, count: n)
        var live = [Double](repeating: 0, count: n), shadow = [Double](repeating: 0, count: n)
        for (i, k) in scored.traceIndex.enumerated() {
            let memory = state.memory
            for t in 0..<n where t < scored.memory[i].count { out.maxMemoryDifference = max(out.maxMemoryDifference, abs(memory[t] - Double(scored.memory[i][t]))) }
            // Each strand's own probability of the token; a strand not asked is charged what its retrieval alone gives it.
            let likelihoods = (0..<n).map { t -> Double in
                if let p = scored.alone[i][t] { return Double(p) }
                return t == scored.commons ? 0 : lambda * Double(scored.pknn[t][i])
            }
            let weights = Gate.renormalised(memory, open: open)
            let p = (0..<n).reduce(0.0) { $0 + weights[$1] * likelihoods[$1] }
            let shares = (0..<n).map { p > 0 ? weights[$0] * likelihoods[$0] / p : weights[$0] }
            var memoryState = GateState(strands: n, commons: scored.commons, prior: settings.commonsPrior)
            memoryState.memory = memory
            let traces = (0..<n).map { t -> Double in
                guard let lengths = scored.lengths[t], k >= 1, k - 1 < lengths.count else { return 0 }
                return Double(rule.trace(length: lengths[k - 1]))
            }
            let shadowWeights = Gate.renormalised(Gate.shadowWeights(memoryState, traces: traces, beta: settings.shadowBeta), open: open)
            let shadowP = (0..<n).reduce(0.0) { $0 + shadowWeights[$1] * likelihoods[$1] }
            let shadowShares = (0..<n).map { shadowP > 0 ? shadowWeights[$0] * likelihoods[$0] / shadowP : shadowWeights[$0] }
            out.liveShares.append(shares)
            out.positions += 1
            if answers.contains(k) {
                out.answerTokens += 1
                for t in 0..<n {
                    live[t] += shares[t]
                    shadow[t] += shadowShares[t]
                }
            }
            Gate.observe(&state, likelihoods: likelihoods, module: nil, settings: settings)
        }
        if out.answerTokens > 0 {
            for (t, name) in scored.strands.enumerated() {
                out.live[name] = Float(live[t] / Double(out.answerTokens))
                out.shadow[name] = Float(shadow[t] / Double(out.answerTokens))
            }
        }
        return out
    }

    // MARK: - The whole of phase A

    /// `base`: the base pass's scored texts by file; `arms`: each arm's by file.
    public static func run(index: RaoLMDumpIndex, base: [String: RaoLMCheck.ScoredText], arms: [String: [String: RaoLMCheck.ScoredText]],
                           report: RaoLMTrajectoryReport?, rule: TraceRule, lambda: Double, settings: GateSettings = GateSettings()) -> Report {
        let from = TraceBench.from
        // Regate every text of the base pass (its memory against RaoLM's), and score the told and source
        // texts with answers, the texts RaoLM's arms scored.
        var regate = Regate()
        var regates: [String: TextRegate] = [:]
        var live = 0.0, shadow = 0.0
        let noAgreement = arms["no agreement"]
        for text in index.texts {
            guard let scored = base[text.file] else { continue }
            let one = Self.regate(text, scored: scored, rule: rule, settings: settings, lambda: lambda)
            regate.memoryTexts += 1
            regate.memoryPositions += one.positions
            regate.maxMemoryDifference = max(regate.maxMemoryDifference, one.maxMemoryDifference)
            guard (text.kind == "told" || text.kind == "source") && !text.answers.isEmpty, let owner = text.owner else { continue }
            regates[text.file] = one
            regate.texts += 1
            regate.positions += one.positions
            regate.answerTokens += one.answerTokens
            live += Double(one.live[owner] ?? 0) * Double(one.answerTokens)
            shadow += Double(one.shadow[owner] ?? 0) * Double(one.answerTokens)
            if let theirs = noAgreement?[text.file] {
                var worst = regate.maxShareDifference ?? 0
                for (i, shares) in one.liveShares.enumerated() where i < theirs.share.count {
                    for t in shares.indices where t < theirs.share[i].count {
                        worst = max(worst, abs(shares[t] - Double(theirs.share[i][t])))
                        regate.comparedShares += 1
                    }
                }
                regate.maxShareDifference = worst
            }
        }
        if regate.answerTokens > 0 {
            regate.live = Float(live / Double(regate.answerTokens))
            regate.shadow = Float(shadow / Double(regate.answerTokens))
        }
        regate.reference = report?.arms.first { $0.arm == "no agreement" }?.holderShare
        if let value = regate.live, let reference = regate.reference { regate.passes = abs(value - reference) <= regateTolerance }

        // The readings, in RaoLM's window and in Braid's.
        var results: [TraceTextResult] = []
        var braidWindow: [TraceTextResult] = []
        for text in index.texts {
            guard let scored = base[text.file] else { continue }
            let one = regates[text.file]
            if let result = result(text, scored: scored, rule: rule, from: from, live: one?.live ?? [:], shadow: one?.shadow ?? [:],
                                   answerTokens: one?.answerTokens ?? 0) { results.append(result) }
            if let result = result(text, scored: scored, rule: rule, from: from, braidWindow: true) { braidWindow.append(result) }
        }
        let verdict = TraceBench.evaluate(texts: results)
        let verdicts = verdicts(verdict, report: report)
        let braidVerdicts = Self.verdicts(TraceBench.evaluate(texts: braidWindow), report: report)

        // RaoLM's arms: as reported, and from their records.
        var rows: [ArmRow] = []
        let names = (report?.arms.map(\.arm) ?? []) + arms.keys.sorted().filter { name in !(report?.arms.contains { $0.arm == name } ?? false) }
        for name in names {
            let theirs = report?.arms.first { $0.arm == name }
            var row = ArmRow(arm: name, reported: theirs?.holderShare, recomputed: nil, answerTokens: 0, notAskedReported: theirs?.notAsked, notAskedRecomputed: nil)
            if let records = arms[name] {
                // RaoLM's own loop, in its order and in Float: answer by answer, position by position from 1.
                var sum: Float = 0
                var tokens = 0
                var asked = 0, scoredThreads = 0
                for text in index.texts where (text.kind == "told" || text.kind == "source") && !text.answers.isEmpty {
                    guard let scored = records[text.file], let owner = text.owner, let t = scored.strands.firstIndex(of: owner) else { continue }
                    let byIndex = Dictionary(scored.traceIndex.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
                    for answer in text.answers {
                        for position in answer.start..<(answer.start + answer.count) where position >= 1 {
                            guard let i = byIndex[position], t < scored.share[i].count else { continue }
                            sum += scored.share[i][t]
                            tokens += 1
                        }
                    }
                    if let last = scored.open.last {
                        asked += last.filter { $0 }.count
                        scoredThreads += last.count
                    }
                }
                row.recomputed = tokens > 0 ? sum / Float(tokens) : nil
                row.answerTokens = tokens
                row.notAskedRecomputed = scoredThreads > 0 ? 1 - Float(asked) / Float(scoredThreads) : nil
            }
            rows.append(row)
        }
        var chains: [ArmChains] = []
        for (name, records) in arms.sorted(by: { $0.key < $1.key }) {
            var row = ArmChains(arm: name)
            for (file, scored) in records {
                guard let own = base[file] else { continue }
                row.records += 1
                for t in scored.strands.indices where t < own.lengths.count {
                    guard let mine = scored.lengths[t], let theirs = own.lengths[t] else { continue }
                    // The last step is Braid's replay, not a logged chain.
                    for j in 0..<(min(mine.count, theirs.count) - 1) {
                        row.positions += 1
                        if mine[j] == theirs[j] { row.equal += 1 }
                    }
                }
            }
            chains.append(row)
        }
        let readings = agreement(results, report: report)
        let passes = !verdicts.isEmpty && verdicts.allSatisfy(\.agrees) && regate.passes
        return Report(rule: rule, from: from, verdicts: verdicts, readings: readings, braidWindowVerdicts: braidVerdicts, arms: rows, armChains: chains, regate: regate,
                      braidArms: TraceBench.arms(texts: results), reported: verdict.reported, raolmSummary: report?.evaluation.summary, quoted: quoted,
                      passes: passes)
    }
}
