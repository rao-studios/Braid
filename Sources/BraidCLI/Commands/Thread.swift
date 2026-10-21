//
//  Thread.swift
//  BraidCLI
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: `braid thread create <name> --corpus <source>`: a Thread from a corpus source — snapshot,
//        training and the provenance index on the pack's trunk — made live and attached to the
//        braid in braid.toml. The flags become a ThreadRecipe that BraidKit's BraidEngine builds
//        (the studio's new-Thread dialog runs the same path); `sync` and `index` are the engine's
//        other two intents. `thread list` and `thread show` read the records.
//

import ArgumentParser
import BraidKit
import Foundation

struct ThreadCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "thread", abstract: "Threads: create one from a corpus, list them, show one.",
                                                    subcommands: [Create.self, Sync.self, Index.self, List.self, Show.self], defaultSubcommand: List.self)

    struct Create: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "create", abstract: "Snapshot a corpus, train and index a head for it behind the commons' trunk, make it live, attach it.")
        @OptionGroup var workArea: WorkAreaOptions
        @Argument(help: "The Thread's name (a lowercase handle).")
        var name: String
        @Option(help: "dataset:<name or path>#<node> · dir:<path> · aii:<aii>/<lane> · app:<aii>/<app>")
        var corpus: String
        @Option(help: "Only the first N documents of a dataset node (feeding order).")
        var limit: Int?
        @Option(help: "A display label (default: the name, capitalised).")
        var label: String?
        @Option(help: "The key scheme: residual:<n>, pooled-state:<layer>, state-delta:<layer> (default: braid.toml's).")
        var scheme: String?
        @Flag(name: .customLong("no-attach"), help: "Do not add the Thread to [cluster] attach in braid.toml.")
        var noAttach = false
        @Flag(name: .customLong("no-train"), help: "Index on the pack's own blocks 0..<cut, behind the commons' trunk, without training a head of the Thread's own.")
        var noTrain = false
        @Option(help: "Optimizer steps planned (default 1000 from the pack's blocks).")
        var steps: Int?
        @Option(name: .customLong("batch")) var batchSize: Int?
        @Option(name: .customLong("seq-len")) var seqLen: Int?
        @Option(help: "Train on every document but leave this fraction out of the index (the stitched bench's withheld set, e.g. 0.2).")
        var withhold: Double?
        @Option(help: "The training seed, which also draws the withheld documents (default 42).")
        var seed: UInt64?

        func run() throws {
            guarded {
                let area = try workArea.resolve()
                let config = try workArea.config(in: area)
                guard let packRecord = config.pack, let pack = try Packs.find(packRecord.sha256, in: area) else { throw BraidFailure.missing("braid.toml names no pack that is on disk") }
                var recipe = try ThreadRecipe(name, corpus: corpus)
                recipe.settings.limit = limit
                recipe.settings.label = label
                recipe.settings.key = try scheme.map(KeyScheme.parsed)
                recipe.settings.training = noTrain ? .off : .on(steps: steps, batchSize: batchSize, seqLen: seqLen)
                recipe.settings.withhold = withhold
                recipe.settings.seed = seed
                recipe.settings.attach = !noAttach
                let engine = BraidEngine(area: area, config: config, pack: pack) { if let line = $0.line { note(line) } }
                print(try engine.create(recipe).summary)
            }
        }
    }

    struct Sync: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "sync", abstract: "Read the Thread's source again; when its corpus changed, train on from the live blocks and index a new live version.")
        @OptionGroup var workArea: WorkAreaOptions
        @Argument var name: String
        @Flag(name: .customLong("no-train"), help: "Index the changed corpus with the live blocks, without training.") var noTrain = false
        @Option(help: "Optimizer steps planned when training on (default 500).") var steps: Int?

        func run() throws {
            guarded {
                let area = try workArea.resolve()
                let config = try workArea.config(in: area)
                guard let packRecord = config.pack, let pack = try Packs.find(packRecord.sha256, in: area) else { throw BraidFailure.missing("braid.toml names no pack that is on disk") }
                let engine = BraidEngine(area: area, config: config, pack: pack) { if let line = $0.line { note(line) } }
                let synced = try engine.sync(name, training: noTrain ? .off : .on(steps: steps))
                if let outcome = synced.outcome { print(outcome.summary + "  (" + synced.diff.summary + ")") } else { print("\(name)  up to date") }
            }
        }
    }

    struct Index: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "index", abstract: "Key the live version again under another key scheme or checkpoint policy, as a new live version.")
        @OptionGroup var workArea: WorkAreaOptions
        @Argument var name: String
        @Option(help: "The key scheme: residual:<n>, pooled-state:<layer>, state-delta:<layer> (default: the live version's).") var scheme: String?
        @Flag(name: .customLong("checkpoint-every-partition"), help: "Write a state checkpoint at every partition boundary (for transfer), not only every 1,024 tokens.") var everyPartition = false

        func run() throws {
            guarded {
                let area = try workArea.resolve()
                let config = try workArea.config(in: area)
                guard let packRecord = config.pack, let pack = try Packs.find(packRecord.sha256, in: area) else { throw BraidFailure.missing("braid.toml names no pack that is on disk") }
                let engine = BraidEngine(area: area, config: config, pack: pack) { if let line = $0.line { note(line) } }
                let outcome = try engine.rekey(name, key: try scheme.map(KeyScheme.parsed), checkpoints: everyPartition ? .atEveryPartition : CheckpointPolicy())
                print(outcome.summary)
            }
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "Every Thread with its live version.")
        @OptionGroup var workArea: WorkAreaOptions
        func run() throws {
            guarded {
                let area = try workArea.resolve()
                let threads = try ThreadStore.list(in: area)
                if threads.isEmpty { print("no threads in \(area.threads.path); run braid thread create"); return }
                for info in threads {
                    let live = try ThreadStore.live(area.thread(info.name))
                    let version = live.map { "v\($0.version) \($0.trained ? "trained" : "base") \($0.keyScheme) index \($0.indexSHA256.prefix(12)) memorised \(String(format: "%.0f%%", $0.memorised * 100))" } ?? "no live version"
                    print("\(info.name.padding(toLength: 14, withPad: " ", startingAt: 0)) \(info.source.padding(toLength: 34, withPad: " ", startingAt: 0)) \(version)")
                }
            }
        }
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "show", abstract: "One Thread's record and live version.")
        @OptionGroup var workArea: WorkAreaOptions
        @Argument var name: String
        func run() throws {
            guarded {
                let area = try workArea.resolve()
                let layout = area.thread(name)
                let info = try ThreadStore.info(layout)
                print(String(decoding: try JSONCoding.prettyEncoder().encode(info), as: UTF8.self))
                if let live = try ThreadStore.live(layout) { print(String(decoding: try JSONCoding.prettyEncoder().encode(live), as: UTF8.self)) }
            }
        }
    }
}
