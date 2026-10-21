//
//  LiftBench.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: `braid bench lift`: whether the commons and the lift gate earn their place. Fact prompts
//        (a Thread's own facts, the corpus sentence before the answer), generic prose, general
//        English the base model knows (commons prompts), subjects no Thread holds, and each Thread's
//        unfed documents scored by the braid and by the commons alone. Rules L1, L2 and L4 are
//        RaoLM's U3/U4 and Q4, fixed before any numbers (RaoLM Docs/ARCHITECTURE.md, "bench-umbrella");
//        L3 (held-out NLL against the commons alone) is reported without a threshold.
//  PIN:  Needs the commons in the braid. `evaluate` is pure over the saved rows.
//

import BraidCore
import Foundation

public enum LiftSet: String, Codable, Sendable, CaseIterable { case facts, generic, commons, unknown, heldOut }

public struct LiftRow: Codable, Sendable, Equatable {
    public var set: LiftSet
    public var label: String
    public var owner: String?
    public var expected: String?
    public var answer: String?
    public var exact: Bool?
    /// At the first generated token: the commons holds the largest memory; the largest Thread memory.
    public var commonsLeads: Bool?
    public var largestThreadMemory: Float?
    public var ownerLeads: Bool?
    /// Generic and commons prompts: the mean over generated tokens of the Threads' summed share.
    public var threadShare: Float?
    /// Facts: the answer tokens, the owner's mean share of them, and on how many its lift over the
    /// commons was defined (both asked) and positive.
    public var answerTokens: Int?
    public var ownerShare: Float?
    public var liftDefined: Int?
    public var liftPositive: Int?
    /// Σ bits·(the Threads' credit) and Σ bits over the generated tokens (form tokens are the commons').
    public var threadsCredit: Float?
    public var bits: Float?
    /// Held-out: the scored tokens and Σ −ln p under the braid and under the commons alone.
    public var tokens: Int?
    public var nllBraid: Float?
    public var nllCommons: Float?

    public init(set: LiftSet, label: String, owner: String? = nil, expected: String? = nil, answer: String? = nil, exact: Bool? = nil, commonsLeads: Bool? = nil,
                largestThreadMemory: Float? = nil, ownerLeads: Bool? = nil, threadShare: Float? = nil, answerTokens: Int? = nil, ownerShare: Float? = nil,
                liftDefined: Int? = nil, liftPositive: Int? = nil, threadsCredit: Float? = nil, bits: Float? = nil, tokens: Int? = nil, nllBraid: Float? = nil,
                nllCommons: Float? = nil) {
        self.set = set
        self.label = label
        self.owner = owner
        self.expected = expected
        self.answer = answer
        self.exact = exact
        self.commonsLeads = commonsLeads
        self.largestThreadMemory = largestThreadMemory
        self.ownerLeads = ownerLeads
        self.threadShare = threadShare
        self.answerTokens = answerTokens
        self.ownerShare = ownerShare
        self.liftDefined = liftDefined
        self.liftPositive = liftPositive
        self.threadsCredit = threadsCredit
        self.bits = bits
        self.tokens = tokens
        self.nllBraid = nllBraid
        self.nllCommons = nllCommons
    }
}

public struct LiftReport: Codable, Sendable {
    public var bench = "lift"
    public var createdAt: Date
    public var dataset: String
    public var threads: [String: String]
    public var gate: GateSettings
    public var sizes: LiftBench.Sizes
    public var rows: [LiftRow]
    public var rules: [BenchRule]
    public var reported: [String: Float]
    public var summary: String
    public var sessions: [String]? = nil
}

public enum LiftBench {
    public struct Sizes: Codable, Sendable, Equatable {
        public var factsPerNode = 10
        public var unknown = 10
        public var heldOutPerNode = 8
        /// Tokens generated after generic and commons prompts (RaoLM's 8), and after unknown prompts.
        public var generalTokens = 8
        public var unknownTokens = 4

        public init() {}
    }

    public static func run(braid: BenchBraid, world: BenchWorld, sizes: Sizes = Sizes(), progress: ((String) -> Void)? = nil) throws -> LiftReport {
        guard let commons = braid.commonsIndex else { throw BraidFailure.usage("bench lift needs the commons in the braid") }
        let threads = try braid.benchThreads(world: world) { progress?("warning: \($0)") }
        let tokenizer = braid.tokenizer
        try braid.keepSession()
        defer { braid.finishSession() }
        var rows: [LiftRow] = []

        /// Σ bits·(Threads' credit) and Σ bits over the generated tokens.
        func credit(_ generation: Generation) -> (credit: Float, bits: Float) {
            var weighed: Float = 0
            var bits: Float = 0
            let shared = generation.steps.filter { $0.source != .ctx }
            for (i, step) in shared.enumerated() where step.source == .gen {
                guard i < generation.credits.count, let row = generation.credits[i], let b = row.bits else { continue }
                weighed += b * row.credit.indices.filter { $0 != commons }.reduce(Float(0)) { $0 + row.credit[$1] }
                bits += b
            }
            return (weighed, bits)
        }

        // Facts: a Thread's own, from each Thread in turn.
        var ranked: [[BenchPrompts.FactPrompt]] = []
        for thread in threads {
            ranked.append(BenchPrompts.facts(thread: thread, world: world, tokenizer: tokenizer, byteOffsets: tokenizer.byteOffsets,
                                             paragraphBreak: tokenizer.paragraphBreak, perNode: .max))
        }
        let facts = BenchPrompts.interleave(ranked.map { Array($0.prefix(sizes.factsPerNode)) })
        progress?("facts: \(facts.count) prompts")
        for fact in facts {
            guard let owner = braid.index(of: fact.thread) else { continue }
            let generation = try braid.generate(fact.tokens, maxTokens: fact.answerTokens + 2)
            let answer = generation.generated.prefix(fact.answerTokens)
            var share = 0.0
            var defined = 0
            var positive = 0
            for step in answer {
                guard let records = step.threads, owner < records.count, commons < records.count else { continue }
                share += Double(records[owner].share)
                if let own = records[owner].plm, let base = records[commons].plm {
                    defined += 1
                    if own > base { positive += 1 }
                }
            }
            let first = FirstTokenGate(generation, commons: commons)
            let (weighed, bits) = credit(generation)
            rows.append(LiftRow(set: .facts, label: "\(fact.thread) · \(fact.fact.subject) (\(fact.fact.kind))", owner: fact.thread, expected: fact.fact.answer,
                                answer: generation.text, exact: generation.text.hasPrefix(fact.fact.answer), commonsLeads: first?.commonsLeads,
                                largestThreadMemory: first?.largestThreadMemory, ownerLeads: first.map { $0.leader == owner }, answerTokens: answer.count,
                                ownerShare: answer.isEmpty ? nil : Float(share / Double(answer.count)), liftDefined: defined, liftPositive: positive,
                                threadsCredit: weighed, bits: bits))
        }
        braid.relax()

        // Generic prose and general English: does the commons lead, and what do the Threads take?
        for (set, prompts) in [(LiftSet.generic, BenchPrompts.generic), (.commons, BenchPrompts.commons)] {
            progress?("\(set.rawValue): \(prompts.count) prompts")
            for prompt in prompts {
                let generation = try braid.generate(tokenizer.encode(prompt), maxTokens: sizes.generalTokens)
                let first = FirstTokenGate(generation, commons: commons)
                let taken = generation.generated.compactMap { step -> Double? in
                    guard let records = step.threads else { return nil }
                    return records.indices.filter { $0 != commons }.reduce(0.0) { $0 + Double(records[$1].share) }
                }
                let (weighed, bits) = credit(generation)
                rows.append(LiftRow(set: set, label: "\(set.rawValue) · \(prompt)", answer: generation.text, commonsLeads: first?.commonsLeads,
                                    largestThreadMemory: first?.largestThreadMemory, threadShare: taken.isEmpty ? nil : Float(Stats.mean(taken)),
                                    threadsCredit: weighed, bits: bits))
            }
        }
        braid.relax()

        // Subjects no Thread holds: each Thread's templates about nothing, a Thread in turn.
        let unknown = BenchPrompts.interleave(ranked.map { BenchPrompts.unknown($0, count: sizes.unknown) }, total: sizes.unknown)
        progress?("unknown: \(unknown.count) prompts")
        for prompt in unknown {
            let generation = try braid.generate(tokenizer.encode(prompt), maxTokens: sizes.unknownTokens)
            let first = FirstTokenGate(generation, commons: commons)
            let (weighed, bits) = credit(generation)
            rows.append(LiftRow(set: .unknown, label: "nowhere · \(prompt)", answer: generation.text, commonsLeads: first?.commonsLeads,
                                largestThreadMemory: first?.largestThreadMemory, threadsCredit: weighed, bits: bits))
        }
        braid.relax()

        // Held-out: each Thread's unfed exclusive documents, scored by the braid and by the commons alone.
        for thread in threads {
            let unfed = BenchTexts.exclusive(world.corpora[thread.node]?.documents ?? [], crosslinks: world.crosslinks).filter { !thread.present.contains($0.id) }
            let documents = Array(unfed.prefix(sizes.heldOutPerNode))
            progress?("held-out · \(thread.name): \(documents.count) unfed documents")
            for document in documents {
                let tokens = BenchTexts.split(document, tokenizer: tokenizer, paragraphBreak: tokenizer.paragraphBreak).tokens
                guard tokens.count > 1 else { continue }
                let braided = nll(try braid.score(tokens))
                let alone = nll(try braid.scoreCommonsAlone(tokens))
                rows.append(LiftRow(set: .heldOut, label: "\(thread.name) · \(document.name) (unfed)", owner: thread.name, tokens: braided.tokens,
                                    nllBraid: Float(braided.sum), nllCommons: Float(alone.sum)))
            }
            braid.relax()
        }
        let verdict = evaluate(rows: rows)
        return LiftReport(createdAt: BenchFormat.wholeSecond(), dataset: world.name, threads: braid.threadRecords, gate: braid.settings.gate, sizes: sizes, rows: rows,
                          rules: verdict.rules, reported: verdict.reported, summary: verdict.summary, sessions: braid.sessions.map(\.path))
    }

    /// Σ −ln p(y) over a scoring's positions with strands, and how many.
    static func nll(_ generation: Generation) -> (sum: Double, tokens: Int) {
        var sum = 0.0
        var tokens = 0
        for step in generation.steps where step.threads != nil {
            sum -= log(Double(max(step.prob, 1e-12)))
            tokens += 1
        }
        return (sum, tokens)
    }

    public static func rescore(_ report: LiftReport) -> LiftReport {
        var rescored = report
        let verdict = evaluate(rows: report.rows)
        rescored.rules = verdict.rules
        rescored.reported = verdict.reported
        rescored.summary = verdict.summary
        return rescored
    }

    // MARK: - The rule (pure)

    /// L1 nobody's text: the commons holds the largest memory at the first generated token on ≥ 90% of
    /// generic and commons prompts, the largest Thread memory there ≤ 0.35 on average. L2 inherited
    /// knowledge is not attributed: the Threads' summed share of commons prompts' tokens ≤ 0.10; on
    /// facts the owner's share of answer tokens ≥ 0.90 and its lift over the commons positive on ≥ 95%
    /// of them. L4 unknown subjects: the commons leads on ≥ 80%, the Threads' bits-weighted credit
    /// ≤ 0.25. L3 (held-out NLL, braid against the commons alone) is reported without a threshold.
    public static func evaluate(rows: [LiftRow]) -> BenchVerdict {
        let share = BenchFormat.share
        func pct(_ value: Double) -> String { BenchFormat.pct(value) }
        func num(_ value: Double) -> String { BenchFormat.num(value) }
        var rules: [BenchRule] = []
        var reported: [String: Float] = [:]

        let general = rows.filter { $0.set == .generic || $0.set == .commons }
        let leads = share(general.map { $0.commonsLeads == true })
        let gate = Stats.mean(general.compactMap { $0.largestThreadMemory.map(Double.init) })
        rules.append(BenchRule(
            id: "L1 nobody's text", passes: !general.isEmpty && leads >= 0.9 && gate <= 0.35,
            detail: "the commons leads at the first generated token on \(pct(leads)) of \(general.count) generic and commons prompts (needs 90%); "
                + "largest Thread gate \(num(gate)) on average (needs ≤ 0.35)"))

        let commonsRows = rows.filter { $0.set == .commons }
        let taken = Stats.mean(commonsRows.compactMap { $0.threadShare.map(Double.init) })
        let facts = rows.filter { $0.set == .facts }
        var shareSum = 0.0
        var answerTokens = 0
        var defined = 0
        var positive = 0
        for row in facts {
            if let s = row.ownerShare, let n = row.answerTokens {
                shareSum += Double(s) * Double(n)
                answerTokens += n
            }
            defined += row.liftDefined ?? 0
            positive += row.liftPositive ?? 0
        }
        let ownerShare = answerTokens > 0 ? shareSum / Double(answerTokens) : 0
        let liftRate = defined > 0 ? Double(positive) / Double(defined) : 0
        rules.append(BenchRule(
            id: "L2 inherited knowledge is not attributed",
            passes: !commonsRows.isEmpty && answerTokens > 0 && taken <= 0.10 && ownerShare >= 0.90 && liftRate >= 0.95,
            detail: "Threads take \(num(taken)) of \(commonsRows.count) commons prompts' tokens (needs ≤ 0.10); the owner \(num(ownerShare)) of \(answerTokens) "
                + "fact answer tokens (needs ≥ 0.90), its lift over the commons positive on \(pct(liftRate)) of \(defined) where both were asked (needs 95%)"))
        reported["facts: exact"] = Float(share(facts.map { $0.exact == true }))
        reported["facts: the owner leads at the first answer token"] = Float(share(facts.map { $0.ownerLeads == true }))
        reported["facts: answer tokens where the owner's lift is undefined"] = Float(answerTokens - defined)

        let unknown = rows.filter { $0.set == .unknown }
        let unknownLeads = share(unknown.map { $0.commonsLeads == true })
        let credit = unknown.reduce(0.0) { $0 + Double($1.threadsCredit ?? 0) }
        let bits = unknown.reduce(0.0) { $0 + Double($1.bits ?? 0) }
        let threadsCredit = bits > 0 ? credit / bits : 0
        rules.append(BenchRule(
            id: "L4 unknown subjects", passes: !unknown.isEmpty && unknownLeads >= 0.8 && threadsCredit <= 0.25,
            detail: "the commons leads at the first generated token on \(pct(unknownLeads)) of \(unknown.count) (needs 80%); "
                + "the Threads' bits-weighted credit \(num(threadsCredit)) over the generated tokens (needs ≤ 0.25)"))
        reported["unknown: largest Thread gate (mean)"] = Float(Stats.mean(unknown.compactMap { $0.largestThreadMemory.map(Double.init) }))

        let heldOut = rows.filter { $0.set == .heldOut }
        let tokens = heldOut.reduce(0) { $0 + ($1.tokens ?? 0) }
        var l3 = ""
        if tokens > 0 {
            let braid = heldOut.reduce(0.0) { $0 + Double($1.nllBraid ?? 0) } / Double(tokens)
            let alone = heldOut.reduce(0.0) { $0 + Double($1.nllCommons ?? 0) } / Double(tokens)
            reported["L3 held-out NLL: braid"] = Float(braid)
            reported["L3 held-out NLL: commons alone"] = Float(alone)
            reported["L3 held-out tokens"] = Float(tokens)
            l3 = String(format: "; L3 (no threshold): held-out NLL %.4f under the braid, %.4f under the commons alone, over %d tokens of %d unfed documents",
                        braid, alone, tokens, heldOut.count)
        }
        let failed = rules.filter { !$0.passes }.map(\.id)
        let summary = (failed.isEmpty ? "L1, L2 and L4 pass" : "failed: " + failed.joined(separator: ", ")) + l3
        return BenchVerdict(rules: rules, reported: reported, summary: summary)
    }
}
