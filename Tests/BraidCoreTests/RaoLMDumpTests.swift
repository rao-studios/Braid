//
//  RaoLMDumpTests.swift
//  BraidCoreTests
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The port validation over a slice of the real RaoLM dump: the first records of the base pass
//        and of the "no agreement" arm import, verify clean, recompute their shares within 1e-5 and
//        replay their chains over RaoLM's own node indexes; one is written with an import.json and
//        verified the way `braid verify` finds its layouts. Only with BRAID_RAOLM_DUMP=1 (the dump is
//        on the T9; BRAID_RAOLM_DUMP_DIR names another place). Writes only to a temporary directory.
//

import Foundation
import Testing
@testable import BraidCore

let raolmDumpTests: Bool = ProcessInfo.processInfo.environment["BRAID_RAOLM_DUMP"] == "1"

func raolmDump() -> URL {
    URL(fileURLWithPath: ProcessInfo.processInfo.environment["BRAID_RAOLM_DUMP_DIR"] ?? "/Volumes/T9/rao/projects/braid/raolm-dump", isDirectory: true)
}

@Suite("RaoLM dump: a slice of the real records", .enabled(if: raolmDumpTests))
struct RaoLMDumpTests {
    @Test("the base pass and the no-agreement arm: shares within 1e-5, every chain replayed, verify clean")
    func slice() throws {
        let dump = raolmDump()
        let index = try RaoLMDumpIndex.load(from: dump)
        let dataRoot = URL(fileURLWithPath: index.dataRoot, isDirectory: true)
        var sets = RaoLMPort.sets(dump: dump, index: index)
        #expect(sets.first?.name == "base" && sets.first?.complete == true)
        sets = sets.filter { $0.name == "base" || $0.name == "no agreement" }
        sets[0].texts = Array(sets[0].texts.prefix(10))
        sets[1].texts = Array(sets[1].texts.prefix(5))
        let probe = try RaoLMGeneration.load(from: dump.appendingPathComponent(sets[0].texts[0].file))
        let indexes = try RaoLMPort.indexes(of: try #require(probe.braid), dataRoot: dataRoot)
        #expect(indexes.keys.sorted() == ["ambient", "craft", "veil"])
        for set in sets {
            let report = RaoLMPort.SetReport(set: set, outcomes: RaoLMPort.run(set: set, dump: dump, indexes: indexes, dataRoot: dataRoot, mode: .check, jobs: 2))
            #expect(report.errors.isEmpty, "\(report.errors)")
            #expect(report.records == set.texts.count)
            #expect(report.shares.passes && report.shares.maxError <= RaoLMCheck.shareTolerance, "\(set.name): \(report.shares.maxError)")
            #expect(report.mapping.passes, "\(report.mapping)")
            #expect(report.traces.passes && report.traces.strands.values.allSatisfy { $0.mismatches == 0 }, "\(report.traces.mismatches.prefix(3))")
            #expect(report.verify.issues == 0 && report.verify.skipped == ["memory recursion", "shadow β4", "spans"], "\(report.verify.firstIssues)")
        }
    }

    @Test("an imported log beside its import.json verifies with the layouts found by sha")
    func writtenLogVerifies() throws {
        let dump = raolmDump()
        let index = try RaoLMDumpIndex.load(from: dump)
        let dataRoot = URL(fileURLWithPath: index.dataRoot, isDirectory: true)
        var set = RaoLMPort.sets(dump: dump, index: index)[0]
        set.texts = [set.texts[0]]
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("braid-raolm-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: out) }
        let probe = try RaoLMGeneration.load(from: dump.appendingPathComponent(set.texts[0].file))
        let braid = try #require(probe.braid)
        let indexes = try RaoLMPort.indexes(of: braid, dataRoot: dataRoot)
        let outcomes = RaoLMPort.run(set: set, dump: dump, indexes: indexes, dataRoot: dataRoot, mode: .write(out), jobs: 1)
        #expect(outcomes.allSatisfy { $0.error == nil }, "\(outcomes.compactMap(\.error))")
        let report = RaoLMPort.ImportReport(createdAt: Date(), dump: dump.path, dataRoot: dataRoot.path, nodes: RaoLMPort.nodeRecords(braid, indexes: indexes),
                                            sets: [RaoLMPort.ImportReport.SetSummary(RaoLMPort.SetReport(set: set, outcomes: outcomes))])
        try JSONCoding.write(report, to: out.appendingPathComponent(RaoLMPort.ImportReport.fileName))
        let log = out.appendingPathComponent("base").appendingPathComponent((set.texts[0].file as NSString).deletingPathExtension + ".jsonl")
        let session = try SessionReader.read(log)
        #expect(session.header.source == "raolm" && session.header.pack.name == "rao-commons-1" && session.header.pack.hiddenSize == 576)
        let (found, _) = try #require(RaoLMPort.ImportReport.find(near: log))
        let layouts = try RaoLMPort.layouts(for: session, report: found)
        #expect(layouts.keys.sorted() == ["ambient", "craft", "veil"])
        let verified = Verifier.verify(session: session, name: log.lastPathComponent, layouts: { layouts[$0] }, reader: nil, tokenizer: nil)
        #expect(verified.status == .ok, "\(verified.issues.prefix(5).map(\.description))")
        #expect(verified.traces.count == 3 && verified.traces.allSatisfy { $0.positions == set.texts[0].tokens - 1 && $0.mismatches == 0 })
    }
}
