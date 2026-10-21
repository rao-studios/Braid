//
//  RaoLMPort.swift
//  BraidCore
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The port validation's runner over a RaoLM trajectory-bench dump: its sets (the base pass
//        and each gate arm whose files are complete), the RaoLM node indexes its records name, and
//        one pass over every record that either writes it as a Braid session log (`import`) or
//        checks it (`check`: the shares, the mapping onto each node's index, the trace replay, and
//        `braid verify`'s arithmetic and trace replay on the imported session, keeping what phase A
//        reads of each record).
//  OUT:  Under the output directory: `base/<record>.jsonl`, `arms/<slug>/<record>.jsonl` and
//        `import.json` (what was imported from where, the field notes, which verify checks apply);
//        or the check's report.
//  PIN:  Pure Swift and Foundation: no model, no GPU. Records are decoded `jobs` at a time and
//        dropped once read; nothing is written outside the output directory.
//

import Foundation

public enum RaoLMPort {
    public enum Failure: Error, CustomStringConvertible {
        case noSet(String, known: [String])
        case noRecords(String)
        case mixedIndexes(String)

        public var description: String {
            switch self {
            case .noSet(let name, let known): return "the dump has no set \(name) (known: \(known.joined(separator: ", ")))"
            case .noRecords(let detail): return "no records: \(detail)"
            case .mixedIndexes(let detail): return "the records do not name one index per node: \(detail)"
            }
        }
    }

    /// One set of records: the base pass or one gate arm.
    public struct RecordSet: Sendable, Equatable {
        /// "base", or the arm's name as RaoLM wrote it ("both β4").
        public var name: String
        /// Relative to the dump ("" for the base pass, "arms/both-beta4").
        public var directory: String
        /// The texts it should hold.
        public var texts: [RaoLMDumpText]
        /// Expected files not there (or empty): a set is used only when none is missing.
        public var missing: [String]

        public var complete: Bool { missing.isEmpty }
        /// Where its logs go under the output directory.
        public var outputDirectory: String { directory.isEmpty ? "base" : directory }
    }

    /// The base pass and every arm, with what each is missing. An arm holds RaoLM's told and source
    /// texts with answers (the texts its arm loop scored).
    public static func sets(dump: URL, index: RaoLMDumpIndex) -> [RecordSet] {
        let manager = FileManager.default
        func missing(_ directory: String, _ texts: [RaoLMDumpText]) -> [String] {
            texts.compactMap { text in
                let url = dump.appendingPathComponent(directory, isDirectory: true).appendingPathComponent(text.file)
                let size = (try? manager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
                return size > 0 ? nil : text.file
            }
        }
        var sets = [RecordSet(name: "base", directory: "", texts: index.texts, missing: missing("", index.texts))]
        let retold = index.texts.filter { ($0.kind == "told" || $0.kind == "source") && !$0.answers.isEmpty }
        for (name, directory) in index.arms.sorted(by: { $0.key < $1.key }) {
            sets.append(RecordSet(name: name, directory: directory, texts: retold, missing: missing(directory, retold)))
        }
        return sets
    }

    /// The sets `only` names ("base", an arm's name, or its directory's last component), or every
    /// complete set when nil.
    public static func select(_ sets: [RecordSet], only: String?) throws -> [RecordSet] {
        guard let only else { return sets.filter(\.complete) }
        let wanted = sets.filter { $0.name == only || $0.directory == only || ($0.directory as NSString).lastPathComponent == only }
        guard let set = wanted.first else { throw Failure.noSet(only, known: sets.map(\.name)) }
        return [set]
    }

    // MARK: - The nodes

    /// One RaoLM node index the records name, as the import report and `braid verify` find it.
    public struct NodeIndex: Codable, Sendable, Equatable {
        public var name: String
        public var label: String
        public var version: Int
        public var epoch: Int
        public var directory: String
        public var sha256: String
        public var entries: Int
        public var entryOffset: Int
        public var rowOffset: Int
        public var rowCount: Int
        /// RaoLM's own record of the version, with no Braid field (Braid's checkpointSHA256 names an
        /// index's state checkpoints, not a Thread's weights).
        public var runID: String
        public var checkpointSHA256: String
        public var ledgerSHA256: String?
        public var address: String?
        public var ownerKey: String?
    }

    /// The RaoLM indexes of a record's Thread strands under `dataRoot`, each checked against its sha.
    public static func indexes(of braid: RaoLMBraid, dataRoot: URL) throws -> [String: RaoLMIndex] {
        var result: [String: RaoLMIndex] = [:]
        for strand in braid.strands where !strand.isCommons { result[strand.name] = try RaoLMIndex.load(strand: strand, dataRoot: dataRoot) }
        return result
    }

    public static func nodeRecords(_ braid: RaoLMBraid, indexes: [String: RaoLMIndex]) -> [NodeIndex] {
        braid.strands.filter { !$0.isCommons }.compactMap { strand in
            guard let index = indexes[strand.name] else { return nil }
            return NodeIndex(name: strand.name, label: strand.label, version: strand.version, epoch: strand.manifest.epoch, directory: index.directory.path,
                             sha256: index.sha256, entries: index.count, entryOffset: strand.entryOffset, rowOffset: strand.rowOffset, rowCount: strand.rowCount,
                             runID: strand.manifest.runID, checkpointSHA256: strand.manifest.checkpointSHA256, ledgerSHA256: strand.manifest.ledgerSHA256,
                             address: strand.address, ownerKey: strand.ownerKey)
        }
    }

    // MARK: - One pass

    /// What one record gave the check.
    public struct Outcome: Sendable {
        public var set: String
        public var text: RaoLMDumpText
        public var steps = 0
        public var missingHits = 0
        public var shares = RaoLMCheck.Shares()
        public var mapping = RaoLMCheck.Mapping()
        public var traces = RaoLMCheck.Traces()
        public var verify = VerifyTally()
        public var scored: RaoLMCheck.ScoredText?
        public var gate: RaoLMGate?
        public var indexSHA256: [String: String] = [:]
        public var error: String?
    }

    /// `braid verify` on the imported sessions, spans aside (RaoLM's partitions are in no Braid snapshot).
    public struct VerifyTally: Codable, Sendable, Equatable {
        public var logs = 0
        public var issues = 0
        public var traceMismatches = 0
        public var traceUnreplayable = 0
        public var firstIssues: [String] = []
        public var skipped: [String] = []

        public init() {}

        public mutating func add(_ other: VerifyTally) {
            logs += other.logs
            issues += other.issues
            traceMismatches += other.traceMismatches
            traceUnreplayable += other.traceUnreplayable
            firstIssues += other.firstIssues.prefix(max(0, 20 - firstIssues.count))
            for skip in other.skipped where !skipped.contains(skip) { skipped.append(skip) }
        }
    }

    public enum Mode: Sendable {
        /// Write every record as a session log under the directory.
        case write(URL)
        /// Check every record.
        case check
    }

    /// Runs `body` over 0..<count with at most `jobs` at a time, results in order.
    static func parallel<T: Sendable>(_ count: Int, jobs: Int, _ body: @escaping @Sendable (Int) -> T) -> [T] {
        let box = ParallelResults<T>(count)
        DispatchQueue.concurrentPerform(iterations: max(1, min(jobs, count))) { _ in
            while true {
                box.lock.lock()
                let i = box.next
                box.next += 1
                box.lock.unlock()
                guard i < count else { return }
                let value = body(i)
                box.lock.lock()
                box.results[i] = value
                box.lock.unlock()
            }
        }
        return box.results.map { $0! }
    }

    /// One pass over a set: each record decoded, imported, and written or checked.
    public static func run(set: RecordSet, dump: URL, indexes: [String: RaoLMIndex], dataRoot: URL, mode: Mode, rule: TraceRule = .standard,
                           jobs: Int = 4, progress: (@Sendable (String) -> Void)? = nil) -> [Outcome] {
        let layouts = indexes.mapValues(\.layout)
        let corpora = layouts.mapValues(\.corpus)
        let documents = indexes.mapValues(\.documentOfRow)
        let counts = indexes.mapValues(\.count)
        let texts = set.texts
        let base = dump.appendingPathComponent(set.directory, isDirectory: true)
        return parallel(texts.count, jobs: jobs) { i -> Outcome in
            let text = texts[i]
            var outcome = Outcome(set: set.name, text: text)
            do {
                let g = try RaoLMGeneration.load(from: base.appendingPathComponent(text.file))
                guard let braid = g.braid else { throw RaoLMImport.Failure.notBraided(g.generationID) }
                outcome.gate = braid.gate
                for strand in braid.strands where !strand.isCommons { outcome.indexSHA256[strand.name] = strand.manifest.indexSHA256 }
                let ranges = RaoLMImport.entryRanges(braid, counts: counts)
                let id = RaoLMImport.sessionID(set: set.outputDirectory, file: text.file, generationID: g.generationID)
                let imported = try RaoLMImport.session(g, sessionID: id, pack: RaoLMImport.pack(g, dataRoot: dataRoot), ranges: ranges, rule: rule)
                outcome.steps = imported.steps.count
                outcome.missingHits = imported.missingHits
                switch mode {
                case .write(let out):
                    let stem = (text.file as NSString).deletingPathExtension
                    try imported.write(to: out.appendingPathComponent(set.outputDirectory, isDirectory: true).appendingPathComponent(stem + ".jsonl"))
                case .check:
                    outcome.shares = RaoLMCheck.shares(g, file: text.file, ranges: ranges)
                    outcome.mapping = RaoLMCheck.mapping(g, layouts: layouts, ranges: ranges, rule: rule)
                    let replay = RaoLMCheck.replay(g, corpora: corpora, ranges: ranges, rule: rule)
                    outcome.traces = RaoLMCheck.traces(g, replay: replay, set: set.name, file: text.file, rule: rule)
                    outcome.scored = RaoLMCheck.scoredText(g, file: text.file, replay: replay, imported: imported, documentOfRow: documents)
                    let report = Verifier.verify(session: try imported.logged(), name: text.file, layouts: { layouts[$0] }, reader: nil, tokenizer: nil)
                    outcome.verify.logs = 1
                    outcome.verify.issues = report.issues.count
                    outcome.verify.firstIssues = report.issues.prefix(3).map { "\(text.file): \($0)" }
                    outcome.verify.traceMismatches = report.traces.reduce(0) { $0 + $1.mismatches }
                    outcome.verify.traceUnreplayable = report.traces.reduce(0) { $0 + $1.unreplayable }
                    outcome.verify.skipped = report.skipped
                }
            } catch {
                outcome.error = "\(text.file): \(error)"
            }
            if i % 50 == 49 { progress?("\(set.name): \(i + 1)/\(texts.count)") }
            return outcome
        }
    }

    // MARK: - Reports

    /// A set's totals.
    public struct SetReport: Codable, Sendable {
        public var name: String
        public var directory: String
        public var expected: Int
        public var records: Int
        public var steps: Int
        public var missingHits: Int
        public var errors: [String]
        /// RaoLM's gate for the set (its arm's switches), as the first record names it.
        public var gate: RaoLMGate?
        public var shares: RaoLMCheck.Shares
        public var mapping: RaoLMCheck.Mapping
        public var traces: RaoLMCheck.Traces
        public var verify: VerifyTally

        public init(set: RecordSet, outcomes: [Outcome]) {
            name = set.name
            directory = set.outputDirectory
            expected = set.texts.count
            records = outcomes.filter { $0.error == nil }.count
            steps = outcomes.reduce(0) { $0 + $1.steps }
            missingHits = outcomes.reduce(0) { $0 + $1.missingHits }
            errors = outcomes.compactMap(\.error) + set.missing.map { "missing \($0)" }
            gate = outcomes.lazy.compactMap(\.gate).first
            var shares = RaoLMCheck.Shares(), mapping = RaoLMCheck.Mapping(), traces = RaoLMCheck.Traces(), verify = VerifyTally()
            for outcome in outcomes {
                shares.add(outcome.shares)
                mapping.add(outcome.mapping)
                traces.add(outcome.traces)
                verify.add(outcome.verify)
            }
            self.shares = shares
            self.mapping = mapping
            self.traces = traces
            self.verify = verify
        }
    }

    /// Which of `braid verify`'s checks an imported log takes, in words, for the reports.
    public static let verifyChecks: [String: String] = [
        "body": "applies: the importer writes the end line's hash like any log",
        "shares sum to 1": "applies",
        "weights": "applies: w′ from the logged gate (thr.g, RaoLM's gate) and the open set",
        "p and shares": "applies: from w′ and each strand's p_lm, p_knn and λ",
        "H_knn": "applies: from each strand's hits and τ (0 where the record lacks its hits)",
        "trace": "applies over RaoLM's index layout; a mismatch after a position whose hits the record lacks is counted unreplayable, not failed",
        "memory recursion": "skipped: it replays Braid's live gate, and RaoLM's memory was moved by RaoLM's gate code (in Float, under switches Braid has not); `import-raolm --check` measures Braid's Gate.observe against it instead (phase A)",
        "shadow β4": "skipped: RaoLM ran no shadow; the importer derived sg/ss from RaoLM's memory and trace",
        "spans": "skipped: RaoLM's partitions are in no Braid snapshot or lane, and the tokenizer is RaoLM's",
        "keys": "refused: a RaoLM key cannot be recomputed from a Mamba checkpoint",
    ]

    /// `import.json`: what an import wrote, from where, and how to read it.
    public struct ImportReport: Codable, Sendable {
        public var source = RaoLMImport.source
        public var createdAt: Date
        public var dump: String
        public var dataRoot: String
        public var nodes: [NodeIndex]
        public var sets: [SetSummary]
        public var verifyChecks: [String: String]
        public var fieldNotes: [RaoLMImport.FieldNote]

        public struct SetSummary: Codable, Sendable {
            public var name: String
            public var directory: String
            public var records: Int
            public var steps: Int
            public var missingHits: Int
            public var errors: [String]
            public var gate: RaoLMGate?

            public init(_ report: SetReport) {
                name = report.name
                directory = report.directory
                records = report.records
                steps = report.steps
                missingHits = report.missingHits
                errors = report.errors
                gate = report.gate
            }
        }

        public init(createdAt: Date, dump: String, dataRoot: String, nodes: [NodeIndex], sets: [SetSummary]) {
            self.createdAt = createdAt
            self.dump = dump
            self.dataRoot = dataRoot
            self.nodes = nodes
            self.sets = sets
            verifyChecks = RaoLMPort.verifyChecks
            fieldNotes = RaoLMImport.fieldNotes
        }

        public static let fileName = "import.json"

        /// The import report beside a log: in its directory or up to three above it.
        public static func find(near log: URL) -> (ImportReport, URL)? {
            var directory = log.deletingLastPathComponent()
            for _ in 0..<4 {
                let url = directory.appendingPathComponent(fileName)
                if let report = try? JSONCoding.read(ImportReport.self, from: url), report.source == RaoLMImport.source { return (report, url) }
                directory.deleteLastPathComponent()
            }
            return nil
        }
    }

    /// The layouts `braid verify` replays an imported log's traces over: each Thread strand's RaoLM
    /// index, found by its sha under the import's data root (the node records first).
    public static func layouts(for session: LoggedSession, report: ImportReport) throws -> [String: IndexLayout] {
        var layouts: [String: IndexLayout] = [:]
        for thread in session.header.threads where !thread.commons {
            guard let sha = thread.indexSHA256 else { continue }
            if let node = report.nodes.first(where: { $0.sha256 == sha }),
               let index = try? RaoLMIndex.load(directory: URL(fileURLWithPath: node.directory, isDirectory: true), node: thread.name, expectedSHA256: sha) {
                layouts[thread.name] = index.layout
            } else if let index = try RaoLMIndex.find(dataRoot: URL(fileURLWithPath: report.dataRoot, isDirectory: true), node: thread.name, sha256: sha) {
                layouts[thread.name] = index.layout
            }
        }
        return layouts
    }
}

/// The shared cursor and results of `RaoLMPort.parallel`, under one lock.
final class ParallelResults<T: Sendable>: @unchecked Sendable {
    let lock = NSLock()
    var next = 0
    var results: [T?]

    init(_ count: Int) { results = [T?](repeating: nil, count: count) }
}
