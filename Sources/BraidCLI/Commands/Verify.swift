//
//  Verify.swift
//  BraidCLI
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: `braid verify <session.jsonl>`: replays the log — body hashes, share arithmetic, the gate's
//        memory recursion, the shadow gate, the trace over each Thread's index layout, every verbatim
//        span re-read from the Thread's snapshot (or the live lane with --live) — and, with --keys,
//        recomputes every cited key from the nearest state checkpoint. Writes <id>.verify.json beside
//        the log. Exit 0; 3 when a span no longer matches; 65 when the log's arithmetic fails.
//        A log imported from RaoLM (`braid import-raolm`) needs no work area: its traces replay over
//        the RaoLM indexes its import.json names, and the report says which checks it does not take
//        (the memory recursion, the shadow β4, the spans).
//

import ArgumentParser
import BraidKit
import Foundation
import MLX

struct VerifyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "verify", abstract: "Replay a session log: hashes, arithmetic, traces, spans; --keys recomputes cited keys.")

    @OptionGroup var workArea: WorkAreaOptions
    @Argument(help: "The session log (sessions/<stamp>-<id>.jsonl).")
    var session: String
    @Flag(help: "Recompute every cited hit's key from the nearest state checkpoint (loads the trunk).")
    var keys = false
    @Flag(name: .customLong("all-hits"), help: "With --keys: recompute every logged hit's key, not only the cited ones.")
    var allHits = false
    @Flag(help: "Re-read every span from the AII lane that holds its document, as it stands now (other documents from the snapshot).")
    var live = false
    @Flag(name: .customLong("no-write"), help: "Do not write <id>.verify.json beside the log.")
    var noWrite = false

    func run() throws {
        guarded {
            let url = URL(fileURLWithPath: (self.session as NSString).expandingTildeInPath)
            let logged = try SessionReader.read(url)
            let report = logged.header.source == RaoLMImport.source ? try imported(logged, url: url) : try braided(logged, url: url)
            if !noWrite {
                let out = url.deletingPathExtension().appendingPathExtension("verify.json")
                try JSONCoding.write(report, to: out)
                note("verify: report → \(out.path)")
            }
            print("session \(report.session): \(report.generations) generation(s)")
            print("  arithmetic issues: \(report.issues.filter { $0.check != "trace" && $0.check != "keys" }.count)")
            for check in report.traces {
                print("  trace strand \(check.strand): \(check.positions) positions, \(check.mismatches) mismatches" + (check.unreplayable > 0 ? ", \(check.unreplayable) unreplayable" : ""))
            }
            if report.skipped.contains("spans") {
                print("  spans: not checked")
            } else {
                print("  spans: \(report.spansVerified) verified, \(report.spansFailed) failed")
            }
            if !report.skipped.isEmpty { print("  skipped: \(report.skipped.joined(separator: ", "))") }
            for span in report.spans where span.status != .verified { print("    ✗ \(span.status.rawValue) \(span.text.debugDescription) → \(span.documentID.suffix(16)) p\(span.partitionIndex)@\(span.tokenOffset) \(span.detail ?? "")") }
            for issue in report.issues.prefix(10) { print("  ✗ \(issue)") }
            for noteLine in report.notes { print("  · \(noteLine)") }
            print(report.status == .ok ? "verified" : "FAILED")
            if report.status != .ok {
                throw BraidFailure(report.spansFailed > 0 ? "a span no longer matches its source" : "the log does not replay", code: report.spansFailed > 0 ? .verifyMismatch : .data)
            }
        }
    }

    /// A log imported from RaoLM: no work area or pack (the tokenizer and the partitions are RaoLM's);
    /// the traces replay over the RaoLM indexes the import.json beside the log names.
    func imported(_ logged: LoggedSession, url: URL) throws -> VerifyReport {
        if keys || live { throw BraidFailure.usage("--keys and --live do not apply to a log imported from RaoLM", hint: "its keys are RaoLM's and its partitions live in no AII lane") }
        var layouts: [String: IndexLayout] = [:]
        var notes: [String] = []
        if let (record, location) = RaoLMPort.ImportReport.find(near: url) {
            layouts = try RaoLMPort.layouts(for: logged, report: record)
            notes.append("raolm: index layouts found by sha under \(record.dataRoot) (from \(location.path))")
        } else {
            notes.append("raolm: no import.json beside the log, so RaoLM's index layouts were not found and the trace is not replayed")
        }
        var report = Verifier.verify(session: logged, name: url.lastPathComponent, layouts: { layouts[$0] }, reader: nil, tokenizer: nil)
        report.notes += notes
        if layouts.isEmpty { report.skipped.append("trace") }
        return report
    }

    /// A Braid log: the Threads in the work area, their snapshots (or live lanes) and the pack.
    func braided(_ logged: LoggedSession, url: URL) throws -> VerifyReport {
        let area = try workArea.resolve()
        let config = try workArea.config(in: area)
        guard let packRecord = config.pack, let pack = try Packs.find(packRecord.sha256, in: area) else { throw BraidFailure.missing("braid.toml names no pack that is on disk") }
        let tokenizer = try BraidTokenizer(folder: pack.tokenizerFolder)
        // Every Thread the session names: its live index layout and its snapshot.
        var layouts: [String: IndexLayout] = [:]
        var snapshots: [CorpusSnapshot] = []
        var loaded: [String: LoadedThread] = [:]
        let names = Set(logged.header.threads.filter { !$0.commons }.map(\.name) + logged.membership.filter { $0.kind == "attach" }.map(\.thread.name))
        let scheme = KeyScheme(parsing: packRecord.keyScheme) ?? .residual(afterBlocks: pack.config.tapAfterBlocks)
        var commons: LocalNode? = nil                                                       // the trunk the Threads run behind, built once a Thread needs it
        for name in names {
            guard FileManager.default.fileExists(atPath: area.thread(name).record.path) else { note("verify: thread \(name) is not in the work area; its spans and traces are skipped"); continue }
            if commons == nil { commons = try ThreadStore.commons(pack: pack, scheme: scheme) }
            let thread = try ThreadStore.load(name, in: area, pack: pack, commons: commons!)
            loaded[name] = thread
            layouts[name] = thread.node.index?.layout
            snapshots.append(try CorpusSnapshot.load(from: area.thread(name).snapshot(hash: thread.version.snapshotHash)))
        }
        let snapshotReader = SnapshotPartitionReader(snapshots: snapshots)
        let liveReader = live ? LivePartitionReader(lanes: LivePartitionReader.lanes(for: logged), demoRoot: AIIDetect.demoRoot(), fallback: snapshotReader) : nil
        var report = Verifier.verify(session: logged, name: url.lastPathComponent, layouts: { layouts[$0] }, reader: liveReader ?? snapshotReader, tokenizer: tokenizer)
        if let liveReader {
            report.notes.append(liveReader.used.isEmpty ? "live: no span's document is held in an AII lane; spans were read from the snapshots"
                                                        : "live: spans re-read from \(liveReader.used.map(\.description).sorted().joined(separator: ", "))")
        }
        if keys {
            var worst: Float = 0
            var checked = 0
            for generation in logged.generations {
                let strands = SessionReplay.strands(for: generation, session: logged)
                for step in generation.steps where step.source == .gen {
                    guard let records = step.threads else { continue }
                    for (t, record) in records.enumerated() where t < strands.count && !strands[t].commons {
                        guard let thread = loaded[strands[t].name], let index = thread.node.index else { continue }
                        let snapshot = try CorpusSnapshot.load(from: area.thread(strands[t].name).snapshot(hash: thread.version.snapshotHash))
                        let corpus = TokenizedCorpus(snapshot: snapshot, tokenizer: tokenizer, paragraphBreak: tokenizer.paragraphBreak, threadID: thread.info.threadID)
                        for (rank, hit) in record.hits.enumerated() where allHits || (hit.value == step.token && rank < 3) {
                            let entry = Int(hit.entry)
                            let target = TokenPosition(row: Int(index.keyRow[entry]), offset: Int(index.keyOffset[entry]))
                            let (replayed, _) = try Replay.key(at: target, index: index, corpus: corpus, trunk: thread.node.trunk, pack: pack)
                            let cosine = (replayed * index.key(entry: entry)).sum()
                            eval(cosine)
                            worst = max(worst, 1 - cosine.item(Float.self))
                            checked += 1
                        }
                    }
                }
            }
            report.notes.append(String(format: "keys: %d cited hits recomputed, worst 1 − cos %.2e", checked, worst))
            if worst > 1e-3 {
                report.issues.append(ReplayIssue(generationID: "-", step: nil, strand: nil, check: "keys", detail: String(format: "worst 1 − cos %.2e exceeds 1e-3", worst)))
                report.status = .failed
            }
        }
        return report
    }
}
