//
//  SweepKey.swift
//  BraidCLI
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: `braid bench sweep-key --thread <name>`: one Thread re-indexed under each key scheme; the
//        document-identity probe and fact retrieval per scheme; a winner by the fixed rule and whether
//        the +0.02 rule would ship it. Nothing changes a default.
//

import ArgumentParser
import BraidKit
import Foundation

struct SweepKeyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "sweep-key", abstract: "Re-index one Thread under each key scheme; probe document identity and fact retrieval per scheme.")
    @OptionGroup var workArea: WorkAreaOptions
    @Option(help: "The Thread to re-index (its trained blocks and snapshot).") var thread: String
    @Option(help: "Comma-separated schemes (residual:N, pooled-state:L, state-delta:L).") var arms: String?
    @Option(help: "Entries sampled for the document-identity probe.") var sample: Int = 2000
    @Option(help: "Facts measured per arm (0 = all).") var facts: Int = 0
    @Option(help: "Report path (default: bench/sweep-key/<stamp>.json in the work area).") var report: String?
    @Option(help: "Random seed.") var seed: UInt64 = 42

    func run() throws {
        guarded {
            let area = try workArea.resolve()
            let config = try workArea.config(in: area)
            guard let packRecord = config.pack, let pack = try Packs.find(packRecord.sha256, in: area) else { throw BraidFailure.missing("braid.toml names no pack that is on disk") }
            let tokenizer = try BraidTokenizer(folder: pack.tokenizerFolder)
            let scheme = KeyScheme(parsing: packRecord.keyScheme) ?? .residual(afterBlocks: pack.config.tapAfterBlocks)
            let commons = try ThreadStore.commons(pack: pack, scheme: scheme)
            let loaded = try ThreadStore.load(thread, in: area, pack: pack, commons: commons, tau: Float(config.index.tau))
            let snapshot = try CorpusSnapshot.load(from: area.thread(thread).snapshot(hash: loaded.version.snapshotHash))
            var options = KeySweepOptions()
            if let arms {
                options.arms = try arms.split(separator: ",").map { text in
                    guard let scheme = KeyScheme(parsing: String(text).trimmingCharacters(in: .whitespaces)) else { throw BraidFailure.usage("unknown key scheme \(text)") }
                    return scheme
                }
            }
            options.sample = sample
            options.factLimit = facts
            options.seed = seed
            if let current = KeyScheme(parsing: packRecord.keyScheme) { options.defaultScheme = current }
            // Facts come from the Thread's dataset node when it has one.
            var factList: [Fact] = []
            if case .dataset(let name, let node) = try CorpusSourceSpec(parsing: loaded.info.source) {
                let root = DatasetsRoot.resolve(workArea: area.root)
                let dataset = try BraidDataset.load(try DatasetsRoot.locate(name, root: root))
                factList = try dataset.corpus(node: node).facts
                note("facts: \(factList.count) from dataset:\(name)#\(node)")
            } else {
                note("facts: none (the Thread's source is not a dataset node); fact arms are skipped")
            }
            let stamp = SessionLog.stamp()
            let directory = area.bench.appendingPathComponent("sweep-key", isDirectory: true).appendingPathComponent(stamp, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let result = try KeySweep.run(thread: loaded, pack: pack, tokenizer: tokenizer, snapshot: snapshot, facts: factList, options: options, into: directory) { note($0) }
            let reportURL = report.map { URL(fileURLWithPath: $0) } ?? area.bench.appendingPathComponent("sweep-key", isDirectory: true).appendingPathComponent("\(stamp).json")
            try JSONCoding.write(result, to: reportURL)
            print("sweep-key: \(result.thread) (\(result.source)), \(result.documents) documents, \(result.factsLocated) facts located (\(result.factsUnaligned) unaligned)")
            func pad(_ text: String, _ width: Int, left: Bool = false) -> String {
                let fill = String(repeating: " ", count: max(0, width - text.count))
                return left ? text + fill : fill + text
            }
            func f(_ v: Float?) -> String { pad(v.map { String(format: "%.3f", $0) } ?? "–", 6) }
            print([pad("scheme", 16, left: true), pad("dims", 5), pad("entr.", 6), pad("build s", 7), " ", pad("doc", 6), pad("part", 6), "  ", pad("p@1", 6), pad("off@1", 6), pad("ans@1", 6), pad("mass", 6), "  ", pad("stem@1", 6), pad("s.ans", 6), "  ", pad("para@1", 6), pad("p.ans", 6)].joined(separator: " "))
            for arm in result.arms {
                print([pad(arm.scheme, 16, left: true), pad("\(arm.keyDims)", 5), pad("\(arm.entries)", 6), pad(String(format: "%.1f", arm.buildSeconds), 7), " ",
                       f(arm.probe.sameDocument), f(arm.probe.samePartition), "  ", f(arm.prompt?.partitionAt1), f(arm.prompt?.offsetAt1), f(arm.prompt?.answerAt1), f(arm.prompt?.meanAnswerMass), "  ",
                       f(arm.stem?.partitionAt1), f(arm.stem?.answerAt1), "  ", f(arm.paraphrase?.partitionAt1), f(arm.paraphrase?.answerAt1)].joined(separator: " "))
            }
            print("default \(result.defaultScheme); winner \(result.winner ?? "none"); ships: \(result.ships ? "yes (+0.02 rule met; the owner decides)" : "no")")
            for line in result.notes { print("note: \(line)") }
            note("report → \(reportURL.path)")
        }
    }
}
