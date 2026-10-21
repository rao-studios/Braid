//
//  ModuleBenchTests.swift
//  BraidKitTests
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The second round of benches, pure parts with no model: the withheld draw, the stitched
//        bench's texts and its signature reading and S1–S3, the entropy bench's κ, calls and E1–E2,
//        the question bench's stem comparison and Q1–Q5b, the copy tie G3 and Q5b share, and the
//        replacement criterion R1–R3 on synthetic A and B reports.
//

import Foundation
import Testing
@testable import BraidCore
@testable import BraidKit

/// Positions of a two-strand scoring (the commons, then one Thread) with the entropies and
/// probabilities the module reads.
func moduleGeneration(_ positions: [(hlm: Float, hknn: Float, plm: Float, commonsPLM: Float, commonsHLM: Float, length: Int)]) -> Generation {
    var steps = [Step(index: 0, token: 0, text: "<eos>", source: .prompt, prob: 1, lambda: 0.5, threads: nil)]
    for (j, p) in positions.enumerated() {
        let commons = ThreadRecord(memory: 0.9, weight: 0.9, open: true, plm: p.commonsPLM, pknn: 0, share: 0.5, hlm: p.commonsHLM, hknn: 0, shadowGate: 0.9, shadowShare: 0.5,
                                   hits: [], trace: nil)
        let thread = ThreadRecord(memory: 0.1, weight: 0.1, open: true, plm: p.plm, pknn: 0.1, share: 0.5, hlm: p.hlm, hknn: p.hknn, shadowGate: 0.1, shadowShare: 0.5,
                                  hits: [], trace: TraceState(length: p.length, trace: TraceRule.standard.trace(length: p.length)))
        steps.append(Step(index: j + 1, token: Int32(j + 1), text: " w", source: .prompt, prob: 0.5, lambda: 0.5, threads: [commons, thread]))
    }
    let gen = GenerationLine(generationID: "g", prompt: GenerationPrompt(text: "", tokens: []), context: nil, params: GenerationParameters(), strands: ["commons", "t"])
    let end = EndLine(generationID: "g", tokens: positions.count + 1, generated: 0, stoppedOn: nil, text: "", partitions: [], bodySHA256: "")
    return Generation(gen: gen, steps: steps, end: end, strands: [], annotations: [], spans: [], credits: [], decisions: [],
                      royalties: RoyaltiesView(strands: [], documents: [], generated: 0))
}

@Suite("Withheld documents and copy ties")
struct WithheldAndCopyTests {
    @Test("the withheld draw is a seeded fifth, the same for the same ids, never every document")
    func withheld() {
        let ids = (0..<40).map { "raolm-a-\($0)" }
        let a = Withholding.draw(ids, fraction: 0.2, seed: 42)
        #expect(a.count == 8 && a.isSubset(of: Set(ids)))
        #expect(Withholding.draw(ids.reversed(), fraction: 0.2, seed: 42) == a, "order-free")
        #expect(Withholding.draw(ids, fraction: 0.2, seed: 43) != a)
        #expect(Withholding.draw(ids, fraction: 0.99, seed: 42).count == 39)
        #expect(Withholding.draw(["one"], fraction: 0.5, seed: 1).isEmpty)
    }

    @Test("copies tie within 0.10 of their sum; a copy that earned nothing lost the fact whole")
    func copyTie() {
        #expect(CopyTie.tied([0.5, 0.5]) && CopyTie.tied([0.52, 0.48]) && !CopyTie.tied([0.6, 0.4]))
        #expect(!CopyTie.tied([0, 0]) && !CopyTie.takenWhole([0, 0]))
        #expect(CopyTie.takenWhole([0.9, 0]) && !CopyTie.takenWhole([0.9, 0.1]))
    }

    @Test("G3 reads the exactly answered copied facts, as Q5b does")
    func g3() {
        var rows: [GamingRow] = []
        for i in 0..<10 {
            rows.append(GamingRow(set: .copied, label: "c\(i)", owner: "a", answer: "", allOpen: true, largestGate: 0.3, leader: "commons", copies: ["a", "b"],
                                  copyCredit: i == 0 ? [0.7, 0.3] : [0.5, 0.5], exact: true))
        }
        rows.append(GamingRow(set: .copied, label: "wrong", owner: "a", answer: "", allOpen: true, largestGate: 0.3, leader: "commons", copies: ["a", "b"],
                              copyCredit: [1, 0], exact: false))
        let verdict = GamingBench.evaluate(rows: rows, copyPair: ["a", "b"])
        let g3 = verdict.rules.first { $0.id == "G3 copy braid" }!
        #expect(g3.passes && g3.detail.contains("9 of 10"), "\(g3.detail)")
        rows[1].copyCredit = [0.4, 0]
        #expect(!GamingBench.evaluate(rows: rows, copyPair: ["a", "b"]).rules.first { $0.id == "G3 copy braid" }!.passes)
    }
}

@Suite("The stitched bench")
struct StitchedBenchTests {
    @Test("P and its shuffle from the withheld documents, C from the indexed held ones, N1 unfed in voice, N2 other Threads' and generic")
    func texts() {
        let (world, threads) = BenchFixtures.world()
        var sizes = StitchedSizes()
        sizes.minTokens = 8
        sizes.maxTokens = 400
        let withheld: Set<String> = [world.corpora["a"]!.documents[0].id]
        let texts = StitchedBench.buildTexts(world: world, withheldThread: threads[0], withheld: withheld, others: [threads[1]], tokenizer: BenchFixtures.tokenizer,
                                             paragraphBreak: BenchFixtures.paragraphBreak, sizes: sizes)
        func of(_ set: StitchedSet) -> [StitchedBench.Text] { texts.filter { $0.set == set } }
        #expect(of(.withheld).map(\.document) == [world.corpora["a"]!.documents[0].id])
        #expect(of(.withheldShuffled).count == 1 && of(.withheldShuffled)[0].tokens.sorted() == of(.withheld)[0].tokens.sorted())
        #expect(of(.control).map(\.document) == [1, 2, 4].map { world.corpora["a"]!.documents[$0].id })
        #expect(of(.unseen).map(\.document) == [world.corpora["a"]!.documents[3].id])
        #expect(of(.unrelated).filter { $0.owner == "beta" }.count == 2 && of(.unrelated).filter { $0.owner == nil }.count == 4)
        sizes.maxTokens = 20
        let short = StitchedBench.buildTexts(world: world, withheldThread: threads[0], withheld: withheld, others: [threads[1]], tokenizer: BenchFixtures.tokenizer,
                                             paragraphBreak: BenchFixtures.paragraphBreak, sizes: sizes)
        #expect(short.allSatisfy { $0.tokens.count <= 20 })
    }

    @Test("D is the share of positions from 24 inside a stitched run: a sure reed, spread retrieval, lift over the commons")
    func detector() {
        let stitched = (0..<48).map { _ in (hlm: Float(0.2), hknn: Float(2.5), plm: Float(0.9), commonsPLM: Float(0.1), commonsHLM: Float(3.0), length: 0) }
        let reading = StitchedBench.readings(moduleGeneration(stitched), names: ["commons", "t"], commons: 0, settings: ModuleSettings())
        #expect(reading.count == 1 && reading[0].thread == "t" && reading[0].detector == 1, "\(reading)")
        #expect(reading[0].labels["stitched"] == 1 && abs(reading[0].lift! - Float(log(9.0))) < 1e-4)
        let retrieval = stitched.map { p -> (hlm: Float, hknn: Float, plm: Float, commonsPLM: Float, commonsHLM: Float, length: Int) in (p.hlm, 0.1, p.plm, p.commonsPLM, p.commonsHLM, 30) }
        let indexed = StitchedBench.readings(moduleGeneration(retrieval), names: ["commons", "t"], commons: 0, settings: ModuleSettings())
        #expect(indexed[0].detector == 0 && indexed[0].labels["retrieval"] == 1 && indexed[0].trace > 0)
        // A run of seven stitched positions is not a run: D stays 0.
        var broken = stitched
        for i in stride(from: 7, to: broken.count, by: 8) { broken[i].hknn = 0.1 }
        #expect(StitchedBench.readings(moduleGeneration(broken), names: ["commons", "t"], commons: 0, settings: ModuleSettings())[0].detector == 0)
    }

    func text(_ set: StitchedSet, _ d: Float, retrieval: Float = 0) -> StitchedText {
        StitchedText(set: set, label: set.rawValue, owner: "p", document: nil, tokens: 100,
                     readings: [StitchedReading(thread: "p", detector: d, labels: ["retrieval": retrieval], trace: 0, hlm: 0.2, hknn: 2, lift: 1),
                                StitchedReading(thread: "q", detector: 0, labels: [:], trace: 0, hlm: 2, hknn: 2, lift: 0)])
    }

    @Test("S1 to S3 on synthetic readings")
    func rules() {
        var texts: [StitchedText] = []
        for i in 0..<10 { texts.append(text(.withheld, 0.5 + Float(i) * 0.03)) }
        for _ in 0..<10 { texts.append(text(.control, 0, retrieval: 0.9)) }
        for _ in 0..<10 { texts.append(text(.unseen, 0.02)) }
        for _ in 0..<10 { texts.append(text(.unrelated, 0)) }
        texts.append(text(.withheldShuffled, 0.1))
        let clean = StitchedBench.evaluate(texts: texts, withheldThread: "p")
        #expect(clean.passes && clean.rules.map(\.id) == ["S1 stitched, not unseen", "S2 the control is retrieval", "S3 withheld against indexed"], "\(clean.rules)")
        #expect(clean.reported["withheld, shuffled: D ≥ 0.40"] == 0)
        var weak = texts
        weak[0].readings[0].detector = 0.3
        #expect(StitchedBench.evaluate(texts: weak, withheldThread: "p").rules[0].passes, "9 of 10 is 90%: it passes")
        weak[1].readings[0].detector = 0.3
        #expect(!StitchedBench.evaluate(texts: weak, withheldThread: "p").rules[0].passes)
        var noisy = texts
        noisy[10].readings[0].detector = 0.5
        let s2 = StitchedBench.evaluate(texts: noisy, withheldThread: "p")
        #expect(!s2.rules[1].passes && s2.summary.contains("coverage lower bound"))
        #expect(!StitchedBench.evaluate(texts: [], withheldThread: "p").passes)
    }
}

@Suite("The entropy bench")
struct EntropyBenchTests {
    @Test("κ from a 2×2 table is Cohen's κ of the series it counts")
    func kappa() {
        let table = [11, 15, 10, 40]
        var a: [Bool] = [], b: [Bool] = []
        for (count, pair) in zip(table, [(true, true), (true, false), (false, true), (false, false)]) {
            a += Array(repeating: pair.0, count: count)
            b += Array(repeating: pair.1, count: count)
        }
        #expect(abs(EntropyBench.kappa(table)! - Stats.cohenKappa(a, b)!) < 1e-12)
        #expect(EntropyBench.kappa([5, 0, 0, 0]) == nil && EntropyBench.kappa([0, 0, 0, 0]) == nil)
        #expect(EntropyBench.kappa([10, 0, 0, 10]) == 1)
    }

    @Test("a reading: coherent run against in-trace from 24, each call where it is made, the labels where they disagree")
    func reading() {
        let n = 60
        let hknn = (0..<n).map { (10..<50).contains($0) ? 0.1 : 2.0 }
        let series = ThreadSeries(hlm: (0..<n).map { _ in 0.2 }, hknn: hknn, lift: (0..<n).map { _ in 1.0 }, trace: (0..<n).map { _ in 0 }, commonsHLM: (0..<n).map { _ in 3.0 })
        let lengths = (0..<n).map { max(0, $0 - 15) }
        let reading = EntropyBench.reading(thread: "t", series: series, lengths: lengths, settings: ModuleSettings(), phrase: 24)
        #expect(reading.agreement == [11, 15, 10, 0], "\(reading.agreement)")
        #expect(reading.coherentCall == 33 && reading.traceCall == 39)
        #expect(reading.coherentOnlyLabels == ["retrieval": 15] && reading.traceOnlyLabels == ["stitched": 10])
        #expect(abs(reading.coherent - 26.0 / 36) < 1e-6 && abs(reading.inTrace - 21.0 / 36) < 1e-6)
        #expect(EntropyBench.coherentCall([0.1, 0.1, 2, 0.1], settings: ModuleSettings()) == nil)
    }

    func text(_ kind: BenchTextKind, owner: String?, near: String? = nil, coherent: [String: Float], agreement: [Int] = [0, 0, 0, 0]) -> EntropyText {
        EntropyText(kind: kind, label: kind.rawValue, owner: owner, near: near, tokens: 200,
                    readings: coherent.sorted { $0.key < $1.key }.map { EntropyReading(thread: $0.key, coherent: $0.value, inTrace: 0, agreement: $0.key == owner ? agreement : [0, 0, 0, 100],
                                                                                         coherentCall: 30, traceCall: 31) })
    }

    @Test("E1 pools the holders' tables; E2 counts a null text by its largest coherent fraction")
    func rules() {
        var texts: [EntropyText] = []
        for _ in 0..<5 {
            texts.append(text(.held, owner: "a", coherent: ["a": 0.8, "b": 0], agreement: [80, 5, 5, 10]))
            texts.append(text(.told, owner: "b", near: "a", coherent: ["a": 0, "b": 0.7], agreement: [70, 5, 5, 20]))
            texts.append(text(.shuffled, owner: "a", coherent: ["a": 0.05, "b": 0.5]))
            texts.append(text(.voice, owner: "a", coherent: ["a": 0, "b": 0.02]))
        }
        let verdict = EntropyBench.evaluate(texts: texts)
        #expect(verdict.passes, "\(verdict.rules)")
        #expect(abs(verdict.reported["E3 lead/lag: coherent call − trace call (mean positions)"]! + 1) < 1e-6)
        // A Thread coherent on a voice text it never saw counts against E2 even if its holder is quiet.
        var voice = texts
        for i in voice.indices where voice[i].kind == .voice { voice[i].readings[1].coherent = 0.5 }
        #expect(!EntropyBench.evaluate(texts: voice).rules[1].passes)
        // Disagreement drives κ down.
        var noisy = texts
        for i in noisy.indices where noisy[i].kind == .held || noisy[i].kind == .told {
            for r in noisy[i].readings.indices where noisy[i].readings[r].thread == noisy[i].owner { noisy[i].readings[r].agreement = [10, 40, 40, 10] }
        }
        #expect(!EntropyBench.evaluate(texts: noisy).rules[0].passes)
    }
}

@Suite("The question bench")
struct QuestionBenchTests {
    @Test("stems compare normalised; token F1 over words")
    func stems() {
        #expect(QuestionPath.normalised("  Kestleham has a population of about:  ") == "kestleham has a population of about")
        #expect(QuestionPath.normalised("The  mayor is.") == QuestionPath.normalised("the mayor is"))
        #expect(QuestionPath.tokenF1("the mayor of Tillyburn is", "The mayor of Tillyburn is") == 1)
        #expect(abs(QuestionPath.tokenF1("the mayor is", "the current mayor is") - 6.0 / 7) < 1e-12)
        #expect(QuestionPath.tokenF1("x", "y") == 0)
    }

    func question(_ arm: QuestionArm, exact: Bool, matches: Bool? = nil, cited: Bool = true) -> QuestionRow {
        var row = QuestionRow(set: .questions, arm: arm, label: "q", owner: "a", question: "Who?", storedStem: "s", stem: "s", answer: exact ? " x" : " y")
        row.expected = " x"
        row.exact = exact
        row.cited = exact && cited
        row.answerTokens = 1
        row.citedTokens = row.cited == true ? 1 : 0
        row.rewriteMatches = arm == .commons ? matches : nil
        row.rewriter = arm == .commons ? "commons" : nil
        return row
    }

    func shared(_ kind: CrossKind, exact: Bool, followed: String?, credit: [Float], other: Float?) -> QuestionRow {
        var row = QuestionRow(set: .shared, arm: .commons, label: "s", owner: "b", question: "Who?", storedStem: "s", stem: "s", answer: " x")
        row.exact = exact
        row.kind = kind.rawValue
        row.sides = ["a", "b"]
        row.followed = followed
        row.sideCredit = credit
        row.otherCredit = other
        return row
    }

    @Test("Q1 to Q5b on the commons arm")
    func rules() {
        var rows: [QuestionRow] = []
        for i in 0..<10 {
            rows.append(question(.commons, exact: i < 5, matches: i < 6))
            rows.append(question(.stem, exact: i < 5))
            rows.append(question(.slice, exact: i < 9))
            rows.append(question(.paraphrase, exact: i < 2))
        }
        for i in 0..<5 { rows.append(shared(.paraphrase, exact: i < 4, followed: i < 4 ? "b" : nil, credit: [0.1, 0.9], other: 0.05)) }
        rows.append(shared(.excerpt, exact: true, followed: nil, credit: [0.5, 0.5], other: nil))
        for i in 0..<10 {
            var row = QuestionRow(set: .copied, arm: .commons, label: "c\(i)", owner: "a", question: "Who?", storedStem: "s", stem: "s", answer: " x")
            row.exact = true
            row.holders = ["a", "a2"]
            row.holderCredit = [0.5, 0.5]
            rows.append(row)
        }
        let verdict = QuestionBench.evaluate(rows: rows)
        let byID = Dictionary(uniqueKeysWithValues: verdict.rules.map { ($0.id, $0) })
        #expect(byID["Q1 rewrite fidelity"]!.passes && byID["Q2 exact"]!.passes && byID["Q3 cited"]!.passes && byID["Q5a retold"]!.passes && byID["Q5b copied"]!.passes)
        #expect(!byID["Q2′ context"]!.passes, "0.5 against the slice's 0.9")
        #expect(verdict.reported["slice: exact"] == 0.9 && verdict.reported["Q5c (reported) excerpt: asked"] == 1)
        // The followed side is not the most credited: Q5a fails.
        var misread = rows
        for i in misread.indices where misread[i].set == .shared && misread[i].followed == "b" { misread[i].sideCredit = [0.9, 0.1] }
        #expect(!QuestionBench.evaluate(rows: misread).rules.first { $0.id == "Q5a retold" }!.passes)
        // A copy that took a fact whole fails Q5b; no copies skips it.
        var taken = rows
        if let i = taken.firstIndex(where: { $0.set == .copied }) { taken[i].holderCredit = [0.8, 0] }
        #expect(!QuestionBench.evaluate(rows: taken).rules.first { $0.id == "Q5b copied" }!.passes)
        let skipped = QuestionBench.evaluate(rows: rows.filter { $0.set != .copied }).rules.first { $0.id == "Q5b copied" }!
        #expect(skipped.skipped && skipped.verdict == "SKIP")
    }
}

@Suite("The replacement criterion")
struct ReplacementTests {
    func trace(kappa: Double, live: Float, shadow: Float, traces: Float = 0.7) -> TraceReport {
        var gate = GateSettings()
        gate.moduleGain = kappa
        let texts = [TraceTextResult(kind: .told, label: "t", owner: "a", near: "b", tokens: 100, answerTokens: 4,
                                     readings: [TraceReading(thread: "a", trace: traces, longest: 80, partitionRun: 40, wireLongest: 80, meanPknn: 0.9, meanBest: 0.9,
                                                             holderShare: live, shadowHolderShare: shadow)])]
        return TraceReport(createdAt: Date(timeIntervalSince1970: 0), dataset: "d", threads: ["a": "v1/x"], documents: [:], memorised: [:], rule: .standard, from: 24,
                           sizes: BenchTextSizes(), texts: texts, rules: [], arms: [TraceArmReading(set: ReplacementBench.holderSet, texts: 1, answerTokens: 4, live: live, shadow: shadow)],
                           reported: [:], summary: "", gate: gate, sessions: ["/tmp/trace.jsonl"])
    }

    func gaming(kappa: Double, open: Bool, largest: Float, g3: Bool = true) -> GamingReport {
        var gate = GateSettings()
        gate.moduleGain = kappa
        var rows: [GamingRow] = []
        for i in 0..<10 { rows.append(GamingRow(set: .unknown, label: "u\(i)", owner: "a", answer: "", allOpen: open, largestGate: largest, leader: "commons")) }
        for i in 0..<8 { rows.append(GamingRow(set: .generic, label: "g\(i)", owner: nil, answer: "", allOpen: open, largestGate: largest, leader: "commons")) }
        let rules = [BenchRule(id: "G1 unknown subjects", passes: open, detail: ""), BenchRule(id: "G2 generic text", passes: open, detail: ""),
                     BenchRule(id: "G3 copy braid", passes: g3, detail: "")]
        return GamingReport(createdAt: Date(timeIntervalSince1970: 0), dataset: "d", threads: ["a": "v1/x"], gate: gate, perNode: 10, copyPair: ["a", "a2"], rows: rows,
                            rules: rules, reported: [:], summary: "", sessions: ["/tmp/gaming.jsonl"])
    }

    let clean = [SessionVerification(session: "/tmp/trace.jsonl", verified: true, status: "ok", generations: 1, issues: [:]),
                 SessionVerification(session: "/tmp/gaming.jsonl", verified: true, status: "ok", generations: 1, issues: [:])]

    @Test("R1 to R3 hold when B amplifies the holder as the shadow did, the guards hold, and verify replays B")
    func holds() {
        let verdict = ReplacementBench.evaluate(traceA: trace(kappa: 0, live: 0.7, shadow: 0.9), traceB: trace(kappa: 0.5, live: 0.92, shadow: 0.95),
                                                gamingA: gaming(kappa: 0, open: true, largest: 0.3), gamingB: gaming(kappa: 0.5, open: true, largest: 0.33), sessions: clean)
        #expect(verdict.passes && verdict.rules.count == 3, "\(verdict.rules)")
        #expect(verdict.summary.hasPrefix("R1 to R3 hold") && verdict.reported["trace readings: largest |A − B|"] == 0)
    }

    @Test("each failure is named: R1 below the shadow, R2 a moved gate or a failing guard, R3 a memory issue or a missing verify")
    func fails() {
        let traceA = trace(kappa: 0, live: 0.7, shadow: 0.9)
        let gamingA = gaming(kappa: 0, open: true, largest: 0.3)
        func ids(_ verdict: BenchVerdict) -> [String] { verdict.rules.filter { !$0.passes }.map(\.id) }
        #expect(ids(ReplacementBench.evaluate(traceA: traceA, traceB: trace(kappa: 0.5, live: 0.85, shadow: 0.95), gamingA: gamingA,
                                              gamingB: gaming(kappa: 0.5, open: true, largest: 0.3), sessions: clean)) == ["R1 the module amplifies as the shadow did"])
        #expect(ids(ReplacementBench.evaluate(traceA: traceA, traceB: trace(kappa: 0.5, live: 0.95, shadow: 0.95), gamingA: gamingA,
                                              gamingB: gaming(kappa: 0.5, open: true, largest: 0.4), sessions: clean)) == ["R2 the guards hold in B"])
        #expect(ids(ReplacementBench.evaluate(traceA: traceA, traceB: trace(kappa: 0.5, live: 0.95, shadow: 0.95), gamingA: gaming(kappa: 0, open: false, largest: 0.3),
                                              gamingB: gaming(kappa: 0.5, open: false, largest: 0.3), sessions: clean)) == ["R2 the guards hold in B"])
        var memory = clean
        memory[0].issues = ["memory": 3, "shares": 1]
        let r3 = ReplacementBench.evaluate(traceA: traceA, traceB: trace(kappa: 0.5, live: 0.95, shadow: 0.95), gamingA: gamingA,
                                           gamingB: gaming(kappa: 0.5, open: true, largest: 0.3), sessions: memory)
        #expect(ids(r3) == ["R3 the clamp held"] && r3.rules[2].detail.contains("shares 1"))
        var missing = clean
        missing[1].verified = false
        #expect(ids(ReplacementBench.evaluate(traceA: traceA, traceB: trace(kappa: 0.5, live: 0.95, shadow: 0.95), gamingA: gamingA,
                                              gamingB: gaming(kappa: 0.5, open: true, largest: 0.3), sessions: missing)) == ["R3 the clamp held"])
        // A ran with κ above 0: R1 and R2 cannot be read.
        let wrong = ReplacementBench.evaluate(traceA: trace(kappa: 0.5, live: 0.7, shadow: 0.9), traceB: trace(kappa: 0.5, live: 0.95, shadow: 0.95),
                                              gamingA: gamingA, gamingB: gaming(kappa: 0.5, open: true, largest: 0.3), sessions: clean)
        #expect(ids(wrong) == ["R1 the module amplifies as the shadow did", "R2 the guards hold in B"])
        // The trace is gate-independent: a difference between A's and B's readings is reported.
        let drift = ReplacementBench.evaluate(traceA: traceA, traceB: trace(kappa: 0.5, live: 0.95, shadow: 0.95, traces: 0.6), gamingA: gamingA,
                                              gamingB: gaming(kappa: 0.5, open: true, largest: 0.3), sessions: clean)
        #expect(abs(drift.reported["trace readings: largest |A − B|"]! - 0.1) < 1e-6)
    }
}
