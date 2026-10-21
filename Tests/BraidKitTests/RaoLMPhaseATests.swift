//
//  RaoLMPhaseATests.swift
//  BraidKitTests
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Phase A with no model: the trace windows (RaoLM's, the chain after each token from 24 to
//        the last; Braid's, the state that expected each token from 24), the readings and verdicts
//        from scored texts, the regate under Braid's live gate converging on the holder, and RaoLM's
//        arms recomputed from their records. With BRAID_RAOLM_DUMP=1, the first base texts of the
//        real dump read exactly as RaoLM's trajectory.json reports them.
//

import Foundation
import Testing
@testable import BraidCore
@testable import BraidKit

@Suite("Phase A on RaoLM's scorings")
struct RaoLMPhaseATests {
    static let names = ["a", "b", "commons"]

    /// A scored text: per strand the chain lengths after each token, and per trace what each strand alone gave the token.
    static func scored(file: String, n: Int, lengths: [[Int]?], alone: [Float], share: [Float]? = nil) -> RaoLMCheck.ScoredText {
        let traces = n - 1
        return RaoLMCheck.ScoredText(
            file: file, strands: names, commons: 2, tokens: (0..<n).map { Int32($0) }, traceIndex: Array(1..<n), lengths: lengths, partitionRuns: [0, 0, 0],
            wireLongest: [0, 0, 0], pknn: names.map { _ in [Float](repeating: 0.5, count: traces) }, best: names.map { _ in [Float?](repeating: 0.9, count: traces) },
            alone: (0..<traces).map { _ in alone.map { Optional($0) } }, memory: (0..<traces).map { _ in [0, 0, 1] },
            share: (0..<traces).map { _ in share ?? [0, 0, 1] }, open: (0..<traces).map { _ in [true, true, true] })
    }

    static func text(_ file: String, kind: String, owner: String?, near: String? = nil, n: Int, answers: [RaoLMAnswer] = []) -> RaoLMDumpText {
        RaoLMDumpText(file: file, index: 0, kind: kind, label: file, owner: owner, near: near, document: nil, tokens: n, answers: answers)
    }

    @Test("RaoLM's window reads the chain after tokens 24…n−1; Braid's the state expecting tokens 24…n−1")
    func windows() {
        let lengths = Array(0..<100)
        let raolm = RaoLMPhaseA.traceValues(lengths, rule: .standard, from: 24, braidWindow: false)
        let braid = RaoLMPhaseA.traceValues(lengths, rule: .standard, from: 24, braidWindow: true)
        #expect(raolm.count == 76 && raolm.first == 0 && raolm.last == 1)
        #expect(braid.count == 76 && braid.first == Double(TraceRule.standard.trace(length: 23)) && braid.last == Double(TraceRule.standard.trace(length: 98)))
    }

    /// Every class the rules read: the holder follows its own held, told and source texts; nobody follows the rest.
    static func world(n: Int = 120) -> (RaoLMDumpIndex, [String: RaoLMCheck.ScoredText]) {
        let growing = Array(0..<n)
        let flat = [Int](repeating: 2, count: n)
        let answers = [RaoLMAnswer(start: 60, count: 3, text: " x"), RaoLMAnswer(start: 100, count: 2, text: " y")]
        var texts: [RaoLMDumpText] = []
        var scored: [String: RaoLMCheck.ScoredText] = [:]
        func add(_ file: String, _ kind: String, owner: String?, near: String? = nil, follows: Int?, answers: [RaoLMAnswer] = []) {
            texts.append(text(file, kind: kind, owner: owner, near: near, n: n, answers: answers))
            let lengths: [[Int]?] = [follows == 0 ? growing : flat, follows == 1 ? growing : flat, nil]
            let alone: [Float] = [follows == 0 ? 0.9 : 0.01, follows == 1 ? 0.9 : 0.01, 0.05]
            scored[file] = Self.scored(file: file, n: n, lengths: lengths, alone: alone)
        }
        add("held-0-a", "held", owner: "a", follows: 0)
        add("held-1-b", "held", owner: "b", follows: 1)
        add("shuffled-2-a", "shuffled", owner: "a", follows: nil)
        add("collage-3-b", "collage", owner: "b", follows: nil)
        add("voice-4-a", "voice", owner: "a", follows: nil)
        add("voiceShuffled-5-a", "voiceShuffled", owner: "a", follows: nil)
        add("generic-6-none", "generic", owner: nil, follows: nil)
        add("told-7-a", "told", owner: "a", near: "b", follows: 0, answers: answers)
        add("source-8-b", "source", owner: "b", near: "a", follows: 1, answers: answers)
        let index = RaoLMDumpIndex(createdAt: Date(timeIntervalSince1970: 0), dataRoot: "/nowhere", nodes: ["a": 1, "b": 1],
                                   arms: ["no agreement": "arms/no-agreement"], texts: texts)
        return (index, scored)
    }

    static func report(rules: [Bool] = [true, true, true], noAgreement: Float = 1, texts: [RaoLMTrajectoryReport.Text] = []) -> RaoLMTrajectoryReport {
        let ids = ["T1 arc, not phrase", "T2 holder among Threads", "T3 voice earns nothing"]
        return RaoLMTrajectoryReport(
            createdAt: Date(timeIntervalSince1970: 0), nodes: [:], documents: [:], memorised: [:],
            rule: .init(phrase: 24, arc: 96, bridge: 8, heads: 8, seeds: 4), texts: texts,
            arms: [.init(arm: "no agreement", holderShare: noAgreement, answerTokens: 10, exact: 2, prompts: 2, largestGate: nil, allAsked: nil, notAsked: 0)],
            evaluation: .init(rules: zip(ids, rules).map { .init(rule: $0, passed: $1, detail: "raolm") }, qualifies: [], winner: nil, reported: [:], summary: "s"))
    }

    @Test("verdicts from the scored texts equal RaoLM's; the regate gives the holder its answers; arms recompute from their records")
    func phaseA() throws {
        let (index, base) = Self.world()
        // The no-agreement arm's records: the owner holds 0.75 of every told and source token.
        var arm: [String: RaoLMCheck.ScoredText] = [:]
        for text in index.texts where text.kind == "told" || text.kind == "source" {
            var scored = base[text.file]!
            let owner = Self.names.firstIndex(of: text.owner!)!
            scored.share = scored.share.map { _ in (0..<3).map { $0 == owner ? Float(0.75) : Float(0.125) } }
            arm[text.file] = scored
        }
        let report = RaoLMPhaseA.run(index: index, base: base, arms: ["no agreement": arm], report: Self.report(), rule: .standard, lambda: 0.5)
        #expect(report.verdicts.map(\.rule) == ["T1 arc, not phrase", "T2 holder among Threads", "T3 voice earns nothing"])
        #expect(report.verdicts.allSatisfy { $0.braid && $0.agrees }, "\(report.verdicts)")
        #expect(report.braidWindowVerdicts.allSatisfy { $0.braid })
        #expect(report.regate.texts == 2 && report.regate.answerTokens == 10)
        #expect(report.regate.memoryTexts == 9 && report.regate.memoryPositions == 9 * 119)
        let live = try #require(report.regate.live)
        #expect(live > 0.99 && report.regate.passes, "live \(live)")
        #expect(report.arms.first { $0.arm == "no agreement" }?.recomputed == 0.75)
        #expect(report.armChains.first?.positions == 2 * 2 * 119 && report.armChains.first?.equal == report.armChains.first?.positions)
        #expect(report.braidArms.first?.live == live && report.braidArms.first?.answerTokens == 10)
        #expect(report.passes)
        // A RaoLM verdict that differs is a disagreement; a reference far from the regate fails the rule.
        let differs = RaoLMPhaseA.run(index: index, base: base, arms: [:], report: Self.report(rules: [false, true, true]), rule: .standard, lambda: 0.5)
        #expect(!differs.verdicts[0].agrees && !differs.passes)
        let far = RaoLMPhaseA.run(index: index, base: base, arms: [:], report: Self.report(noAgreement: 0.9), rule: .standard, lambda: 0.5)
        #expect(!far.regate.passes && !far.passes)
    }

    @Test("readings compare with RaoLM's report exactly, text by text and strand by strand")
    func readingsAgree() throws {
        let (index, base) = Self.world()
        // The report's readings, as RaoLM computes them: the mean trace after tokens 24…n−1, in Float through Double.
        let texts = index.texts.map { text -> RaoLMTrajectoryReport.Text in
            let scored = base[text.file]!
            let readings = ["a", "b"].enumerated().map { t, name -> RaoLMTrajectoryReport.Reading in
                let lengths = scored.lengths[t]!
                let trace = Stats.mean(lengths.indices.filter { $0 >= 24 }.map { TraceRule.standard.trace(length: lengths[$0]) })
                return .init(strand: name, trace: trace, longest: lengths.max()!, wireLongest: 0, manner: nil, arc: nil, fit: 0, meanFit: 0, meanBest: 0, logLikelihood: 0)
            }
            return .init(kind: text.kind, label: text.label, owner: text.owner, near: text.near, tokens: text.tokens, readings: readings)
        }
        let report = RaoLMPhaseA.run(index: index, base: base, arms: [:], report: Self.report(texts: texts), rule: .standard, lambda: 0.5)
        #expect(report.readings.readings == 18 && report.readings.traceEqual == 18 && report.readings.longestEqual == 18, "\(report.readings)")
        #expect(report.readings.unmatched.isEmpty)
    }
}

@Suite("Phase A on the real dump", .enabled(if: ProcessInfo.processInfo.environment["BRAID_RAOLM_DUMP"] == "1"))
struct RaoLMPhaseADumpTests {
    @Test("the first base texts read exactly as RaoLM's trajectory.json reports them")
    func readings() throws {
        let dump = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BRAID_RAOLM_DUMP_DIR"] ?? "/Volumes/T9/rao/projects/braid/raolm-dump", isDirectory: true)
        let index = try RaoLMDumpIndex.load(from: dump)
        let report = try RaoLMTrajectoryReport.load(from: dump.appendingPathComponent("trajectory.json"))
        let dataRoot = URL(fileURLWithPath: index.dataRoot, isDirectory: true)
        var set = RaoLMPort.sets(dump: dump, index: index)[0]
        set.texts = Array(set.texts.prefix(12))
        let probe = try RaoLMGeneration.load(from: dump.appendingPathComponent(set.texts[0].file))
        let indexes = try RaoLMPort.indexes(of: try #require(probe.braid), dataRoot: dataRoot)
        let outcomes = RaoLMPort.run(set: set, dump: dump, indexes: indexes, dataRoot: dataRoot, mode: .check, jobs: 2)
        var compared = 0
        for outcome in outcomes {
            let scored = try #require(outcome.scored)
            let result = try #require(RaoLMPhaseA.result(outcome.text, scored: scored, rule: report.traceRule))
            let theirs = try #require(report.texts.first { $0.label == outcome.text.label && $0.kind == outcome.text.kind })
            for reading in result.readings {
                let other = try #require(theirs.readings.first { $0.strand == reading.thread })
                #expect(reading.trace == other.trace, "\(outcome.text.file) \(reading.thread): \(reading.trace) vs \(other.trace)")
                #expect(reading.longest == other.longest, "\(outcome.text.file) \(reading.thread)")
                compared += 1
            }
        }
        #expect(compared == 36)
    }
}
