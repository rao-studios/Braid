//
//  GamingBench.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: `braid bench gaming`: the guards that keep the gate from being gamed. Prompts about entities
//        no Thread holds (each Thread's fact templates about nothing) and generic prose are continued
//        four tokens; at the first generated token every Thread must still be open and the largest
//        Thread's gate bounded. On a copy braid (two Threads holding the same documents, trained
//        apart) the copies must tie on their facts' credit and neither may take a fact whole. RaoLM's
//        gate-bench guards and Q5b, fixed before any numbers (RaoLM Docs/BRAID.md, "Choosing the
//        gate"; Docs/ARCHITECTURE.md, "Context to credit").
//  PIN:  "Gate" is the live gate (`ThreadRecord.memory`) over the Threads, the commons excluded;
//        "open" is `ThreadRecord.open`. G1 and G2 run on the braid; G3 on the copy braid (the commons
//        and the two copies) when one is named, else on a copy pair inside the braid, else it is
//        skipped and says so. `evaluate` is pure over the saved rows. Session logs are kept.
//

import BraidCore
import Foundation

public enum GamingSet: String, Codable, Sendable, CaseIterable { case unknown, generic, copied }

public struct GamingRow: Codable, Sendable, Equatable {
    public var set: GamingSet
    public var label: String
    /// Unknown: the Thread whose fact template was used; copied: the first copy.
    public var owner: String?
    public var answer: String
    /// Every strand open at the first generated token.
    public var allOpen: Bool
    /// The largest Thread memory at the first generated token (the commons excluded).
    public var largestGate: Float
    /// The strand with the most memory there, and whether that is the commons.
    public var leader: String
    public var commonsLeads: Bool?
    /// Copied facts: the two copies and each one's summed content credit over the generated tokens.
    public var copies: [String]?
    public var copyCredit: [Float]?
    public var exact: Bool?
    /// Copied facts: the Thread the answer's sentence followed, or those it tied between.
    public var followed: String?
    public var tied: [String]?

    public init(set: GamingSet, label: String, owner: String?, answer: String, allOpen: Bool, largestGate: Float, leader: String, commonsLeads: Bool? = nil,
                copies: [String]? = nil, copyCredit: [Float]? = nil, exact: Bool? = nil, followed: String? = nil, tied: [String]? = nil) {
        self.set = set
        self.label = label
        self.owner = owner
        self.answer = answer
        self.allOpen = allOpen
        self.largestGate = largestGate
        self.leader = leader
        self.commonsLeads = commonsLeads
        self.copies = copies
        self.copyCredit = copyCredit
        self.exact = exact
        self.followed = followed
        self.tied = tied
    }
}

public struct GamingReport: Codable, Sendable {
    public var bench = "gaming"
    public var createdAt: Date
    public var dataset: String
    public var threads: [String: String]
    public var gate: GateSettings
    public var perNode: Int
    /// The two Threads holding the same documents, when the braid has them.
    public var copyPair: [String]?
    public var rows: [GamingRow]
    public var rules: [BenchRule]
    public var reported: [String: Float]
    public var summary: String
    /// The session logs the bench wrote (the braid's, then the copy braid's).
    public var sessions: [String]? = nil
    /// What a reader needs beside the numbers.
    public var notes: [String]? = nil
}

public enum GamingBench {
    public static let generated = 4

    /// G1 and G2 on `braid`; G3 on `copies` (the commons and two copies) when given, else on a copy
    /// pair inside `braid` when there is one.
    public static func run(braid: BenchBraid, world: BenchWorld, perNode: Int = 10, copies: BenchBraid? = nil, progress: ((String) -> Void)? = nil) throws -> GamingReport {
        let threads = try braid.benchThreads(world: world) { progress?("warning: \($0)") }
        try braid.keepSession()
        defer { braid.finishSession() }
        var rows: [GamingRow] = []
        func row(_ generation: Generation, in braid: BenchBraid, set: GamingSet, label: String, owner: String?) -> GamingRow? {
            guard let first = FirstTokenGate(generation, commons: braid.commonsIndex) else { return nil }
            return GamingRow(set: set, label: label, owner: owner, answer: generation.text, allOpen: first.allOpen, largestGate: first.largestThreadMemory,
                             leader: braid.names[first.leader], commonsLeads: first.commonsLeads)
        }
        // Subjects nobody holds: each Thread's own templates about nothing, each prompt asked once.
        var asked = Set<String>()
        for thread in threads {
            let facts = BenchPrompts.facts(thread: thread, world: world, tokenizer: braid.tokenizer, byteOffsets: braid.tokenizer.byteOffsets,
                                           paragraphBreak: braid.tokenizer.paragraphBreak, perNode: .max)
            let prompts = BenchPrompts.unknown(facts, count: perNode).filter { !asked.contains($0) }
            progress?("unknown · \(thread.name): \(prompts.count) prompts")
            for prompt in prompts {
                asked.insert(prompt)
                let generation = try braid.generate(braid.tokenizer.encode(prompt), maxTokens: generated)
                if let made = row(generation, in: braid, set: .unknown, label: "nowhere · \(prompt)", owner: thread.name) { rows.append(made) }
            }
            braid.relax()
        }
        progress?("generic: \(BenchPrompts.generic.count) prompts")
        for prompt in BenchPrompts.generic {
            let generation = try braid.generate(braid.tokenizer.encode(prompt), maxTokens: generated)
            if let made = row(generation, in: braid, set: .generic, label: "generic · \(prompt)", owner: nil) { rows.append(made) }
        }
        // G3: two Threads holding the same documents (equal snapshot hashes), in the copy braid if named.
        let copyBraid = copies ?? braid
        var pair: [String]? = nil
        if let found = copyPair(in: copyBraid) {
            pair = found
            if copies != nil { try copyBraid.keepSession() }
            defer { if copies != nil { copyBraid.finishSession() } }
            let copyThreads = try copyBraid.benchThreads(world: world) { progress?("warning: \($0)") }
            guard let a = copyThreads.first(where: { $0.name == found[0] }), let b = copyThreads.first(where: { $0.name == found[1] }) else {
                throw BraidFailure.data("the copy pair \(found.joined(separator: ", ")) is not in the copy braid")
            }
            let facts = copiedFacts(a, b, world: world, tokenizer: copyBraid.tokenizer)
            progress?("copied · \(a.name) = \(b.name): \(facts.count) facts")
            for fact in facts {
                let generation = try copyBraid.generate(fact.tokens, maxTokens: fact.answerTokens + 2)
                guard var made = row(generation, in: copyBraid, set: .copied, label: "\(a.name) = \(b.name) · \(fact.fact.subject) (\(fact.fact.kind))", owner: a.name) else { continue }
                made.copies = found
                made.copyCredit = CopyTie.credits(generation, holders: found)
                made.exact = generation.text.hasPrefix(fact.fact.answer)
                made.followed = generation.decisions.first?.followed
                made.tied = generation.decisions.first.map(\.tied)
                rows.append(made)
            }
            copyBraid.relax()
        } else {
            progress?("copied: no two Threads hold the same documents; G3 is skipped")
        }
        let verdict = evaluate(rows: rows, copyPair: pair)
        let strands = braid.names.count
        let floor = Gate.floor(braid.settings.gate.openFloor, strands: strands)
        let prior = strands > 1 ? (1 - braid.settings.gate.commonsPrior) / Double(strands - 1) : 1
        let notes = [
            String(format: "RaoLM's recorded 100%% · 0.59 (unknown) and 100%% · 0.50 (generic) (RaoLM Docs/BRAID.md, \"Choosing the gate\") were measured on a two-Thread braid (Ambient, Craft) with no commons, before the commons existed, so the open floor never bit there. This braid has the commons at prior %.2f and %d Threads starting at %.3f each, against an open floor of %.3f.",
                   braid.settings.gate.commonsPrior, strands - 1, prior, floor),
        ]
        return GamingReport(createdAt: BenchFormat.wholeSecond(), dataset: world.name, threads: braid.threadRecords.merging(copyBraid.threadRecords) { a, _ in a },
                            gate: braid.settings.gate, perNode: perNode, copyPair: pair, rows: rows, rules: verdict.rules, reported: verdict.reported,
                            summary: verdict.summary, sessions: (braid.sessions + (copies?.sessions ?? [])).map(\.path), notes: notes)
    }

    /// The first two Threads of `braid` whose live versions hold the same corpus.
    public static func copyPair(in braid: BenchBraid) -> [String]? {
        for a in braid.threads.indices {
            for b in braid.threads.indices where b > a && braid.threads[a].version.corpusHash == braid.threads[b].version.corpusHash {
                return [braid.threads[a].info.name, braid.threads[b].info.name]
            }
        }
        return nil
    }

    /// Every located fact of the exclusive documents both copies hold (a third Thread holds none of them).
    static func copiedFacts(_ a: BenchThread, _ b: BenchThread, world: BenchWorld, tokenizer: BraidTokenizer) -> [BenchPrompts.FactPrompt] {
        BenchPrompts.facts(thread: a, world: world, tokenizer: tokenizer, byteOffsets: tokenizer.byteOffsets, paragraphBreak: tokenizer.paragraphBreak, perNode: .max)
            .filter { b.present.contains($0.documentID) }
    }

    public static func rescore(_ report: GamingReport) -> GamingReport {
        var rescored = report
        let verdict = evaluate(rows: report.rows, copyPair: report.copyPair)
        rescored.rules = verdict.rules
        rescored.reported = verdict.reported
        rescored.summary = verdict.summary
        return rescored
    }

    // MARK: - The rule (pure)

    /// G1 unknown subjects: every Thread open at the first generated token on ≥ 90% of prompts, the
    /// largest Thread gate there ≤ 0.80 on average. G2 generic text: every Thread open on every prompt,
    /// the largest Thread gate ≤ 0.65 on average. G3 copy braid (only with two Threads holding the same
    /// documents): of the exactly answered copied facts, the copies' content credits tie within 0.10
    /// of their sum on ≥ 90%, and no fact is taken whole by one copy (RaoLM's Q5b reading).
    public static func evaluate(rows: [GamingRow], copyPair: [String]?) -> BenchVerdict {
        let share = BenchFormat.share
        func pct(_ value: Double) -> String { BenchFormat.pct(value) }
        var rules: [BenchRule] = []
        var reported: [String: Float] = [:]
        let guards: [(id: String, set: GamingSet, needOpen: Double, maxGate: Double)] = [
            ("G1 unknown subjects", .unknown, 0.9, 0.80), ("G2 generic text", .generic, 1.0, 0.65),
        ]
        for rule in guards {
            let mine = rows.filter { $0.set == rule.set }
            let open = share(mine.map(\.allOpen))
            let gate = Stats.mean(mine.map { Double($0.largestGate) })
            rules.append(BenchRule(
                id: rule.id, passes: !mine.isEmpty && open >= rule.needOpen && gate <= rule.maxGate,
                detail: "every Thread open at the first generated token on \(pct(open)) of \(mine.count) (needs \(pct(rule.needOpen))); "
                    + "largest Thread gate \(BenchFormat.num(gate)) on average (needs ≤ \(BenchFormat.num(rule.maxGate, 2)))"))
            reported["\(rule.set.rawValue): every Thread open at the first generated token"] = Float(open)
            reported["\(rule.set.rawValue): largest Thread gate (mean)"] = Float(gate)
            reported["\(rule.set.rawValue): the commons leads at the first generated token"] = Float(share(mine.map { $0.commonsLeads == true }))
            reported["\(rule.set.rawValue): largest Thread gate (max)"] = mine.map(\.largestGate).max() ?? 0
        }
        let copied = rows.filter { $0.set == .copied }
        if let copyPair, !copied.isEmpty {
            let exact = copied.filter { $0.exact == true }
            let tied = exact.filter { CopyTie.tied($0.copyCredit ?? []) }.count
            let taken = exact.filter { CopyTie.takenWhole($0.copyCredit ?? []) }.count
            let rate = exact.isEmpty ? 0 : Double(tied) / Double(exact.count)
            rules.append(BenchRule(
                id: "G3 copy braid", passes: !exact.isEmpty && rate >= 0.9 && taken == 0,
                detail: "\(copyPair.joined(separator: " and ")): \(tied) of \(exact.count) exactly answered copied facts tie (each copy within 0.10 of the other, "
                    + "\(pct(rate)), needs 90%); \(taken) taken whole by one copy (needs 0); \(copied.count - exact.count) of \(copied.count) not answered exactly"))
            reported["copied: answered exactly"] = Float(share(copied.map { $0.exact == true }))
            reported["copied: the sentence followed one copy"] = Float(share(exact.map { $0.followed != nil }))
        } else {
            rules.append(BenchRule(id: "G3 copy braid", passes: false, detail: "skipped: no two Threads hold the same documents", skipped: true))
        }
        let failed = rules.filter { !$0.passes && !$0.skipped }.map(\.id)
        var summary = failed.isEmpty ? "G1 and G2 pass" : "failed: " + failed.joined(separator: ", ")
        if let g3 = rules.first(where: { $0.id == "G3 copy braid" }) {
            summary += g3.skipped ? "; G3 skipped (no copy braid)" : (g3.passes ? "; G3 passes" : "")
        }
        return BenchVerdict(rules: rules, reported: reported, summary: summary)
    }
}
