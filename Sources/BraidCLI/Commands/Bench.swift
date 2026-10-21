//
//  Bench.swift
//  BraidCLI
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: `braid bench trace|gaming|lift|stitched|entropy|question --dataset <name>`: the acceptance
//        benches on the braid in the work area (the commons and the named Threads on their live
//        versions), each printing its rules table (id, verdict, the numbers), keeping its session logs
//        and writing a JSON report; `--rescore <json>` re-applies the rules to a saved report without a
//        model. `braid bench replacement` reads the A (κ 0) and B (κ > 0) reports and the verify
//        reports of B's sessions and applies R1–R3. Rules are fixed before numbers; a bench never
//        changes a default (`--module-gain` sets κ for one run only).
//

import ArgumentParser
import BraidKit
import Foundation

struct BenchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bench",
        abstract: "The acceptance benches, rules fixed before numbers: trace (T1–T3), gaming (G1–G3), lift (L1–L4), stitched (S1–S3), entropy (E1–E3), question (Q1–Q5b), replacement (R1–R3), sweep-key (the key schemes).",
        subcommands: [Trace.self, Gaming.self, Lift.self, Stitched.self, Entropy.self, Question.self, Replacement.self, SweepKeyCommand.self])

    struct Options: ParsableArguments {
        @OptionGroup var workArea: WorkAreaOptions
        @Option(help: "The braid dataset the Threads were fed from (default: the dataset the first Thread's source names).")
        var dataset: String?
        @Option(help: "Comma-separated Thread names (default: braid.toml's [cluster] attach).")
        var threads: String?
        @Option(help: "Where to write the report (default: <work area>/bench/<bench>/<stamp>.json).")
        var report: String?
        @Option(help: "Re-apply the rules to a saved report instead of running the braid.")
        var rescore: String?
        @Option(name: .customLong("per-node"), help: "Texts (trace) or prompts (gaming, lift facts) per Thread.")
        var perNode: Int?
        @Option(help: "The seed the shuffles draw from.")
        var seed: UInt64 = 42
        @Flag(name: .customLong("no-commons"), help: "Leave the commons out (trace and gaming only; the gate then uses absolute evidence).")
        var noCommons = false
        @Option(name: .customLong("module-gain"), help: "κ for this run: the trajectory module's weight in the gate's evidence (default: braid.toml's [gate] module_gain). Recorded in the report and the session header.")
        var moduleGain: Double?
        @Option(help: "Two Threads holding the same documents, comma-separated: G3 (gaming) and Q5b (question) run on a copy braid of the commons and these two.")
        var copy: String?

        var threadNames: [String]? {
            threads.map { $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        }

        var copyNames: [String]? {
            copy.map { $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        }

        /// The copy braid `--copy` names, sharing the braid's loaded nodes.
        func copyBraid(of braid: BenchBraid) throws -> BenchBraid? {
            guard let names = copyNames else { return nil }
            guard names.count == 2 else { throw BraidFailure.usage("--copy takes two Threads: a,b") }
            return try braid.subBraid(threads: names) { note("bench: \($0)") }
        }

        func url(_ path: String) -> URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }

        /// The braid in the work area and the dataset world its Threads were fed from.
        func assemble(commons: Bool) throws -> (BenchBraid, BenchWorld) {
            let area = try workArea.resolve()
            var config = try workArea.config(in: area)
            if let moduleGain {
                guard moduleGain >= 0 else { throw BraidFailure.usage("--module-gain is κ ≥ 0, not \(moduleGain)") }
                config.gate.moduleGain = moduleGain
                note("bench: κ \(moduleGain) for this run (braid.toml unchanged)")
            }
            guard let packRecord = config.pack, let pack = try Packs.find(packRecord.sha256, in: area) else { throw BraidFailure.missing("braid.toml names no pack that is on disk") }
            let names = (threadNames ?? config.attach).filter { !$0.isEmpty }
            guard let first = names.first else { throw BraidFailure.usage("no Threads: pass --threads or create one") }
            var datasetName = dataset
            if datasetName == nil, case .dataset(let nameOrPath, _)? = try? CorpusSourceSpec(parsing: try ThreadStore.info(area.thread(first)).source) {
                datasetName = nameOrPath
            }
            guard let datasetName else { throw BraidFailure.usage("pass --dataset <name>: thread \(first) was not fed from a dataset") }
            let directory = try DatasetsRoot.locate(datasetName, root: DatasetsRoot.resolve(workArea: area.root))
            note("bench: loading dataset \(directory.path)")
            let world = BenchWorld(dataset: try BraidDataset.load(directory))
            let braid = try BenchBraid.assemble(area: area, config: config, pack: pack, threadNames: names, commons: commons) { note("bench: \($0)") }
            return (braid, world)
        }

        /// Where the report goes: `--report`, else the work area's bench folder (a rescore without `--report` is only printed).
        func output(bench: String, rescoring: Bool) throws -> URL? {
            if let report { return url(report) }
            if rescoring { return nil }
            return BenchFormat.reportURL(area: try workArea.resolve(), bench: bench)
        }

        func write<T: Encodable>(_ report: T, bench: String, rescoring: Bool) throws {
            guard let url = try output(bench: bench, rescoring: rescoring) else { return }
            try JSONCoding.write(report, to: url)
            print("report → \(url.path)")
        }
    }

    struct Trace: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "trace", abstract: "T1–T3: the trace tells a Thread's own text from a pastiche of it; the holder's share of told and source answers under the live gate and the shadow β4 is reported.")
        @OptionGroup var options: Options

        func run() throws {
            guarded {
                if let path = options.rescore {
                    let report = TraceBench.rescore(try JSONCoding.read(TraceReport.self, from: options.url(path)))
                    BenchTable.print(report)
                    try options.write(report, bench: "trace", rescoring: true)
                    return
                }
                let (braid, world) = try options.assemble(commons: !options.noCommons)
                var sizes = BenchTextSizes()
                if let perNode = options.perNode { sizes.perNode = perNode }
                sizes.seed = options.seed
                let started = Date()
                let report = try TraceBench.run(braid: braid, world: world, sizes: sizes) { note("bench trace: \($0)") }
                note(String(format: "bench trace: %d texts in %.0f s", report.texts.count, Date().timeIntervalSince(started)))
                BenchTable.print(report)
                try options.write(report, bench: "trace", rescoring: false)
            }
        }
    }

    struct Gaming: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "gaming", abstract: "G1–G3: on subjects nobody holds and generic prose every Thread stays open and the largest gate stays bounded; copies tie.")
        @OptionGroup var options: Options

        func run() throws {
            guarded {
                if let path = options.rescore {
                    let report = GamingBench.rescore(try JSONCoding.read(GamingReport.self, from: options.url(path)))
                    BenchTable.print(report)
                    try options.write(report, bench: "gaming", rescoring: true)
                    return
                }
                let (braid, world) = try options.assemble(commons: !options.noCommons)
                let copies = try options.copyBraid(of: braid)
                let started = Date()
                let report = try GamingBench.run(braid: braid, world: world, perNode: options.perNode ?? 10, copies: copies) { note("bench gaming: \($0)") }
                note(String(format: "bench gaming: %d prompts in %.0f s", report.rows.count, Date().timeIntervalSince(started)))
                BenchTable.print(report)
                try options.write(report, bench: "gaming", rescoring: false)
            }
        }
    }

    struct Lift: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "lift", abstract: "L1–L4: the commons leads nobody's text, inherited knowledge is not attributed, the owner's lift carries its facts; held-out NLL against the commons alone reported.")
        @OptionGroup var options: Options

        func run() throws {
            guarded {
                if let path = options.rescore {
                    let report = LiftBench.rescore(try JSONCoding.read(LiftReport.self, from: options.url(path)))
                    BenchTable.print(report)
                    try options.write(report, bench: "lift", rescoring: true)
                    return
                }
                if options.noCommons { throw BraidFailure.usage("bench lift needs the commons in the braid") }
                let (braid, world) = try options.assemble(commons: true)
                var sizes = LiftBench.Sizes()
                if let perNode = options.perNode { sizes.factsPerNode = perNode }
                let started = Date()
                let report = try LiftBench.run(braid: braid, world: world, sizes: sizes) { note("bench lift: \($0)") }
                note(String(format: "bench lift: %d prompts and texts in %.0f s", report.rows.count, Date().timeIntervalSince(started)))
                BenchTable.print(report)
                try options.write(report, bench: "lift", rescoring: false)
            }
        }
    }
}

extension BenchCommand {
    struct Stitched: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "stitched", abstract: "S1–S3: the module's stitched signature fires on what a Thread trained on but did not index, and not on unseen, unrelated or indexed text.")
        @OptionGroup var options: Options
        @Option(name: .customLong("withheld"), help: "The Thread that withholds documents from its index (default: the one in --threads that does).")
        var withheld: String?

        func run() throws {
            guarded {
                if let path = options.rescore {
                    let report = StitchedBench.rescore(try JSONCoding.read(StitchedReport.self, from: options.url(path)))
                    BenchTable.print(report)
                    try options.write(report, bench: "stitched", rescoring: true)
                    return
                }
                let (braid, world) = try options.assemble(commons: true)
                var sizes = StitchedSizes()
                if let perNode = options.perNode { sizes.perNode = perNode }
                sizes.seed = options.seed
                let started = Date()
                let report = try StitchedBench.run(braid: braid, world: world, sizes: sizes, thread: withheld) { note("bench stitched: \($0)") }
                note(String(format: "bench stitched: %d texts in %.0f s", report.texts.count, Date().timeIntervalSince(started)))
                BenchTable.print(report)
                try options.write(report, bench: "stitched", rescoring: false)
            }
        }
    }

    struct Entropy: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "entropy", abstract: "E1–E3: the entropy path's coherent runs against the trace on the trace bench's texts.")
        @OptionGroup var options: Options

        func run() throws {
            guarded {
                if let path = options.rescore {
                    let report = EntropyBench.rescore(try JSONCoding.read(EntropyReport.self, from: options.url(path)))
                    BenchTable.print(report)
                    try options.write(report, bench: "entropy", rescoring: true)
                    return
                }
                let (braid, world) = try options.assemble(commons: true)
                var sizes = BenchTextSizes()
                if let perNode = options.perNode { sizes.perNode = perNode }
                sizes.seed = options.seed
                let started = Date()
                let report = try EntropyBench.run(braid: braid, world: world, sizes: sizes) { note("bench entropy: \($0)") }
                note(String(format: "bench entropy: %d texts in %.0f s", report.texts.count, Date().timeIntervalSince(started)))
                BenchTable.print(report)
                try options.write(report, bench: "entropy", rescoring: false)
            }
        }
    }

    struct Question: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "question", abstract: "Q1–Q5b: questions through the path braid chat uses, against the stored stem, the corpus slice and a paraphrase; retold and copied facts.")
        @OptionGroup var options: Options

        func run() throws {
            guarded {
                if let path = options.rescore {
                    let report = QuestionBench.rescore(try JSONCoding.read(QuestionReport.self, from: options.url(path)))
                    BenchTable.print(report)
                    try options.write(report, bench: "question", rescoring: true)
                    return
                }
                let (braid, world) = try options.assemble(commons: true)
                let copies = try options.copyBraid(of: braid)
                var sizes = QuestionBench.Sizes()
                if let perNode = options.perNode { sizes.perNode = perNode }
                let started = Date()
                let report = try QuestionBench.run(braid: braid, world: world, sizes: sizes, copies: copies) { note("bench question: \($0)") }
                note(String(format: "bench question: %d rows in %.0f s", report.rows.count, Date().timeIntervalSince(started)))
                BenchTable.print(report)
                try options.write(report, bench: "question", rescoring: false)
            }
        }
    }

    struct Replacement: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "replacement", abstract: "R1–R3, the owner's replacement criterion: sessions A (κ 0, shadow β4 logged) against B (κ > 0) from saved trace and gaming reports and B's verify reports. Reads only; deletes nothing.")
        @OptionGroup var workArea: WorkAreaOptions
        @Option(name: .customLong("trace-a")) var traceA: String
        @Option(name: .customLong("trace-b")) var traceB: String
        @Option(name: .customLong("gaming-a")) var gamingA: String
        @Option(name: .customLong("gaming-b")) var gamingB: String
        @Option(help: "Where to write the report (default: <work area>/bench/replacement/<stamp>.json).")
        var report: String?

        func run() throws {
            guarded {
                func url(_ path: String) -> URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
                let made = ReplacementBench.run(
                    traceA: try JSONCoding.read(TraceReport.self, from: url(traceA)), traceB: try JSONCoding.read(TraceReport.self, from: url(traceB)),
                    gamingA: try JSONCoding.read(GamingReport.self, from: url(gamingA)), gamingB: try JSONCoding.read(GamingReport.self, from: url(gamingB)),
                    inputs: ["trace A": url(traceA).path, "trace B": url(traceB).path, "gaming A": url(gamingA).path, "gaming B": url(gamingB).path])
                BenchTable.print(made)
                let out = try report.map(url) ?? BenchFormat.reportURL(area: workArea.resolve(), bench: "replacement")
                try JSONCoding.write(made, to: out)
                print("report → \(out.path)")
            }
        }
    }
}

/// The rules table every bench prints: id, verdict, the numbers; then what is reported without a threshold.
enum BenchTable {
    static func header(_ bench: String, dataset: String, threads: [String: String], createdAt: Date) {
        let formatter = ISO8601DateFormatter()
        Swift.print("bench \(bench) · \(dataset) · \(formatter.string(from: createdAt))")
        for (name, record) in threads.sorted(by: { $0.key < $1.key }) { Swift.print("  \(name.padding(toLength: 12, withPad: " ", startingAt: 0)) \(record)") }
    }

    static func rules(_ rules: [BenchRule]) {
        let width = max(40, rules.map(\.id.count).max() ?? 0)
        for rule in rules { Swift.print("  \(rule.id.padding(toLength: width, withPad: " ", startingAt: 0)) \(rule.verdict)  \(rule.detail)") }
    }

    static func reported(_ values: [String: Float]) {
        guard !values.isEmpty else { return }
        Swift.print("  reported (no threshold):")
        for (key, value) in values.sorted(by: { $0.key < $1.key }) {
            // Small differences (R1's is a few parts in 10⁵) would print as 0.000.
            Swift.print("    \(key): \(value != 0 && abs(value) < 0.001 ? String(format: "%.2e", value) : String(format: "%.3f", value))")
        }
    }

    static func print(_ report: TraceReport) {
        header("trace", dataset: report.dataset, threads: report.threads, createdAt: report.createdAt)
        var census: [String] = []
        for kind in BenchTextKind.allCases { census.append("\(kind.rawValue) \(report.texts.filter { $0.kind == kind }.count)") }
        Swift.print("  texts: \(census.joined(separator: " · ")) · values from token \(report.from)")
        Swift.print("  κ \(report.gate.map { "\($0.moduleGain)" } ?? "?") (the module's weight in the gate)")
        rules(report.rules)
        Swift.print("  arms (share of answer tokens, no threshold):")
        for arm in report.arms {
            Swift.print("    \(arm.set.padding(toLength: 22, withPad: " ", startingAt: 0)) live gate \(BenchFormat.num(arm.live))  shadow β4 \(BenchFormat.num(arm.shadow))  (\(arm.texts) texts, \(arm.answerTokens) tokens)")
        }
        reported(report.reported)
        sessions(report.sessions)
        Swift.print("  \(report.summary)")
    }

    static func print(_ report: GamingReport) {
        header("gaming", dataset: report.dataset, threads: report.threads, createdAt: report.createdAt)
        var census: [String] = []
        for set in GamingSet.allCases { census.append("\(set.rawValue) \(report.rows.filter { $0.set == set }.count)") }
        Swift.print("  prompts: \(census.joined(separator: " · ")) · \(GamingBench.generated) tokens generated · κ \(report.gate.moduleGain)\(report.copyPair.map { " · copies " + $0.joined(separator: " = ") } ?? "")")
        rules(report.rules)
        reported(report.reported)
        for note in report.notes ?? [] { Swift.print("  note: \(note)") }
        sessions(report.sessions)
        Swift.print("  \(report.summary)")
    }

    static func sessions(_ paths: [String]?) {
        for path in paths ?? [] { Swift.print("  session: \(path)") }
    }

    static func print(_ report: StitchedReport) {
        header("stitched", dataset: report.dataset, threads: report.threads, createdAt: report.createdAt)
        var census: [String] = []
        for set in StitchedSet.allCases { census.append("\(set.rawValue) \(report.texts.filter { $0.set == set }.count)") }
        Swift.print("  \(report.withheldThread) withholds \(report.withheld.count) documents · texts: \(census.joined(separator: " · ")) · values from token \(report.from)")
        rules(report.rules)
        reported(report.reported)
        sessions(report.sessions)
        Swift.print("  \(report.summary)")
    }

    static func print(_ report: EntropyReport) {
        header("entropy", dataset: report.dataset, threads: report.threads, createdAt: report.createdAt)
        var census: [String] = []
        for kind in BenchTextKind.allCases { census.append("\(kind.rawValue) \(report.texts.filter { $0.kind == kind }.count)") }
        Swift.print("  texts: \(census.joined(separator: " · ")) · coherent: H_knn ≤ \(String(format: "%.3f", report.module.coherent)) for \(report.module.coherentRun) positions · in trace: chain ≥ \(report.phrase)")
        rules(report.rules)
        reported(report.reported)
        sessions(report.sessions)
        Swift.print("  \(report.summary)")
    }

    static func print(_ report: QuestionReport) {
        header("question", dataset: report.dataset, threads: report.threads, createdAt: report.createdAt)
        var census: [String] = []
        for set in QuestionSet.allCases { census.append("\(set.rawValue) \(report.rows.filter { $0.set == set }.count)") }
        Swift.print("  rows (sets × arms): \(census.joined(separator: " · "))\(report.copyPair.map { " · copies " + $0.joined(separator: " = ") } ?? "")")
        rules(report.rules)
        reported(report.reported)
        sessions(report.sessions)
        Swift.print("  \(report.summary)")
    }

    static func print(_ report: ReplacementReport) {
        Swift.print("bench replacement · κ A \(report.moduleGainA.map { "\($0)" } ?? "?") · κ B \(report.moduleGainB.map { "\($0)" } ?? "?")")
        for (name, path) in report.inputs.sorted(by: { $0.key < $1.key }) { Swift.print("  \(name): \(path)") }
        for session in report.sessions {
            let issues = session.issues.isEmpty ? "no issues" : session.issues.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            Swift.print("  verify \(URL(fileURLWithPath: session.session).lastPathComponent): \(session.verified ? (session.status ?? "?") + ", " + issues : "no verify report")")
        }
        rules(report.rules)
        reported(report.reported)
        Swift.print("  \(report.summary)")
    }

    static func print(_ report: LiftReport) {
        header("lift", dataset: report.dataset, threads: report.threads, createdAt: report.createdAt)
        var census: [String] = []
        for set in LiftSet.allCases { census.append("\(set.rawValue) \(report.rows.filter { $0.set == set }.count)") }
        Swift.print("  prompts and texts: \(census.joined(separator: " · "))")
        rules(report.rules)
        reported(report.reported)
        sessions(report.sessions)
        Swift.print("  \(report.summary)")
    }
}
