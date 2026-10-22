//
//  Pack.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: A pack: the imported Mamba2 model as a braid's foundation — the vocabulary (embedding and
//        final norm), every block, the tokenizer — named by SHA-256 and written once. The NAME covers
//        everything a node must match (norm, embedding, every block in key order, the tokenizer);
//        the SEAM covers what a node runs unchanged (norm, embedding, the tail's blocks ≥ cut): the
//        commons' tail, which every Thread runs behind its own head; the VOCABULARY fingerprint is
//        the reed's name. RaoLM v2's definitions, unchanged. The commons is a pack run whole
//        (`LanguageModule(pack:)`); a head starts from `headArrays`.
//  PIN:  Float32 throughout, so the index a node keys later matches the weights on disk. A pack
//        directory is staged and renamed; loading re-hashes and refuses any difference.
//

import BraidCore
import Foundation
import MLX
import MLXNN

public struct PackInfo: Codable, Sendable, Equatable {
    public var version = 2
    public var name: String
    public var source: String
    public var architecture = "mamba2"
    public var config: Mamba2Config
    /// NAME: SHA-256(norm ‖ embedding ‖ ∀ block arrays sorted by key: key ‖ bytes ‖ tokenizerSHA256).
    public var sha256: String
    /// SEAM: SHA-256(norm ‖ embedding ‖ ∀ arrays of blocks ≥ cut sorted by key: key ‖ bytes).
    public var seamSHA256: String
    public var vocabularySHA256: String
    public var baseSHA256: String
    public var vocabularyFileSHA256: String
    public var tokenizerSHA256: String
    public var tokenizerFiles: [String]
    public var tokenizerVocabSize: Int
    public var paddingRows: [Int]
    public var eosTokenID: Int
    public var paragraphBreak: [Int]
    public var dtype = "float32"
    public var sourceDType: String
    public var referenceNLL: Float?
    public var referenceSample: String?
    public var stateBytesPerStream: Int
    public var createdAt: Date
}

public enum PackHash {
    static func bytes(_ array: MLXArray) -> Data {
        let floats = array.asType(.float32).asArray(Float.self)
        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// SHA-256(norm f32 LE ‖ embedding f32 LE).
    public static func vocabulary(embedding: MLXArray, norm: MLXArray) -> String {
        ContentHash.sha256Hex(parts: [bytes(norm), bytes(embedding)])
    }

    /// SHA-256(norm ‖ embedding ‖ ∀ (key, bytes) sorted by key ‖ tokenizerSHA256).
    public static func name(embedding: MLXArray, norm: MLXArray, blocks: [(String, MLXArray)], tokenizerSHA256: String) -> String {
        var parts = [bytes(norm), bytes(embedding)]
        for (key, array) in blocks.sorted(by: { $0.0 < $1.0 }) {
            parts.append(Data(key.utf8))
            parts.append(bytes(array))
        }
        parts.append(Data(tokenizerSHA256.utf8))
        return ContentHash.sha256Hex(parts: parts)
    }

    /// SHA-256(norm ‖ embedding ‖ ∀ tail block (key, bytes) sorted by key).
    public static func seam(embedding: MLXArray, norm: MLXArray, tail: [(String, MLXArray)]) -> String {
        var parts = [bytes(norm), bytes(embedding)]
        for (key, array) in tail.sorted(by: { $0.0 < $1.0 }) {
            parts.append(Data(key.utf8))
            parts.append(bytes(array))
        }
        return ContentHash.sha256Hex(parts: parts)
    }
}

public final class Pack {
    public static let infoFile = "pack.json"
    public static let vocabularyFile = "vocabulary.safetensors"
    public static let baseFile = "base.safetensors"
    public static let tokenizerDirectory = "tokenizer"
    public static let embeddingKey = "backbone.embeddings.weight"
    public static let normKey = "backbone.norm_f.weight"

    public let directory: URL
    public let info: PackInfo
    public let embedding: MLXArray
    public let norm: MLXArray
    /// Every block array by its checkpoint key, f32.
    public let blocks: [String: MLXArray]

    init(directory: URL, info: PackInfo, embedding: MLXArray, norm: MLXArray, blocks: [String: MLXArray]) {
        self.directory = directory
        self.info = info
        self.embedding = embedding
        self.norm = norm
        self.blocks = blocks
    }

    public var config: Mamba2Config { info.config }
    public var sha256: String { info.sha256 }
    public var tokenizerFolder: URL { directory.appendingPathComponent(Self.tokenizerDirectory, isDirectory: true) }
    public var identity: PackIdentity {
        PackIdentity(sha256: info.sha256, name: info.name, vocabularySHA256: info.vocabularySHA256, tokenizerSHA256: info.tokenizerSHA256,
                     hiddenSize: config.hiddenSize, vocabulary: config.vocabSize, seamSHA256: info.seamSHA256)
    }

    /// The tail's block arrays: blocks ≥ cut, the seam's input.
    public var tailArrays: [(String, MLXArray)] {
        blocks.filter { LanguageModule.blockIndex(ofKey: $0.key).map { $0 >= config.cut } ?? false }.map { ($0.key, $0.value) }
    }

    /// A head's arrays: blocks 0..<cut as imported. The commons' own head, where a Thread's training
    /// starts, and what an untrained Thread runs.
    public var headArrays: [String: MLXArray] {
        blocks.filter { LanguageModule.blockIndex(ofKey: $0.key).map { $0 < config.cut } ?? false }
    }

    /// The directory a pack with this name lives in under `packs/`.
    public static func directory(in packs: URL, sha256: String) -> URL { packs.appendingPathComponent(String(sha256.prefix(12)), isDirectory: true) }

    /// Writes the pack once. A directory holding the same pack is left alone; another pack there is refused.
    public static func write(info: PackInfo, embedding: MLXArray, norm: MLXArray, blocks: [String: MLXArray], tokenizerFiles: [URL], into packs: URL) throws -> URL {
        let target = directory(in: packs, sha256: info.sha256)
        if FileManager.default.fileExists(atPath: target.appendingPathComponent(infoFile).path) {
            let existing = try JSONCoding.read(PackInfo.self, from: target.appendingPathComponent(infoFile))
            if existing.sha256 == info.sha256 { return target }
            throw BraidFailure.exists("\(target.path) holds another pack (\(existing.sha256.prefix(12)))")
        }
        let staging = packs.appendingPathComponent(".staging-\(info.sha256.prefix(12))-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: staging.appendingPathComponent(tokenizerDirectory), withIntermediateDirectories: true)
        try MLX.save(arrays: [embeddingKey: embedding, normKey: norm], metadata: ["format": "braid-vocabulary-v1"], url: staging.appendingPathComponent(vocabularyFile))
        try MLX.save(arrays: blocks, metadata: ["format": "braid-base-v1", "pack": info.sha256], url: staging.appendingPathComponent(baseFile))
        for file in tokenizerFiles {
            try FileManager.default.copyItem(at: file, to: staging.appendingPathComponent(tokenizerDirectory).appendingPathComponent(file.lastPathComponent))
        }
        var written = info
        written.baseSHA256 = try ContentHash.sha256Hex(fileAt: staging.appendingPathComponent(baseFile))
        written.vocabularyFileSHA256 = try ContentHash.sha256Hex(fileAt: staging.appendingPathComponent(vocabularyFile))
        try JSONCoding.write(written, to: staging.appendingPathComponent(infoFile))
        try FileManager.default.createDirectory(at: packs, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: staging, to: target)
        return target
    }

    /// Loads a pack and re-derives every hash; any difference is refused.
    public static func load(from directory: URL) throws -> Pack {
        let info = try JSONCoding.read(PackInfo.self, from: directory.appendingPathComponent(infoFile))
        guard try ContentHash.sha256Hex(fileAt: directory.appendingPathComponent(baseFile)) == info.baseSHA256 else { throw BraidFailure.data("\(directory.lastPathComponent): base.safetensors does not hash to the pack's record") }
        guard try ContentHash.sha256Hex(fileAt: directory.appendingPathComponent(vocabularyFile)) == info.vocabularyFileSHA256 else { throw BraidFailure.data("\(directory.lastPathComponent): vocabulary.safetensors does not hash to the pack's record") }
        let vocabulary = try loadArrays(url: directory.appendingPathComponent(vocabularyFile))
        guard let embedding = vocabulary[embeddingKey], let norm = vocabulary[normKey] else { throw BraidFailure.data("the vocabulary file lacks the embedding or the norm") }
        let blocks = try loadArrays(url: directory.appendingPathComponent(baseFile))
        let tokenizer = directory.appendingPathComponent(tokenizerDirectory).appendingPathComponent("tokenizer.json")
        guard try ContentHash.sha256Hex(fileAt: tokenizer) == info.tokenizerSHA256 else { throw BraidFailure.data("\(directory.lastPathComponent): tokenizer.json does not hash to the pack's record") }
        guard PackHash.vocabulary(embedding: embedding, norm: norm) == info.vocabularySHA256 else { throw BraidFailure.data("\(directory.lastPathComponent): the vocabulary fingerprint differs") }
        let pack = Pack(directory: directory, info: info, embedding: embedding, norm: norm, blocks: blocks)
        guard PackHash.name(embedding: embedding, norm: norm, blocks: blocks.map { ($0.key, $0.value) }, tokenizerSHA256: info.tokenizerSHA256) == info.sha256 else {
            throw BraidFailure.data("\(directory.lastPathComponent): the pack's name does not hash")
        }
        guard PackHash.seam(embedding: embedding, norm: norm, tail: pack.tailArrays) == info.seamSHA256 else { throw BraidFailure.data("\(directory.lastPathComponent): the seam does not hash") }
        return pack
    }

    public func reed(tokens: Int) -> MLXReed { MLXReed(embedding: embedding, vocabularySHA256: info.vocabularySHA256, tokens: tokens) }
}
