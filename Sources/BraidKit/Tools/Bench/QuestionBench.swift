//
//  QuestionBench.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: `braid bench question`: whether the braid answers questions through the path `braid chat`
//        uses (QuestionPath). Every fact's first question (≤ 150 per Thread, from its exclusive
//        documents) goes through four arms: the commons' rewrite (the path), the question's stored
//        stem, the corpus slice before the answer (the v1 prompt, the ceiling) and the fact's first
//        paraphrase (reported). Negative questions (20 per Thread) ask about entities nobody holds;
//        each agreeing retelling is asked once so the followed-credit rule can be read; on a copy
//        braid (two Threads holding the same documents, trained apart) the copies' facts are asked.
//  PIN:  RaoLM's rules (RaoLM Docs/ARCHITECTURE.md, "bench-question" and "Context to credit"), fixed
//        before any numbers and read on the commons arm: Braid has no rules rewriter, the fallback is
//        the question itself. The commons, stem and paraphrase arms look up each Thread's context at
//        the 0.6 floor; the slice is the corpus's own context and gets none. Q4 (negatives) is
//        reported without a threshold, as the plan's table has no Q4. Session logs are kept.
//

import BraidCore
import Foundation

public enum QuestionSet: String, Codable, Sendable, CaseIterable { case questions, negatives, shared, copied }

public enum QuestionArm: String, Codable, Sendable, CaseIterable { case commons, stem, slice, paraphrase }

public struct QuestionRow: Codable, Sendable, Equatable {
    public var set: QuestionSet
    public var arm: QuestionArm
    public var label: String
    /// The fact's Thread (questions; copied: the first holder; shared: the target's Thread).
    public var owner: String?
    public var question: String
    public var storedStem: String?
    /// What the braid completed: the rewrite, the stored stem, the paraphrase or the slice's text.
    public var stem: String
    /// Commons arm: "commons" or "none" (the question itself), whether the rewrite is the stored stem, its token F1, its time.
    public var rewriter: String?
    public var rewriteMatches: Bool?
    public var rewriteF1: Float?
    public var adapterSeconds: Double?
    public var expected: String?
    public var answer: String
    public var exact: Bool?
    /// Some answer token's top citation is the fact's partition; the answer tokens, and those whose top citation is.
    public var cited: Bool?
    public var answerTokens: Int?
    public var citedTokens: Int?
    /// The Threads that found a context, and whether the fact's own Thread did.
    public var contexts: [String] = []
    public var ownerContext: Bool?
    /// Negatives: the commons holds the largest memory at the first generated token; the Threads' mean
    /// credit per generated content token.
    public var commonsLeads: Bool?
    public var threadsCredit: Float?
    /// Shared: the link's kind, its two sides (the source's Thread, the target's), the answer
    /// sentence's follow decision, each side's summed content credit, and the side not followed's
    /// mean credit per content token (when one side was followed).
    public var kind: String?
    public var sides: [String]?
    public var followed: String?
    public var tied: [String]?
    public var sideCredit: [Float]?
    public var otherCredit: Float?
    public var contentTokens: Int?
    /// Copied: the holders and each one's summed content credit.
    public var holders: [String]?
    public var holderCredit: [Float]?

    public init(set: QuestionSet, arm: QuestionArm, label: String, owner: String?, question: String, storedStem: String?, stem: String, answer: String) {
        self.set = set
        self.arm = arm
        self.label = label
        self.owner = owner
        self.question = question
        self.storedStem = storedStem
        self.stem = stem
        self.answer = answer
    }
}

public struct QuestionReport: Codable, Sendable {
    public var bench = "question"
    public var createdAt: Date
    public var dataset: String
    public var threads: [String: String]
    public var gate: GateSettings
    public var copyPair: [String]?
    public var sizes: QuestionBench.Sizes
    public var rows: [QuestionRow]
    public var rules: [BenchRule]
    public var reported: [String: Float]
    public var summary: String
    public var sessions: [String]? = nil
}

public enum QuestionBench {
    public struct Sizes: Codable, Sendable, Equatable {
        /// Questions per Thread: every fact's first question, up to this many facts.
        public var perNode = 150
        public var negativesPerNode = 20
        public var sharedPerLink = 1
        public var maxTokens = 24
        public var floor: Float = QuestionPath.floor

        public init() {}
    }

    /// Q5a reads these link kinds (RaoLM's amended rule); excerpts and variants are reported.
    public static let retold: Set<String> = [CrossKind.paraphrase.rawValue, CrossKind.summary.rawValue]

    struct Question {
        var thread: String
        var fact: Fact
        var text: String
        var stem: String
        var slice: [Int32]
        var paraphrase: String
    }

    struct Shared {
        var text: String
        var stem: String
        var expected: String
        var kind: CrossKind
        var sides: [String]
        var subject: String
    }

    public static func run(braid: BenchBraid, world: BenchWorld, sizes: Sizes = Sizes(), copies: BenchBraid? = nil, progress: ((String) -> Void)? = nil) throws -> QuestionReport {
        guard braid.hasCommons else { throw BraidFailure.usage("bench question needs the commons: it rewrites the questions") }
        let commonsNode = braid.commonsNode
        let tokenizer = braid.tokenizer
        let adapter = QuestionAdapter(trunk: commonsNode.trunk, reed: braid.reed, tokenizer: tokenizer)
        let threads = try braid.benchThreads(world: world) { progress?("warning: \($0)") }

        // The sets.
        var questions: [Question] = []
        var negatives: [(thread: String, question: FactQuestion)] = []
        for thread in threads {
            let facts = BenchPrompts.facts(thread: thread, world: world, tokenizer: tokenizer, byteOffsets: tokenizer.byteOffsets,
                                           paragraphBreak: tokenizer.paragraphBreak, perNode: .max)
            for fact in facts.prefix(sizes.perNode) {
                guard let question = fact.fact.questions?.first else { continue }
                questions.append(Question(thread: thread.name, fact: fact.fact, text: question.text, stem: question.stem, slice: fact.tokens,
                                          paraphrase: fact.fact.paraphrases.first ?? question.stem))
            }
            var seen = Set<String>()
            for fact in facts {
                guard negatives.filter({ $0.thread == thread.name }).count < sizes.negativesPerNode, let negative = fact.fact.negativeQuestions?.first,
                      !seen.contains(negative.text) else { continue }
                seen.insert(negative.text)
                negatives.append((thread.name, negative))
            }
        }
        let shared = sharedFacts(world: world, threads: threads, perLink: sizes.sharedPerLink)
        var copyPair: [String]? = nil
        var copied: [Question] = []
        if let copies {
            guard let pair = GamingBench.copyPair(in: copies) else { throw BraidFailure.usage("the copy braid holds no two Threads with the same documents") }
            copyPair = pair
            let copyThreads = try copies.benchThreads(world: world) { progress?("warning: \($0)") }
            if let a = copyThreads.first(where: { $0.name == pair[0] }), let b = copyThreads.first(where: { $0.name == pair[1] }) {
                copied = GamingBench.copiedFacts(a, b, world: world, tokenizer: tokenizer).compactMap { fact in
                    fact.fact.questions?.first.map { Question(thread: a.name, fact: fact.fact, text: $0.text, stem: $0.stem, slice: fact.tokens, paraphrase: $0.stem) }
                }
            }
        }
        progress?("questions \(questions.count), negatives \(negatives.count), shared \(shared.count), copied \(copied.count)")

        // The asking.
        var rewrites: [String: QuestionRewrite] = [:]
        func rewrite(_ question: String) -> QuestionRewrite {
            if let cached = rewrites[question] { return cached }
            let made = adapter.rewrite(question, maxTokens: sizes.maxTokens)
            rewrites[question] = made
            return made
        }
        func turn(_ arm: QuestionArm, question: String, stem: String, slice: [Int32]?, paraphrase: String?, in braid: BenchBraid) throws -> QuestionTurn {
            let nodes = braid.threads.map { (name: $0.info.name, node: $0.node) }
            switch arm {
            case .commons:
                let made = rewrite(question)
                return try QuestionPath.prepare(question: question, rewrite: made, stem: made.stem, nodes: nodes, tokenizer: tokenizer, k: braid.config.index.k, floor: sizes.floor)
            case .stem:
                return try QuestionPath.prepare(question: question, rewrite: nil, stem: stem, nodes: nodes, tokenizer: tokenizer, k: braid.config.index.k, floor: sizes.floor)
            case .paraphrase:
                return try QuestionPath.prepare(question: question, rewrite: nil, stem: paraphrase ?? stem, nodes: nodes, tokenizer: tokenizer, k: braid.config.index.k,
                                                floor: sizes.floor)
            case .slice:
                let tokens = slice ?? []
                return QuestionTurn(question: question, rewrite: nil, stem: tokenizer.decode(tokens), tokens: tokens, subject: nil, contexts: [:])
            }
        }
        func answer(_ turn: QuestionTurn, in braid: BenchBraid) throws -> Generation {
            var params = GenerationParameters()
            params.maxTokens = sizes.maxTokens
            params.tau = Float(braid.config.index.tau)
            params.k = braid.config.index.k
            return try QuestionPath.answer(turn, cluster: braid.cluster, params: params)
        }
        func row(_ set: QuestionSet, _ arm: QuestionArm, label: String, owner: String?, question: String, storedStem: String?, turn: QuestionTurn,
                 generation: Generation, expected: String?) -> QuestionRow {
            var made = QuestionRow(set: set, arm: arm, label: label, owner: owner, question: question, storedStem: storedStem, stem: turn.stem, answer: generation.text)
            if let rewrite = turn.rewrite {
                made.rewriter = rewrite.rewriter
                made.adapterSeconds = rewrite.seconds
                if let storedStem {
                    made.rewriteMatches = QuestionPath.normalised(rewrite.stem) == QuestionPath.normalised(storedStem)
                    made.rewriteF1 = Float(QuestionPath.tokenF1(rewrite.stem, storedStem))
                }
            }
            made.expected = expected
            made.exact = expected.map { generation.text.hasPrefix($0) }
            made.contexts = turn.contexts.keys.sorted()
            made.ownerContext = owner.map { turn.contexts[$0] != nil }
            return made
        }

        try braid.keepSession()
        defer { braid.finishSession() }
        var rows: [QuestionRow] = []
        let commonsName = braid.commonsIndex.map { braid.names[$0] }
        for arm in QuestionArm.allCases {
            progress?("questions · \(arm.rawValue): \(questions.count)")
            for question in questions {
                let asked = try turn(arm, question: question.text, stem: question.stem, slice: question.slice, paraphrase: question.paraphrase, in: braid)
                let generation = try answer(asked, in: braid)
                var made = row(.questions, arm, label: "\(question.thread) · \(question.fact.subject) (\(question.fact.kind))", owner: question.thread,
                               question: question.text, storedStem: question.stem, turn: asked, generation: generation, expected: question.fact.answer)
                let length = max(1, tokenizer.encode(question.fact.answer).count)
                let tokens = generation.generatedTokens.prefix(length)
                let hits = tokens.map { token -> Bool in
                    guard let top = token.annotation?.citations.first else { return false }
                    return top.address.documentID == question.fact.documentID && top.address.partitionIndex == question.fact.partitionIndex
                }
                made.answerTokens = tokens.count
                made.citedTokens = hits.filter { $0 }.count
                made.cited = hits.contains(true)
                rows.append(made)
            }
            braid.relax()
        }
        for arm in [QuestionArm.commons, .stem] {
            progress?("negatives · \(arm.rawValue): \(negatives.count)")
            for negative in negatives {
                let asked = try turn(arm, question: negative.question.text, stem: negative.question.stem, slice: nil, paraphrase: nil, in: braid)
                let generation = try answer(asked, in: braid)
                var made = row(.negatives, arm, label: "nowhere · \(negative.question.text)", owner: nil, question: negative.question.text,
                               storedStem: negative.question.stem, turn: asked, generation: generation, expected: nil)
                made.commonsLeads = FirstTokenGate(generation, commons: braid.commonsIndex)?.commonsLeads
                let content = generation.generatedTokens.filter { $0.credit?.role == .content }
                if !content.isEmpty {
                    made.threadsCredit = Stats.mean(content.map { token in token.names.filter { $0 != commonsName }.reduce(Float(0)) { $0 + token.credit(of: $1) } })
                }
                rows.append(made)
            }
            progress?("shared · \(arm.rawValue): \(shared.count)")
            for fact in shared {
                let asked = try turn(arm, question: fact.text, stem: fact.stem, slice: nil, paraphrase: nil, in: braid)
                let generation = try answer(asked, in: braid)
                var made = row(.shared, arm, label: "\(fact.sides[1]) ≈ \(fact.sides[0]) · \(fact.subject) (\(fact.kind.rawValue))", owner: fact.sides[1],
                               question: fact.text, storedStem: fact.stem, turn: asked, generation: generation, expected: fact.expected)
                let content = generation.generatedTokens.filter { $0.credit?.role == .content }
                let decision = generation.decisions.first
                made.kind = fact.kind.rawValue
                made.sides = fact.sides
                made.followed = decision?.followed
                made.tied = decision?.tied
                made.contentTokens = content.count
                made.sideCredit = fact.sides.map { side in content.reduce(Float(0)) { $0 + $1.credit(of: side) } }
                if let followed = decision?.followed, fact.sides.contains(followed), let other = fact.sides.first(where: { $0 != followed }), !content.isEmpty {
                    made.otherCredit = Stats.mean(content.map { $0.credit(of: other) })
                }
                rows.append(made)
            }
            braid.relax()
            if let copies, let copyPair {
                if arm == .commons { try copies.keepSession() }
                progress?("copied · \(arm.rawValue): \(copied.count)")
                for question in copied {
                    let asked = try turn(arm, question: question.text, stem: question.stem, slice: nil, paraphrase: nil, in: copies)
                    let generation = try answer(asked, in: copies)
                    var made = row(.copied, arm, label: "\(copyPair.joined(separator: " = ")) · \(question.fact.subject) (\(question.fact.kind))", owner: copyPair[0],
                                   question: question.text, storedStem: question.stem, turn: asked, generation: generation, expected: question.fact.answer)
                    made.holders = copyPair
                    made.holderCredit = CopyTie.credits(generation, holders: copyPair)
                    made.followed = generation.decisions.first?.followed
                    made.tied = generation.decisions.first?.tied
                    rows.append(made)
                }
                copies.relax()
            }
        }
        copies?.finishSession()
        let verdict = evaluate(rows: rows)
        return QuestionReport(createdAt: BenchFormat.wholeSecond(), dataset: world.name, threads: braid.threadRecords.merging(copies?.threadRecords ?? [:]) { a, _ in a },
                              gate: braid.settings.gate, copyPair: copyPair, sizes: sizes, rows: rows, rules: verdict.rules, reported: verdict.reported,
                              summary: verdict.summary, sessions: (braid.sessions + (copies?.sessions ?? [])).map(\.path))
    }

    /// One agreeing fact per non-homonym link whose two documents its Threads hold: the target fact's
    /// first question (else the source's), its answer, and the two sides.
    static func sharedFacts(world: BenchWorld, threads: [BenchThread], perLink: Int) -> [Shared] {
        var byNode: [String: BenchThread] = [:]
        for thread in threads where byNode[thread.node] == nil { byNode[thread.node] = thread }
        var shared: [Shared] = []
        for link in world.crosslinks where link.kind != .homonym {
            guard let origin = byNode[link.source.node], let teller = byNode[link.target.node], origin.name != teller.name,
                  origin.present.contains(link.source.documentID), teller.present.contains(link.target.documentID),
                  let source = world.document(id: link.source.documentID), let target = world.document(id: link.target.documentID) else { continue }
            var count = 0
            for pair in link.facts where pair.agrees && count < perLink {
                guard let sourceFact = source.facts.first(where: { $0.id == pair.sourceFact }), let targetFact = target.facts.first(where: { $0.id == pair.targetFact }),
                      let question = targetFact.questions?.first ?? sourceFact.questions?.first else { continue }
                shared.append(Shared(text: question.text, stem: question.stem, expected: targetFact.answer, kind: link.kind, sides: [origin.name, teller.name],
                                     subject: link.subject))
                count += 1
            }
        }
        return shared
    }

    public static func rescore(_ report: QuestionReport) -> QuestionReport {
        var rescored = report
        let verdict = evaluate(rows: report.rows)
        rescored.rules = verdict.rules
        rescored.reported = verdict.reported
        rescored.summary = verdict.summary
        return rescored
    }

    /// Of the decided shared rows (answered exactly, one side followed): those whose followed side
    /// earned strictly the most, and the other side's mean credit.
    static func followedReading(_ rows: [QuestionRow]) -> (asked: Int, decided: Int, followedMost: Int, otherCredit: Double?, ties: Int) {
        var decided = 0
        var most = 0
        var other: [Double] = []
        var ties = 0
        for row in rows {
            if (row.tied?.count ?? 0) >= 2 { ties += 1 }
            guard row.exact == true, let followed = row.followed, let sides = row.sides, sides.contains(followed), let credit = row.sideCredit, credit.count == sides.count
            else { continue }
            decided += 1
            if let f = sides.firstIndex(of: followed), credit.indices.allSatisfy({ $0 == f || credit[$0] < credit[f] }) { most += 1 }
            if let value = row.otherCredit { other.append(Double(value)) }
        }
        return (rows.count, decided, most, other.isEmpty ? nil : Stats.mean(other), ties)
    }

    // MARK: - The rules (pure)

    /// Read on the commons arm. Q1: the rewrite, normalised, is the stored stem on ≥ 0.50 of questions.
    /// Q2: its exact answers ≥ the stem arm's − 0.05. Q2′: ≥ the slice arm's − 0.10 (the slice is the
    /// ceiling; expected to fail). Q3: ≥ 0.90 of its exact answers cite the fact's partition (some
    /// answer token's top citation). Q5a: on agreeing paraphrase and summary retellings, one shared
    /// fact each, retrieval decides (the sentence followed one side, answered exactly) on ≥ 0.60 of
    /// those asked; where it did, the followed side is the most credited on ≥ 0.90 and the other side's
    /// mean credit ≤ 0.10. Q5b (a copy braid only): the copies tie within 0.10 on ≥ 0.90 of the exactly
    /// answered copied questions, none taken whole.
    public static func evaluate(rows: [QuestionRow]) -> BenchVerdict {
        let share = BenchFormat.share
        func pct(_ value: Double) -> String { BenchFormat.pct(value) }
        func num(_ value: Double?) -> String { BenchFormat.num(value) }
        func of(_ set: QuestionSet, _ arm: QuestionArm) -> [QuestionRow] { rows.filter { $0.set == set && $0.arm == arm } }
        func exact(_ rows: [QuestionRow]) -> Double { share(rows.map { $0.exact == true }) }
        var rules: [BenchRule] = []
        var reported: [String: Float] = [:]

        let commons = of(.questions, .commons)
        let stem = of(.questions, .stem)
        let slice = of(.questions, .slice)
        let matches = share(commons.map { $0.rewriteMatches == true })
        let f1 = Stats.mean(commons.compactMap { $0.rewriteF1.map(Double.init) })
        let fallbacks = commons.filter { $0.rewriter == "none" }.count
        rules.append(BenchRule(
            id: "Q1 rewrite fidelity", passes: !commons.isEmpty && matches >= 0.5,
            detail: "the commons' stem is the stored stem on \(pct(matches)) of \(commons.count) (needs 50%); token F1 \(num(f1)); \(fallbacks) fell back to the question"))
        rules.append(BenchRule(
            id: "Q2 exact", passes: !commons.isEmpty && !stem.isEmpty && exact(commons) >= exact(stem) - 0.05 - 1e-9,
            detail: "commons \(pct(exact(commons))) exact against the stored stem's \(pct(exact(stem))) (needs within 0.05)"))
        rules.append(BenchRule(
            id: "Q2′ context", passes: !commons.isEmpty && !slice.isEmpty && exact(commons) >= exact(slice) - 0.10 - 1e-9,
            detail: "commons \(pct(exact(commons))) exact against the slice's \(pct(exact(slice))), the ceiling (needs within 0.10; expected to fail)"))
        let answered = commons.filter { $0.exact == true }
        let cited = share(answered.map { $0.cited == true })
        rules.append(BenchRule(
            id: "Q3 cited", passes: !answered.isEmpty && cited >= 0.9,
            detail: "\(answered.filter { $0.cited == true }.count) of \(answered.count) exact answers cite the fact's partition (\(pct(cited)), needs 90%)"))

        let retoldRows = of(.shared, .commons).filter { Self.retold.contains($0.kind ?? "") }
        let q5a = followedReading(retoldRows)
        let decidedRate = q5a.asked > 0 ? Double(q5a.decided) / Double(q5a.asked) : 0
        let followedRate = q5a.decided > 0 ? Double(q5a.followedMost) / Double(q5a.decided) : 0
        rules.append(BenchRule(
            id: "Q5a retold", passes: q5a.asked > 0 && decidedRate >= 0.6 && followedRate >= 0.9 && (q5a.otherCredit ?? 1) <= 0.10,
            detail: "\(q5a.decided) of \(q5a.asked) paraphrase and summary facts decided by retrieval (\(pct(decidedRate)), needs 60%); the followed Thread most "
                + "credited on \(q5a.followedMost) (\(pct(followedRate)), needs 90%); the other side's credit \(num(q5a.otherCredit)) (needs ≤ 0.10); ties \(q5a.ties)"))

        let copied = of(.copied, .commons)
        if copied.isEmpty {
            rules.append(BenchRule(id: "Q5b copied", passes: false, detail: "skipped: no copy braid", skipped: true))
        } else {
            let exactCopies = copied.filter { $0.exact == true }
            let tied = exactCopies.filter { CopyTie.tied($0.holderCredit ?? []) }.count
            let taken = exactCopies.filter { CopyTie.takenWhole($0.holderCredit ?? []) }.count
            let rate = exactCopies.isEmpty ? 0 : Double(tied) / Double(exactCopies.count)
            rules.append(BenchRule(
                id: "Q5b copied", passes: !exactCopies.isEmpty && rate >= 0.9 && taken == 0,
                detail: "\(tied) of \(exactCopies.count) exactly answered copied questions tie between the copies (\(pct(rate)), needs 90%); \(taken) taken whole (needs 0); "
                    + "\(copied.count - exactCopies.count) of \(copied.count) not answered exactly"))
        }

        // Reported, no threshold.
        for arm in QuestionArm.allCases {
            let mine = of(.questions, arm)
            guard !mine.isEmpty else { continue }
            reported["\(arm.rawValue): exact"] = Float(exact(mine))
            let tokens = mine.reduce(0) { $0 + ($1.answerTokens ?? 0) }
            if tokens > 0 { reported["\(arm.rawValue): citation@1 per answer token"] = Float(Double(mine.reduce(0) { $0 + ($1.citedTokens ?? 0) }) / Double(tokens)) }
            if arm != .slice {
                let found = mine.filter { $0.ownerContext == true }
                reported["\(arm.rawValue): the owner found a context"] = Float(share(mine.map { $0.ownerContext == true }))
                reported["\(arm.rawValue): exact with the owner's context"] = Float(exact(found))
                reported["\(arm.rawValue): exact without it"] = Float(exact(mine.filter { $0.ownerContext != true }))
            }
        }
        let latencies = commons.compactMap(\.adapterSeconds)
        if !latencies.isEmpty { reported["commons: adapter ms (mean)"] = Float(Stats.mean(latencies) * 1000) }
        reported["commons: rewrite token F1 (mean)"] = Float(f1)
        for arm in [QuestionArm.commons, .stem] {
            let negatives = of(.negatives, arm)
            guard !negatives.isEmpty else { continue }
            reported["Q4 (reported) \(arm.rawValue): the commons leads on negatives"] = Float(share(negatives.map { $0.commonsLeads == true }))
            reported["Q4 (reported) \(arm.rawValue): Threads' credit per content token on negatives"] = Float(Stats.mean(negatives.compactMap { $0.threadsCredit.map(Double.init) }))
        }
        let stemRetold = followedReading(of(.shared, .stem).filter { Self.retold.contains($0.kind ?? "") })
        reported["Q5a (stem arm): decided"] = stemRetold.asked > 0 ? Float(Double(stemRetold.decided) / Double(stemRetold.asked)) : 0
        reported["Q5a (stem arm): followed most credited"] = stemRetold.decided > 0 ? Float(Double(stemRetold.followedMost) / Double(stemRetold.decided)) : 0
        if let other = stemRetold.otherCredit { reported["Q5a (stem arm): the other side's credit"] = Float(other) }
        let stemCopies = of(.copied, .stem)
        if !stemCopies.isEmpty {
            let exactCopies = stemCopies.filter { $0.exact == true }
            reported["Q5b (stem arm): copied questions answered exactly"] = Float(exactCopies.count)
            reported["Q5b (stem arm): of those, the copies tie"] = exactCopies.isEmpty ? 0 : Float(exactCopies.filter { CopyTie.tied($0.holderCredit ?? []) }.count) / Float(exactCopies.count)
            reported["Q5b (stem arm): taken whole"] = Float(exactCopies.filter { CopyTie.takenWhole($0.holderCredit ?? []) }.count)
        }
        reported["Q5a (commons arm): shared facts answered exactly"] = Float(of(.shared, .commons).filter { $0.exact == true }.count)
        for kind in [CrossKind.excerpt, .variant] {
            let mine = of(.shared, .commons).filter { $0.kind == kind.rawValue }
            guard !mine.isEmpty else { continue }
            let reading = followedReading(mine)
            reported["Q5c (reported) \(kind.rawValue): asked"] = Float(reading.asked)
            reported["Q5c (reported) \(kind.rawValue): decided"] = Float(reading.decided) / Float(reading.asked)
            reported["Q5c (reported) \(kind.rawValue): ties"] = Float(reading.ties)
        }

        let failed = rules.filter { !$0.passes && !$0.skipped }.map(\.id)
        var summary = failed.isEmpty ? "every rule holds on the commons arm" : "commons arm fails " + failed.joined(separator: ", ")
        if rules.contains(where: { $0.skipped }) { summary += "; Q5b skipped (no copy braid)" }
        return BenchVerdict(rules: rules, reported: reported, summary: summary)
    }
}
