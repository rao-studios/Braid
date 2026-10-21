//
//  Scratch.swift
//  Scratch
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The playground's own Braid work area, Examples/.work, shared by both of its programs
//        (Braid and Proof): the commons' pack (reused when it is there, linked from the
//        T9's work area when that is mounted, else downloaded once and imported) and braid.toml
//        exactly as `braid init` writes it.
//  PIN:  The T9's work area is read, never written: the playground's Threads, sessions, bench
//        reports and braid.toml live only in Examples/.work.
//

import BraidKit
import Foundation

/// Not named Scratch: no type is named like its module.
public enum ScratchArea {
    public struct Prepared {
        public var area: WorkArea
        public var config: BraidConfig
        public var pack: Pack
        /// How the pack got here: reused, linked from the T9, or downloaded and imported.
        public var origin: String
    }

    /// The commons, and the revision the T9's pack was imported at, for a download.
    public static let base = "AntonV/mamba2-130m-hf"
    public static let revision = "05e8773fc4ac1cd067e8a18a5c45372ce5178405"

    /// Examples/, found from this source file's own path, so a binary built anywhere (by run.sh
    /// in Examples/.build, or by Xcode in DerivedData) uses the same work area.
    public static func playground() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // Sources/Scratch
            .deletingLastPathComponent()    // Sources
            .deletingLastPathComponent()    // Examples
    }

    /// MLX loads its shaders from mlx.metallib beside the running binary, on its first GPU call.
    /// run.sh installs it; a binary Xcode builds in DerivedData has none, so the library Frigate's
    /// build-metallib.sh staged (or Braid's own copy) is put beside it before MLX starts. Returns
    /// where it was copied from, or nil when the binary already had one.
    public static func installMetalLibrary() throws -> String? {
        let fm = FileManager.default
        let binary = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath().deletingLastPathComponent()
        let target = binary.appendingPathComponent("mlx.metallib")
        if fm.fileExists(atPath: target.path) { return nil }
        let braid = playground().deletingLastPathComponent()
        let frigate = braid.deletingLastPathComponent().appendingPathComponent("Frigate", isDirectory: true)
        let checkout = playground().appendingPathComponent(".build/checkouts/Frigate", isDirectory: true)
        let built = [
            checkout.appendingPathComponent(".build/metallib-release/mlx.metallib"),
            checkout.appendingPathComponent(".build/metallib-debug/mlx.metallib"),
            frigate.appendingPathComponent(".build/metallib-release/mlx.metallib"),
            frigate.appendingPathComponent(".build/metallib-debug/mlx.metallib"),
            braid.appendingPathComponent(".build/out/Products/Release/mlx.metallib"),
            braid.appendingPathComponent(".build/out/Products/Debug/mlx.metallib"),
        ]
        guard let source = built.first(where: { fm.fileExists(atPath: $0.path) }) else {
            throw BraidFailure.configuration("no mlx.metallib beside \(binary.path), and none built to copy",
                                             hint: "run Examples/run.sh once")
        }
        try fm.copyItem(at: source, to: target)
        return source.path
    }

    public static func prepare(at root: URL, progress: @escaping @Sendable (String) -> Void) throws -> Prepared {
        let fm = FileManager.default
        let area = WorkArea(root: root)
        try area.prepare()
        func holdsPack(_ directory: URL) -> Bool { fm.fileExists(atPath: directory.appendingPathComponent(Pack.infoFile).path) }
        func isLink(_ url: URL) -> Bool { (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil }

        var config = fm.fileExists(atPath: area.configFile.path) ? try BraidConfig.load(from: area.configFile) : nil
        let t9 = WorkArea(root: WorkArea.t9)
        let wanted = config?.pack?.sha256 ?? (try? BraidConfig.load(from: t9.configFile))?.pack?.sha256
        let directory: URL
        let origin: String
        if let sha = wanted, holdsPack(area.pack(sha256: sha)) {
            directory = area.pack(sha256: sha)
            origin = isLink(directory) ? "linked from the T9" : "reused"
        } else if let sha = wanted, holdsPack(t9.pack(sha256: sha)) {
            directory = area.pack(sha256: sha)
            if isLink(directory) { try fm.removeItem(at: directory) }    // only our own stale link
            try fm.createSymbolicLink(at: directory, withDestinationURL: t9.pack(sha256: sha))
            origin = "linked from the T9"
        } else if let sha = wanted, isLink(area.pack(sha256: sha)) {
            throw BraidFailure.unavailable("the pack is linked from the T9, which is not mounted",
                                           hint: "mount the T9, or remove \(area.pack(sha256: sha).path) to download the commons")
        } else {
            let folder = try PackImporter.fetch(repo: base, revision: revision, modelsHome: area.modelsHome, progress: progress)
            directory = try PackImporter.importPack(folder: folder, name: "mamba2-130m-hf", source: "hub:\(base)@\(revision)",
                                                    cut: nil, tapAfterBlocks: nil, into: area.packs, progress: progress).directory
            origin = "downloaded and imported"
        }
        let pack = try Pack.load(from: directory)    // every hash re-derived

        if config == nil {
            // What `braid init` writes for a pack (BraidCLI's InitCommand), defaults untouched.
            let c = pack.config
            var made = BraidConfig(pack: BraidConfig.Pack(name: pack.info.name, sha256: pack.sha256, vocabularySHA256: pack.info.vocabularySHA256,
                                                          tokenizerSHA256: pack.info.tokenizerSHA256, hiddenSize: c.hiddenSize, layers: c.numHiddenLayers,
                                                          heads: c.numHeads, headDim: c.headDim, stateSize: c.stateSize, convKernel: c.convKernel,
                                                          vocabRows: c.vocabSize, vocabTokens: pack.info.tokenizerVocabSize,
                                                          keyScheme: "residual:\(c.tapAfterBlocks)"))
            made.aiiHome = "~/.rao"
            try made.save(to: area.configFile)
            config = made
        }
        guard let written = config, written.pack?.sha256 == pack.sha256 else {
            throw BraidFailure.data("\(area.configFile.path) names another pack than \(pack.sha256.prefix(12))", hint: "start over: rm -rf \(area.root.path)")
        }
        return Prepared(area: area, config: written, pack: pack, origin: origin)
    }
}
