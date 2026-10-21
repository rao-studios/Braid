//
//  ModuleSessionTests.swift
//  BraidCoreTests
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The trajectory module in every session: its e_t is logged (`mod`) at every context, prompt
//        and generated position and equals the offline module's reading of the positions before it
//        (a strand's own context first, the runway); at κ 0 the gate is exactly the module-off gate;
//        at κ > 0 the module moves the memory and the log's memory recursion still replays.
//

import Foundation
import Testing
@testable import BraidCore

@Suite("The module in every session")
struct ModuleSessionTests {
    /// " the cat sat on the mat. the dog ran far away. Big birds fly"
    static let prompt: [Int32] = [1, 2, 3, 4, 1, 5, 6, 1, 7, 8, 9, 10, 6, 11, 12, 13]

    func run(_ settings: ClusterSettings, contexts: Bool, log: URL? = nil) throws -> (Generation, Cluster) {
        let cluster = Fixtures.cluster(settings: settings)
        _ = try Fixtures.threeStrands(into: cluster)
        if let log { try cluster.startLog(at: log) }
        var params = GenerationParameters()
        params.maxTokens = 4
        let context = NodeContext(tokens: [11, 12, 13, 14, 15, 6, 1, 2, 3], score: 0.9, documentID: "doc-b-1", position: TokenPosition(row: 1, offset: 0))
        let generation = try cluster.generate(prompt: GenerationPrompt(text: "", tokens: Self.prompt), contexts: contexts ? ["b": context] : [:], params: params)
        cluster.closeLog()
        return (generation, cluster)
    }

    @Test("mod is logged at every position and is the offline reading of the positions before it, a strand's context first")
    func liveEqualsOffline() throws {
        let (generation, cluster) = try run(ClusterSettings(), contexts: true)
        let commons = cluster.commonsIndex
        let series = TrajectoryModule.series(generation.steps, commons: commons)
        let settings = ModuleSettings()
        func offline(_ t: Int, before i: Int) -> Float { i <= 0 ? 0 : Float(TrajectoryModule.read(series[t], at: i - 1, settings: settings).evidence) }
        var nonZero = 0
        // Context lines: strand b's own words, its series' first positions.
        let ctx = generation.steps.filter { $0.source == .ctx }
        #expect(ctx.count == 9 && ctx.allSatisfy { $0.owner == 2 })
        for (c, step) in ctx.enumerated() {
            let logged = try #require(step.threads?.first?.module)
            #expect(abs(logged - offline(2, before: c)) < 1e-6, "ctx \(c): \(logged) vs \(offline(2, before: c))")
        }
        // Prompt and generated positions: every strand, offset by its own context.
        let shared = generation.steps.filter { $0.source != .ctx && $0.threads != nil }
        #expect(shared.count == Self.prompt.count + generation.generated.count)
        for (i, step) in shared.enumerated() {
            for (t, record) in step.threads!.enumerated() {
                let logged = try #require(record.module, "no mod at position \(i) strand \(t)")
                let expected = offline(t, before: TrajectoryModule.contextCount(generation.steps, strand: t) + i)
                #expect(abs(logged - expected) < 1e-6, "position \(i) strand \(t): \(logged) vs \(expected)")
                if logged != 0 { nonZero += 1 }
            }
        }
        #expect(nonZero > 0, "the module said nothing: the test would prove nothing")
        #expect(TrajectoryModule.contextCount(generation.steps, strand: 2) == 9 && TrajectoryModule.contextCount(generation.steps, strand: 1) == 0)
    }

    @Test("κ 0 leaves the gate exactly as with the module off; κ 0.5 moves it, and the log replays")
    func kappa() throws {
        var off = ClusterSettings()
        off.module = nil
        let (plain, _) = try run(off, contexts: false)
        let (logged, _) = try run(ClusterSettings(), contexts: false)
        #expect(ClusterSettings().module != nil, "the module runs by default")
        for (a, b) in zip(plain.steps, logged.steps) {
            #expect(a.threads?.map(\.memory) == b.threads?.map(\.memory))
            #expect(a.threads?.map(\.share) == b.threads?.map(\.share))
            #expect(a.token == b.token)
            #expect(a.threads?.allSatisfy { $0.module == nil } ?? true)
        }
        var on = ClusterSettings()
        on.gate.moduleGain = 0.5
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("braid-module-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let (steered, _) = try run(on, contexts: true, log: url)
        let (unsteered, _) = try run(ClusterSettings(), contexts: true)
        let moved = zip(steered.steps, unsteered.steps).contains { a, b in a.threads?.map(\.memory) != b.threads?.map(\.memory) }
        #expect(moved, "κ 0.5 did not move the memory")
        let session = try SessionReader.read(url)
        #expect(session.header.gate.moduleGain == 0.5 && session.header.module != nil)
        let issues = SessionReplay.check(session.generations[0], session: session)
        #expect(issues.isEmpty, "\(issues.map(\.description))")
        // The replay re-enters the module's evidence from the log: without `mod` the memory recursion breaks.
        var stripped = session.generations[0]
        for k in stripped.steps.indices where stripped.steps[k].threads != nil {
            for t in stripped.steps[k].threads!.indices { stripped.steps[k].threads![t].module = nil }
        }
        let missing = SessionReplay.check(stripped, session: session)
        #expect(missing.contains { $0.check == "memory" }, "\(missing.map(\.description))")
    }
}
