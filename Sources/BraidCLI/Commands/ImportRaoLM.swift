//
//  ImportRaoLM.swift
//  BraidCLI
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: `braid import-raolm <dump>`: RaoLM's trajectory-bench records (a CitedGeneration per scored
//        text, the base pass and each gate arm) become Braid session logs with `source: raolm`,
//        under raolm-import/ in the work area by default, beside an import.json that says what was
//        imported from where, how each field maps, and which `braid verify` checks such a log takes.
//        `--check` validates the port against the same records instead and prints its table: (a)
//        the shares from RaoLM's gate and probabilities, (b) Braid's tracker replaying RaoLM's chains
//        over its index layouts, (c) phase A — T1–T3 from the dump's traces against RaoLM's own
//        verdicts, and the regate under Braid's live gate against RaoLM's "no agreement" arm.
//  PIN:  No model and no GPU. Reads the dump and RaoLM's node indexes; writes only under --out.
//        Exit 0; 65 when a check fails.
//

import ArgumentParser
import BraidKit
import Foundation

struct ImportRaoLMCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import-raolm",
        abstract: "RaoLM trajectory-bench records → Braid session logs (source raolm); --check validates the port against them.")

    static let defaultOut = WorkArea.t9.appendingPathComponent("raolm-import", isDirectory: true)

    @Argument(help: "The dump: index.json, a record per scored text, arms/<arm>/ (RaoLM's bench-trajectory --dump).")
    var dump: String
    @Option(help: "One set: base, or a gate arm by name (\"no agreement\") or directory (no-agreement). Default: the base pass and every complete arm.")
    var arm: String?
    @Option(help: "Where the logs and import.json (or check.json) go (default: /Volumes/T9/rao/projects/braid/raolm-import).")
    var out: String?
    @Flag(help: "Validate instead of importing: (a) shares, (b) the trace replay, (c) phase A; prints the table and writes check.json.")
    var check = false

    func run() throws {
        guarded {
            let dumpURL = URL(fileURLWithPath: (dump as NSString).expandingTildeInPath, isDirectory: true)
            let outURL = out.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) } ?? Self.defaultOut
            let index = try RaoLMDumpIndex.load(from: dumpURL)
            let dataRoot = URL(fileURLWithPath: index.dataRoot, isDirectory: true)
            let all = RaoLMPort.sets(dump: dumpURL, index: index)
            for set in all where !set.complete { note("import-raolm: \(set.name) is missing \(set.missing.count) of \(set.texts.count) records; left out") }
            let sets = try RaoLMPort.select(all, only: arm)
            guard let first = sets.first?.texts.first else { throw BraidFailure.missing("no complete set in \(dumpURL.path)") }
            // The node indexes, from the first record: every record must name the same.
            let probe = try RaoLMGeneration.load(from: dumpURL.appendingPathComponent(sets[0].directory, isDirectory: true).appendingPathComponent(first.file))
            guard let braid = probe.braid else { throw BraidFailure.data("\(first.file) is not a braided generation") }
            note("import-raolm: loading RaoLM's node indexes under \(dataRoot.path)")
            let indexes = try RaoLMPort.indexes(of: braid, dataRoot: dataRoot)
            let nodes = RaoLMPort.nodeRecords(braid, indexes: indexes)
            let jobs = max(1, min(6, ProcessInfo.processInfo.activeProcessorCount / 2))
            let started = Date()
            if check {
                try runCheck(sets: sets, dump: dumpURL, index: index, dataRoot: dataRoot, indexes: indexes, nodes: nodes, out: outURL, jobs: jobs)
            } else {
                try runImport(sets: sets, dump: dumpURL, dataRoot: dataRoot, indexes: indexes, nodes: nodes, out: outURL, jobs: jobs)
            }
            fflush(stdout)
            note(String(format: "import-raolm: %.0f s", Date().timeIntervalSince(started)))
        }
    }

    /// Every record of every set written as a session log, then import.json.
    func runImport(sets: [RaoLMPort.RecordSet], dump: URL, dataRoot: URL, indexes: [String: RaoLMIndex], nodes: [RaoLMPort.NodeIndex], out: URL, jobs: Int) throws {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var summaries: [RaoLMPort.ImportReport.SetSummary] = []
        print("import-raolm · \(dump.path) → \(out.path)")
        print("  \("set".padding(toLength: 16, withPad: " ", startingAt: 0)) records   steps     strand-positions without hits")
        for set in sets {
            let outcomes = RaoLMPort.run(set: set, dump: dump, indexes: indexes, dataRoot: dataRoot, mode: .write(out), jobs: jobs) { note("import-raolm: \($0)") }
            let report = RaoLMPort.SetReport(set: set, outcomes: outcomes)
            summaries.append(RaoLMPort.ImportReport.SetSummary(report))
            print("  \(set.name.padding(toLength: 16, withPad: " ", startingAt: 0)) \(pad(report.records, 9)) \(pad(report.steps, 9)) \(pad(report.missingHits, 30)) → \(out.appendingPathComponent(report.directory).path)/")
            for error in report.errors.prefix(5) { print("    ✗ \(error)") }
        }
        let report = RaoLMPort.ImportReport(createdAt: BenchFormat.wholeSecond(), dump: dump.path, dataRoot: dataRoot.path, nodes: nodes, sets: summaries)
        let url = out.appendingPathComponent(RaoLMPort.ImportReport.fileName)
        try JSONCoding.write(report, to: url)
        print("import.json → \(url.path)")
        print("  braid verify on these logs: " + RaoLMPort.verifyChecks.sorted { $0.key < $1.key }.filter { $0.value.hasPrefix("skipped") || $0.value.hasPrefix("refused") }
            .map { "\($0.key) \($0.value.prefix(7))" }.joined(separator: "; "))
        if summaries.contains(where: { !$0.errors.isEmpty }) { throw BraidFailure.data("some records did not import") }
    }

    /// The check report: every set's record-level checks and phase A.
    struct CheckReport: Encodable {
        var createdAt: Date
        var dump: String
        var dataRoot: String
        var raolmReport: String?
        var nodes: [RaoLMPort.NodeIndex]
        var sets: [RaoLMPort.SetReport]
        var phaseA: RaoLMPhaseA.Report?
        var passes: [String: Bool]
    }

    func runCheck(sets: [RaoLMPort.RecordSet], dump: URL, index: RaoLMDumpIndex, dataRoot: URL, indexes: [String: RaoLMIndex], nodes: [RaoLMPort.NodeIndex],
                  out: URL, jobs: Int) throws {
        var reports: [RaoLMPort.SetReport] = []
        var scored: [String: [String: RaoLMCheck.ScoredText]] = [:]
        var lambda = 0.5
        for set in sets {
            let outcomes = RaoLMPort.run(set: set, dump: dump, indexes: indexes, dataRoot: dataRoot, mode: .check, jobs: jobs) { note("import-raolm: \($0)") }
            reports.append(RaoLMPort.SetReport(set: set, outcomes: outcomes))
            scored[set.name] = Dictionary(outcomes.compactMap { o in o.scored.map { (o.text.file, $0) } }, uniquingKeysWith: { first, _ in first })
            note("import-raolm: \(set.name) checked (\(outcomes.count) records)")
        }
        if let probe = try? RaoLMGeneration.load(from: dump.appendingPathComponent(sets[0].directory, isDirectory: true).appendingPathComponent(sets[0].texts[0].file)) {
            lambda = Double(probe.params.lambda)
        }
        let reportURL = [dump.appendingPathComponent("trajectory.json"), dataRoot.appendingPathComponent("bench/trajectory.json")]
            .first { FileManager.default.fileExists(atPath: $0.path) }
        let raolm = try reportURL.map { try RaoLMTrajectoryReport.load(from: $0) }
        let rule = raolm?.traceRule ?? .standard
        var phaseA: RaoLMPhaseA.Report?
        if let base = scored["base"] {
            var arms = scored
            arms["base"] = nil
            phaseA = RaoLMPhaseA.run(index: index, base: base, arms: arms, report: raolm, rule: rule, lambda: lambda)
        } else {
            note("import-raolm: phase A needs the base pass; it is not among the sets checked")
        }

        // The table.
        print("port validation · \(dump.path)")
        print("  RaoLM's report: \(reportURL?.path ?? "none found (looked at <dump>/trajectory.json and <dataRoot>/bench/trajectory.json)")")
        for node in nodes {
            print("  \(node.name.padding(toLength: 8, withPad: " ", startingAt: 0)) v\(node.version) epoch \(node.epoch)  index \(node.sha256.prefix(12))  \(node.entries) entries from \(node.entryOffset), rows \(node.rowOffset)..<\(node.rowOffset + node.rowCount)")
        }
        print("")
        print("(a) shares: share_t = w′_t·p_t(y)/p(y), w′ the gate renormalised over the open strands, p_t RaoLM's alone; tolerance 1e-5")
        print("    \("set".padding(toLength: 14, withPad: " ", startingAt: 0)) records positions  values   max|Δ| alone  max|Δ| gate/lmProb/knn  max rel|Δp|  max|Δλ|   p_t from hits (n, max|Δ|)   verdict")
        for r in reports {
            let s = r.shares
            print("    \(r.name.padding(toLength: 14, withPad: " ", startingAt: 0)) \(pad(r.records, 7)) \(pad(s.positions, 9)) \(pad(s.values, 8))  \(sci(s.maxErrorAlone).padding(toLength: 12, withPad: " ", startingAt: 0))  \(sci(s.maxErrorLogged).padding(toLength: 21, withPad: " ", startingAt: 0))  \(sci(s.maxRelativeP).padding(toLength: 11, withPad: " ", startingAt: 0))  \(sci(s.maxLambdaError).padding(toLength: 8, withPad: " ", startingAt: 0))  \(pad(s.aloneFromHits, 8)) \(sci(s.maxAloneFromHitsError).padding(toLength: 16, withPad: " ", startingAt: 0))  \(s.passes ? "PASS" : "FAIL")")
        }
        let shares = reports.reduce(into: RaoLMCheck.Shares()) { $0.add($1.shares) }
        if let worst = shares.worst { print("    largest: \(worst.file) trace \(worst.index) \(worst.strand): recomputed \(String(format: "%.9f", worst.recomputed)), logged \(worst.logged)") }
        print("")
        print("(b) trace: Braid's TraceTracker on RaoLM's tokens and each strand's own hits over its index layout, against RaoLM's trajectory length and next")
        print("    \("set".padding(toLength: 14, withPad: " ", startingAt: 0)) \("strand".padding(toLength: 8, withPad: " ", startingAt: 0)) positions  matched   lacking hits  failed  after a lack (explained)")
        for r in reports {
            for (name, t) in r.traces.strands.sorted(by: { $0.key < $1.key }) {
                print("    \(r.name.padding(toLength: 14, withPad: " ", startingAt: 0)) \(name.padding(toLength: 8, withPad: " ", startingAt: 0)) \(pad(t.positions, 9)) \(pad(t.matched, 9)) \(pad(t.missingHits, 12)) \(pad(t.mismatches, 7)) \(t.mismatchesAfterMissing) (\(t.explained))")
            }
        }
        let traces = reports.reduce(into: RaoLMCheck.Traces()) { $0.add($1.traces) }
        for m in traces.mismatches.prefix(12) {
            print("    · \(m.set) \(m.file) \(m.strand) trace \(m.index): logged L=\(m.loggedLength) next \(m.loggedNext.map(String.init) ?? "—"), replayed L=\(m.replayedLength) next \(m.replayedNext.map(String.init) ?? "—")"
                + (m.afterMissingHits ? "; the record lacks this strand's hits at trace\(m.missingNear.count == 1 ? "" : "s") \(m.missingNear.map(String.init).joined(separator: ", "))" : "; every earlier hit present"))
        }
        let mapping = reports.reduce(into: RaoLMCheck.Mapping()) { $0.add($1.mapping) }
        print("    mapping: \(mapping.hits) pooled hits → \(mapping.outside) off their node, \(mapping.valueMismatches) value and \(mapping.keyMismatches) key mismatches against the node's index; \(mapping.chains) logged chains, \(mapping.chainMismatches) off the index; \(mapping.traces) node traces, \(mapping.traceMismatches) not the rule's")
        let verify = reports.reduce(into: RaoLMPort.VerifyTally()) { $0.add($1.verify) }
        print("    braid verify on the imported sessions: \(verify.logs) logs, \(verify.issues) issues; trace \(verify.traceMismatches) failed, \(verify.traceUnreplayable) unreplayable; skipped: \(verify.skipped.joined(separator: ", "))")
        for row in phaseA?.armChains ?? [] {
            print("    \(row.arm.padding(toLength: 14, withPad: " ", startingAt: 0)) logged chains equal the base pass's on \(row.equal) of \(row.positions) strand-positions (\(row.records) records)")
        }
        for issue in verify.firstIssues.prefix(5) { print("      ✗ \(issue)") }
        print("")
        if let a = phaseA {
            print("(c) phase A: Braid's trace-bench rules on RaoLM's traces (values from token \(a.from); the chain after the last token by Braid's tracker)")
            print("    \("rule".padding(toLength: 26, withPad: " ", startingAt: 0)) Braid  RaoLM  Braid's window")
            for (v, w) in zip(a.verdicts, a.braidWindowVerdicts) {
                print("    \(v.rule.padding(toLength: 26, withPad: " ", startingAt: 0)) \(word(v.braid))   \(v.raolm.map(word) ?? "—   ")   \(word(w.braid))   \(v.agrees ? "equal" : "DIFFER")")
                print("      Braid: \(v.braidDetail)")
                if let detail = v.raolmDetail { print("      RaoLM: \(detail)") }
            }
            let r = a.readings
            print("    readings against trajectory.json: \(r.readings) text×strand; trace equal \(r.traceEqual) (max |Δ| \(sci(Double(r.maxTraceDifference)))), longest equal \(r.longestEqual), wire longest equal \(r.wireLongestEqual)")
            let g = a.regate
            print("    regate under Braid's live gate (memory + lift over the commons) on \(g.texts) told/source texts, \(g.answerTokens) answer tokens:")
            print("      holder share: live \(BenchFormat.num(g.live, 5)), shadow β4 \(BenchFormat.num(g.shadow, 5)); RaoLM \"no agreement\" \(BenchFormat.num(g.reference, 5)) → |Δ| \(sci(Double(abs((g.live ?? 0) - (g.reference ?? 0))))) within ±\(RaoLMPhaseA.regateTolerance): \(g.passes ? "PASS" : "FAIL")")
            print("      live shares against the no-agreement arm's logged shares: max |Δ| \(g.maxShareDifference.map(sci) ?? "—") over \(g.comparedShares) values")
            print("      Gate.observe against RaoLM's logged memory: max |Δ| \(sci(g.maxMemoryDifference)) over \(g.memoryPositions) positions of \(g.memoryTexts) base texts")
            print("    holder share of told and source answer tokens:")
            print("      \("arm".padding(toLength: 16, withPad: " ", startingAt: 0)) RaoLM reported  from its records  |Δ|        not asked (reported / records)")
            for row in a.arms {
                let delta = row.reported.flatMap { r in row.recomputed.map { sci(Double(abs(r - $0))) } } ?? "—"
                print("      \(row.arm.padding(toLength: 16, withPad: " ", startingAt: 0)) \(BenchFormat.num(row.reported, 6).padding(toLength: 15, withPad: " ", startingAt: 0)) \(BenchFormat.num(row.recomputed, 6).padding(toLength: 16, withPad: " ", startingAt: 0)) \(delta.padding(toLength: 10, withPad: " ", startingAt: 0)) \(BenchFormat.num(row.notAskedReported)) / \(BenchFormat.num(row.notAskedRecomputed))")
            }
            for arm in a.braidArms.prefix(1) {
                print("      \("Braid live gate".padding(toLength: 16, withPad: " ", startingAt: 0)) \(BenchFormat.num(arm.live))  (\(arm.set), \(arm.texts) texts, \(arm.answerTokens) tokens; memory only, regated)")
                print("      \("Braid shadow β4".padding(toLength: 16, withPad: " ", startingAt: 0)) \(BenchFormat.num(arm.shadow))  (over the regated memory and RaoLM's traces)")
            }
            print("    \(a.quoted)")
            print("")
        }
        let passesA = reports.allSatisfy { $0.shares.passes }
        let passesB = reports.allSatisfy { $0.traces.passes && $0.mapping.passes } && verify.issues == 0
        let passesC = phaseA?.passes
        let report = CheckReport(createdAt: BenchFormat.wholeSecond(), dump: dump.path, dataRoot: dataRoot.path, raolmReport: reportURL?.path, nodes: nodes,
                                 sets: reports, phaseA: phaseA, passes: ["a": passesA, "b": passesB, "c": passesC ?? false])
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let url = out.appendingPathComponent("check.json")
        try JSONCoding.write(report, to: url)
        print("verdict: (a) \(word(passesA))  (b) \(word(passesB))  (c) \(passesC.map(word) ?? "not run")")
        print("check.json → \(url.path)")
        for r in reports where !r.errors.isEmpty { for error in r.errors.prefix(5) { print("  ✗ \(error)") } }
        if !passesA || !passesB || passesC == false || reports.contains(where: { !$0.errors.isEmpty }) {
            throw BraidFailure.data("the port validation fails")
        }
    }

    func pad(_ value: Int, _ width: Int) -> String { String(value).padding(toLength: width, withPad: " ", startingAt: 0) }
    func sci(_ value: Double) -> String { String(format: "%.2e", value) }
    func word(_ passes: Bool) -> String { passes ? "PASS" : "FAIL" }
}
