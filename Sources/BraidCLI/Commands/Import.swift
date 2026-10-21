//
//  Import.swift
//  BraidCLI
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: `braid import <hf-id | folder>`: a Hugging Face Mamba2 checkpoint becomes a pack under the
//        work area's packs/, hashed at import. `braid init --base <pack | hf-id>` imports when given
//        an id, validates the pack and writes braid.toml with the storage math printed.
//

import ArgumentParser
import BraidKit
import Foundation
import MLX

struct ImportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "import", abstract: "Convert a pretrained Mamba2 checkpoint into a Braid pack.")

    @OptionGroup var workArea: WorkAreaOptions
    @Argument(help: "A Hugging Face repo id (AntonV/mamba2-130m-hf) or a folder holding config.json, safetensors and tokenizer files.")
    var source: String
    @Option(help: "The revision (commit) to fetch; default: the repo's latest, recorded in pack.json.")
    var revision: String?
    @Option(help: "The pack's name (default: the repo's last path component).")
    var name: String?
    @Option(help: "The first block of the commons' trunk, the blocks every Thread runs behind its own (default: half the blocks).")
    var cut: Int?
    @Option(name: .customLong("tap"), help: "The residual tap the default key reads, after this many blocks (default: the cut).")
    var tapAfterBlocks: Int?
    @Flag(help: "Run the trunk once after the import: a greedy sample and the held-out NLL, recorded in pack.json.")
    var check = false

    func run() throws {
        guarded {
            let area = try workArea.resolve()
            try area.prepare()
            let imported = try Importer.run(source: source, revision: revision, name: name, cut: cut, tapAfterBlocks: tapAfterBlocks, check: check, area: area)
            print("pack \(imported.pack.info.name)  \(imported.pack.sha256)")
            print("  \(imported.directory.path)")
            for (label, value) in StorageMath(config: imported.pack.config).table() { print("  \(label.padding(toLength: 30, withPad: " ", startingAt: 0)) \(value)") }
        }
    }
}

enum Importer {
    static func run(source: String, revision: String?, name: String?, cut: Int?, tapAfterBlocks: Int?, check: Bool, area: WorkArea) throws -> PackImporter.Imported {
        let folder: URL
        var origin = source
        if FileManager.default.fileExists(atPath: (source as NSString).expandingTildeInPath + "/config.json") {
            folder = URL(fileURLWithPath: (source as NSString).expandingTildeInPath, isDirectory: true)
            origin = "folder:\(folder.path)"
        } else {
            folder = try PackImporter.fetch(repo: source, revision: revision, modelsHome: area.modelsHome) { note("import: \($0)") }
            origin = "hub:\(source)@\(PackImporter.snapshotCommit(folder) ?? revision ?? "main")"
        }
        let packName = name ?? source.split(separator: "/").last.map(String.init) ?? source
        let imported = try PackImporter.importPack(folder: folder, name: packName, source: origin, cut: cut, tapAfterBlocks: tapAfterBlocks, into: area.packs) { note("import: \($0)") }
        if check {
            note("import: running the trunk once")
            let tokenizer = try BraidTokenizer(folder: imported.pack.tokenizerFolder)
            let trunk = try Trunk(pack: imported.pack)
            let reed = imported.pack.reed(tokens: tokenizer.vocabSize)
            let (sample, nll) = try Sampler.sampleAndNLL(trunk: trunk, reed: reed, tokenizer: tokenizer)
            try PackImporter.record(referenceNLL: nll, sample: sample, in: imported.directory)
            print("  sample: \(sample.replacingOccurrences(of: "\n", with: "⏎"))")
            print(String(format: "  held-out NLL: %.3f nats/token", nll))
        }
        return imported
    }
}

struct InitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "init", abstract: "Validate a pack and write braid.toml in the work area.")

    @OptionGroup var workArea: WorkAreaOptions
    @Option(help: "The pack: its sha256 (or 12-hex prefix), its name, or a Hugging Face repo id to import first (not needed for --measure on an existing braid.toml).")
    var base: String?
    @Flag(help: "Overwrite an existing braid.toml.")
    var force = false
    @Flag(help: "Time the trunk on this machine (forward tokens/s, one training step, peak memory) at B×L 4×512, 8×512, 4×1024, 8×1024 and chunks 256 and 128; with an existing braid.toml, only measure.")
    var measure = false

    func run() throws {
        guarded {
            let area = try workArea.resolve()
            try area.prepare()
            if measure, FileManager.default.fileExists(atPath: area.configFile.path), !force {
                let config = try workArea.config(in: area)
                guard let record = config.pack, let pack = try Packs.find(record.sha256, in: area) else { throw BraidFailure.missing("braid.toml names no pack that is on disk") }
                try Self.measure(pack: pack, area: area)
                return
            }
            if FileManager.default.fileExists(atPath: area.configFile.path), !force {
                throw BraidFailure.exists("\(area.configFile.path) exists", hint: "pass --force to rewrite it")
            }
            guard let base else { throw BraidFailure.usage("braid init needs --base <pack or hf-id>") }
            let pack: Pack
            if let found = try Packs.find(base, in: area) {
                pack = found
            } else {
                note("init: no pack named \(base) in \(area.packs.path); importing")
                pack = try Importer.run(source: base, revision: nil, name: nil, cut: nil, tapAfterBlocks: nil, check: false, area: area).pack
            }
            let c = pack.config
            var config = BraidConfig(pack: BraidConfig.Pack(name: pack.info.name, sha256: pack.sha256, vocabularySHA256: pack.info.vocabularySHA256,
                                                            tokenizerSHA256: pack.info.tokenizerSHA256, hiddenSize: c.hiddenSize, layers: c.numHiddenLayers, heads: c.numHeads,
                                                            headDim: c.headDim, stateSize: c.stateSize, convKernel: c.convKernel, vocabRows: c.vocabSize,
                                                            vocabTokens: pack.info.tokenizerVocabSize, keyScheme: "residual:\(c.tapAfterBlocks)"))
            config.aiiHome = "~/.rao"
            try config.save(to: area.configFile)
            print("braid.toml → \(area.configFile.path)  (sha256 \(config.sha256.prefix(12)))")
            print("pack \(pack.info.name)  \(pack.sha256.prefix(12))  vocabulary \(pack.info.vocabularySHA256.prefix(12))  tokenizer \(pack.info.tokenizerSHA256.prefix(12))")
            for (label, value) in StorageMath(config: c).table() { print("  \(label.padding(toLength: 30, withPad: " ", startingAt: 0)) \(value)") }
            if measure { try Self.measure(pack: pack, area: area) }
        }
    }

    static func measure(pack: Pack, area: WorkArea) throws {
        note("measure: pack \(pack.info.name) \(pack.sha256.prefix(12)); one MLX workload, nothing else should run")
        let report = try TrunkMeasure.run(pack: pack, vocabTokens: pack.info.tokenizerVocabSize) { note("measure: \($0)") }
        let url = area.bench.appendingPathComponent("measure", isDirectory: true).appendingPathComponent("\(SessionLog.stamp()).json")
        try JSONCoding.write(report, to: url)
        print("   B      L  chunk   forward tok/s   step s   peak GB")
        for row in report.rows {
            print(String(format: "%4d %6d %6d %15.0f %8.2f %9.1f", row.batch, row.length, row.chunk, row.forwardTokensPerSecond, row.stepSeconds, row.peakGB))
        }
        note("measure: report → \(url.path)")
    }
}

enum Packs {
    /// Every pack directory under packs/ with its info.
    static func list(in area: WorkArea) throws -> [(URL, PackInfo)] {
        guard FileManager.default.fileExists(atPath: area.packs.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: area.packs, includingPropertiesForKeys: nil)
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent(Pack.infoFile).path) }
            .map { ($0, try JSONCoding.read(PackInfo.self, from: $0.appendingPathComponent(Pack.infoFile))) }
            .sorted { $0.1.createdAt < $1.1.createdAt }
    }

    /// By sha256 (or prefix) or by name; nil when nothing matches.
    static func find(_ reference: String, in area: WorkArea) throws -> Pack? {
        for (directory, info) in try list(in: area) where info.sha256.hasPrefix(reference.lowercased()) || info.name == reference {
            return try Pack.load(from: directory)
        }
        return nil
    }
}

struct PackCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "pack", abstract: "The packs in the work area.", subcommands: [PackList.self, PackShow.self], defaultSubcommand: PackList.self)

    struct PackList: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "Every pack: name, sha256, shape, cut.")
        @OptionGroup var workArea: WorkAreaOptions
        func run() throws {
            guarded {
                let area = try workArea.resolve()
                let packs = try Packs.list(in: area)
                if packs.isEmpty { print("no packs in \(area.packs.path); run braid import <hf-id>"); return }
                for (_, info) in packs {
                    let c = info.config
                    print("\(info.sha256.prefix(12))  \(info.name.padding(toLength: 18, withPad: " ", startingAt: 0))  \(c.numHiddenLayers)×\(c.hiddenSize) heads \(c.numHeads)×\(c.headDim) state \(c.stateSize)  cut \(c.cut)  vocab \(info.tokenizerVocabSize)/\(c.vocabSize)  \(info.source)")
                }
            }
        }
    }

    struct PackShow: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "show", abstract: "One pack's record, hashes re-derived, and the split: a Thread node and the commons' trunk.")
        @OptionGroup var workArea: WorkAreaOptions
        @Argument var reference: String
        func run() throws {
            guarded {
                let area = try workArea.resolve()
                guard let pack = try Packs.find(reference, in: area) else { throw BraidFailure.missing("no pack \(reference) in \(area.packs.path)") }
                let data = try JSONCoding.prettyEncoder().encode(pack.info)
                print(String(decoding: data, as: UTF8.self))
                print("hashes re-derived on load: ok")
                for (label, value) in StorageMath(config: pack.config).table() where label.hasPrefix("a Thread node") || label.hasPrefix("the commons' trunk") {
                    print("  \(label.padding(toLength: 30, withPad: " ", startingAt: 0)) \(value)")
                }
            }
        }
    }
}
