//
//  PackImporter.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: `braid import`: a Hugging Face Mamba2 checkpoint (config.json, safetensors, tokenizer
//        files) becomes a pack. The conv1d weight is turned to MLX's layout, every array is widened
//        to float32, the lm_head must be tied (or equal to the embedding), and the pack's hashes are
//        written at import time. The download goes through Frigate's hub into the work area.
//

import BraidCore
import Foundation
import FrigateBridge
import MLX

public enum PackImporter {
    public static let patterns = ["config.json", "*.safetensors", "model.safetensors.index.json", "tokenizer.json", "tokenizer_config.json", "special_tokens_map.json"]

    /// Fetches a repo into `<modelsHome>/snapshots/models/<org>/<repo>` (or finds it there).
    public static func fetch(repo: String, revision: String?, modelsHome: URL, progress: @escaping @Sendable (String) -> Void) throws -> URL {
        if let onDisk = HubDownloader.materializedSnapshot(id: repo, revision: revision, matching: patterns, roots: HubDownloader.snapshotRoots(home: modelsHome)) {
            return onDisk
        }
        progress("downloading \(repo)\(revision.map { "@\($0)" } ?? "") into \(modelsHome.path)")
        return try Blocking.run {
            try await HubDownloader(home: modelsHome).download(id: repo, revision: revision, matching: patterns, useLatest: revision == nil) { p in
                progress(String(format: "  %.0f%%", p.fractionCompleted * 100))
            }
        }
    }

    public struct Imported {
        public var directory: URL
        public var pack: Pack
    }

    /// Reads the checkpoint folder, builds the pack and writes it under `packs`.
    public static func importPack(folder: URL, name: String, source: String, cut: Int?, tapAfterBlocks: Int?, into packs: URL,
                                  progress: (String) -> Void = { _ in }) throws -> Imported {
        var config = try JSONCoding.readStandardized(Mamba2Config.self, from: folder.appendingPathComponent("config.json"))
        if let cut { config.cut = cut }
        if let tapAfterBlocks { config.tapAfterBlocks = tapAfterBlocks }
        try config.validate()
        progress("reading weights")
        var weights: [String: MLXArray] = [:]
        var sourceDType = "unknown"
        let indexURL = folder.appendingPathComponent("model.safetensors.index.json")
        var files: [URL] = []
        if FileManager.default.fileExists(atPath: indexURL.path),
           let index = try JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [String: Any],
           let map = index["weight_map"] as? [String: String] {
            files = Array(Set(map.values)).sorted().map { folder.appendingPathComponent($0) }
        } else {
            files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "safetensors" }.sorted { $0.path < $1.path }
        }
        guard !files.isEmpty else { throw BraidFailure.missing("no safetensors in \(folder.path)") }
        for file in files {
            for (key, value) in try loadArrays(url: file) {
                sourceDType = "\(value.dtype)"
                weights[key] = value
            }
        }
        // Sanitize: HF's conv1d weight is [C,1,K]; MLX's is [C,K,1]. The lm_head must be the embedding.
        for (key, value) in weights where key.contains("conv1d.weight") && value.dim(-1) != 1 { weights[key] = value.swappedAxes(1, 2) }
        if let lmHead = weights.removeValue(forKey: "lm_head.weight") {
            guard let embedding = weights[Pack.embeddingKey] else { throw BraidFailure.data("the checkpoint has an lm_head but no embedding") }
            let difference = abs(lmHead.asType(.float32) - embedding.asType(.float32)).max()
            eval(difference)
            guard difference.item(Float.self) == 0 else { throw BraidFailure.data("the checkpoint's lm_head is not its embedding; Braid's reed is the vocabulary") }
        }
        guard let embedding = weights.removeValue(forKey: Pack.embeddingKey)?.asType(.float32), let norm = weights.removeValue(forKey: Pack.normKey)?.asType(.float32) else {
            throw BraidFailure.data("the checkpoint lacks \(Pack.embeddingKey) or \(Pack.normKey)")
        }
        guard embedding.dim(0) == config.vocabSize, embedding.dim(1) == config.hiddenSize else {
            throw BraidFailure.data("the embedding is \(embedding.shape), not [\(config.vocabSize), \(config.hiddenSize)]")
        }
        var blocks: [String: MLXArray] = [:]
        for (key, value) in weights {
            guard Trunk.blockIndex(ofKey: key) != nil else { throw BraidFailure.data("unexpected array \(key) in the checkpoint") }
            blocks[key] = value.asType(.float32)
        }
        eval(embedding, norm)
        eval(Array(blocks.values))
        // The tokenizer, checked.
        progress("loading the tokenizer")
        let tokenizerFiles = ["tokenizer.json", "tokenizer_config.json", "special_tokens_map.json"].map { folder.appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        let tokenizer = try BraidTokenizer(folder: folder)
        guard tokenizer.eos == 0 else { throw BraidFailure.data("the tokenizer's eos is \(tokenizer.eos); Braid's streams open with eos 0") }
        guard tokenizer.vocabSize <= config.vocabSize else { throw BraidFailure.data("the tokenizer has \(tokenizer.vocabSize) tokens but the embedding \(config.vocabSize) rows") }
        for sample in ["Hello world.", "  two  spaces\n\nand a break", "naïve café 日本"] {
            guard tokenizer.decode(tokenizer.encode(sample)) == sample else { throw BraidFailure.data("the tokenizer does not round-trip \(sample.debugDescription)") }
        }
        progress("hashing")
        let blockList = blocks.map { ($0.key, $0.value) }
        let trunkList = blockList.filter { Trunk.blockIndex(ofKey: $0.0).map { $0 >= config.cut } ?? false }
        let info = PackInfo(name: name, source: source, config: config,
                            sha256: PackHash.name(embedding: embedding, norm: norm, blocks: blockList, tokenizerSHA256: tokenizer.sha256),
                            seamSHA256: PackHash.seam(embedding: embedding, norm: norm, trunk: trunkList),
                            vocabularySHA256: PackHash.vocabulary(embedding: embedding, norm: norm), baseSHA256: "", vocabularyFileSHA256: "",
                            tokenizerSHA256: tokenizer.sha256, tokenizerFiles: tokenizerFiles.map(\.lastPathComponent), tokenizerVocabSize: tokenizer.vocabSize,
                            paddingRows: tokenizer.vocabSize < config.vocabSize ? [tokenizer.vocabSize, config.vocabSize] : [], eosTokenID: Int(tokenizer.eos),
                            paragraphBreak: tokenizer.paragraphBreak.map(Int.init), sourceDType: sourceDType, referenceNLL: nil, referenceSample: nil,
                            stateBytesPerStream: StorageMath(config: config).stateBytesPerStream, createdAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)))
        progress("writing the pack")
        let directory = try Pack.write(info: info, embedding: embedding, norm: norm, blocks: blocks, tokenizerFiles: tokenizerFiles, into: packs)
        return Imported(directory: directory, pack: try Pack.load(from: directory))
    }

    /// Records a greedy sample and the held-out NLL in pack.json after the trunk has run once.
    public static func record(referenceNLL: Float?, sample: String?, in directory: URL) throws {
        var info = try JSONCoding.read(PackInfo.self, from: directory.appendingPathComponent(Pack.infoFile))
        info.referenceNLL = referenceNLL
        info.referenceSample = sample
        try JSONCoding.write(info, to: directory.appendingPathComponent(Pack.infoFile))
    }
}

extension PackImporter {
    /// The commit a downloaded snapshot folder was materialised at, when the hub recorded it.
    public static func snapshotCommit(_ folder: URL) -> String? { HubDownloader.snapshotCommit(folder) }
}
