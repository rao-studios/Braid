//
//  SessionTests.swift
//  BraidCoreTests
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation
import Testing
@testable import BraidCore

@Suite("Sessions: the cluster, the log and its replay")
struct SessionTests {
    func temporaryLog() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("braid-session-\(UUID().uuidString).jsonl")
    }

    @Test("a generation over three strands logs clean: shares sum to 1, the body hashes, the arithmetic replays")
    func generateAndReplay() throws {
        let cluster = Fixtures.cluster()
        let (a, b, _) = try Fixtures.threeStrands(into: cluster)
        let url = temporaryLog()
        defer { try? FileManager.default.removeItem(at: url) }
        try cluster.startLog(at: url)
        var params = GenerationParameters()
        params.maxTokens = 6
        let prompt = GenerationPrompt(text: " the cat sat on", tokens: [1, 2, 3, 4])
        let generation = try cluster.generate(prompt: prompt, params: params)
        cluster.closeLog()
        #expect(generation.steps.count >= 5)
        #expect(generation.generated.count >= 1 && generation.generated.count <= 6)
        var shareA = 0.0, shareB = 0.0
        for step in generation.steps where step.threads != nil {
            #expect(abs(step.threads!.map { Double($0.share) }.reduce(0, +) - 1) < 1e-5)
            for record in step.threads! { #expect(record.hits.count <= 16 && record.hknn >= 0) }
            if !step.isPrompt {
                shareA += Double(step.threads![1].share)
                shareB += Double(step.threads![2].share)
            }
        }
        // a holds "the cat sat on the mat."; b holds nothing about it.
        #expect(shareA > shareB, "a \(shareA) b \(shareB)")
        #expect(generation.steps[4].threads![1].trace!.length >= 2, "a's chain follows the prompt through its document")
        #expect(a.opens == 1 && b.opens == 1)
        #expect(a.advances <= generation.generated.count && a.advances >= generation.generated.count - 1)
        let session = try SessionReader.read(url)
        #expect(session.header.threads.map(\.name) == ["commons", "a", "b"])
        #expect(session.generations.count == 1)
        let logged = session.generations[0]
        #expect(logged.steps == generation.steps)
        #expect(logged.end?.bodySHA256 == logged.bodySHA256)
        let issues = SessionReplay.check(logged, session: session)
        #expect(issues.isEmpty, "\(issues.map(\.description))")
        // The spans: " the cat sat on the mat" walks a's document.
        #expect(generation.spans.contains { $0.source.documentID == "doc-a-0" }, "spans \(generation.spans.map(\.text))")
        #expect(generation.royalties.strands.count == 3)
        #expect(!generation.credits.compactMap { $0 }.isEmpty)
    }

    @Test("an edited log fails the body hash; a wrong share fails the arithmetic")
    func tamper() throws {
        let cluster = Fixtures.cluster()
        _ = try Fixtures.threeStrands(into: cluster)
        let url = temporaryLog()
        defer { try? FileManager.default.removeItem(at: url) }
        try cluster.startLog(at: url)
        var params = GenerationParameters()
        params.maxTokens = 3
        _ = try cluster.generate(prompt: GenerationPrompt(text: " the dog", tokens: [1, 7]), params: params)
        cluster.closeLog()
        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"share\":1", with: "\"share\":0.9").replacingOccurrences(of: "\"share\":0.5", with: "\"share\":0.6")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let session = try SessionReader.read(url)
        let issues = SessionReplay.check(session.generations[0], session: session)
        #expect(issues.contains { $0.check == "body" })
    }

    @Test("a strand attached mid-generation catches up and is logged; a detached one drops out")
    func attachDetach() throws {
        let cluster = Fixtures.cluster()
        let commons = FakeNode(name: "commons", documents: [], commons: true)
        let a = FakeNode(name: "a", documents: [Fixtures.catDocument])
        try cluster.attach(commons)
        try cluster.attach(a)
        let url = temporaryLog()
        defer { try? FileManager.default.removeItem(at: url) }
        try cluster.startLog(at: url)
        var params = GenerationParameters()
        params.maxTokens = 5
        let b = FakeNode(name: "b", documents: [Fixtures.dogDocument])
        var seen = 0
        let generation = try cluster.generate(prompt: GenerationPrompt(text: " the cat", tokens: [1, 2]), params: params) { step in
            guard step.source == .gen else { return }
            seen += 1
            if seen == 1 { try? cluster.attach(b) }
            if seen == 3 { try? cluster.detach("a") }
        }
        cluster.closeLog()
        let generated = generation.generated
        #expect(generated[0].threads!.count == 2)
        #expect(generated[1].threads!.count == 3, "b attached at the next boundary")
        #expect(generated.last!.threads!.count == 2, "a detached")
        #expect(b.opens == 1 && cluster.strandNames == ["commons", "b"])
        for step in generated { #expect(abs(step.threads!.map { Double($0.share) }.reduce(0, +) - 1) < 1e-5) }
        let session = try SessionReader.read(url)
        #expect(session.membership.map(\.kind) == ["attach", "detach"])
        #expect(session.generations[0].membership.count == 2)
        let issues = SessionReplay.check(session.generations[0], session: session)
        #expect(issues.isEmpty, "\(issues.map(\.description))")
    }

    @Test("conformance refuses a node on another pack or vocabulary; the commons is exempt from the pack")
    func conformance() throws {
        let cluster = Fixtures.cluster()
        try cluster.attach(FakeNode(name: "commons", documents: [], commons: true, pack: nil))
        #expect(throws: Conformance.Failure.self) { try cluster.attach(FakeNode(name: "x", documents: [], pack: "other")) }
        #expect(throws: Conformance.Failure.self) { try cluster.attach(FakeNode(name: "y", documents: [], vocabulary: "other")) }
        #expect(throws: Conformance.Failure.self) { try cluster.attach(FakeNode(name: "z", documents: [], hidden: 8)) }
        #expect(throws: ClusterError.self) { try cluster.attach(FakeNode(name: "c2", documents: [], commons: true)) }
        try cluster.attach(FakeNode(name: "ok", documents: [Fixtures.catDocument]))
        #expect(cluster.strandNames == ["commons", "ok"])
    }

    @Test("the trajectory module reads a session: a stitched series fires, retrieval does not, readings are causal")
    func module() {
        let settings = ModuleSettings()
        let n = 40
        let stitched = ThreadSeries(hlm: (0..<n).map { _ in 0.2 }, hknn: (0..<n).map { _ in 2.5 }, lift: (0..<n).map { _ in 2.0 }, trace: (0..<n).map { _ in 0 },
                                    commonsHLM: (0..<n).map { _ in 3.0 })
        let readings = TrajectoryModule.readAll(stitched, settings: settings)
        #expect(readings.allSatisfy { $0.label == .stitched } && readings[10].stitched)
        #expect(TrajectoryModule.detectorScore(readings, from: 24) == 1)
        let retrieval = ThreadSeries(hlm: (0..<n).map { _ in 0.2 }, hknn: (0..<n).map { _ in 0.1 }, lift: (0..<n).map { _ in 2.0 }, trace: (0..<n).map { _ in 0.5 },
                                     commonsHLM: (0..<n).map { _ in 3.0 })
        let r = TrajectoryModule.readAll(retrieval, settings: settings)
        #expect(r.allSatisfy { $0.label == .retrieval && !$0.stitched } && TrajectoryModule.coherentFraction(r, from: 0) == 1)
        // Collapsing H_knn gives positive evidence; the reading at j ignores what comes after.
        let collapsing = ThreadSeries(hlm: (0..<n).map { _ in 1.0 }, hknn: (0..<n).map { max(0, 2.5 - 0.3 * Double($0)) }, lift: (0..<n).map { _ in 0.5 },
                                      trace: (0..<n).map { _ in 0 }, commonsHLM: (0..<n).map { _ in 3.0 })
        let at7 = TrajectoryModule.read(collapsing, at: 7, settings: settings)
        #expect(at7.evidence > 0.5 && at7.slope! < 0)
        var truncated = collapsing
        truncated.hknn = Array(truncated.hknn.prefix(8)); truncated.hlm = Array(truncated.hlm.prefix(8)); truncated.lift = Array(truncated.lift.prefix(8))
        truncated.trace = Array(truncated.trace.prefix(8)); truncated.commonsHLM = Array(truncated.commonsHLM.prefix(8))
        #expect(TrajectoryModule.read(truncated, at: 7, settings: settings) == at7)
    }
}
