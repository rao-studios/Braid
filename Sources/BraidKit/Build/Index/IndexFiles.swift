//
//  IndexFiles.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: What an index is on disk: index.safetensors (keys f16, values and addresses i32, loss and
//        entropy f32), index.json (the record binding it to the weights, the corpus, the tokenizer
//        and the pack), partitions.json, shared-ngrams.bin, and checkpoints.json with the state
//        checkpoints the replay starts from.
//

import BraidCore
import Foundation
import MLX

public struct IndexInfo: Codable, Sendable, Equatable {
    public var version = 1
    public var format = "braid-provenance-index"
    public var keyScheme: KeyScheme
    public var alpha: Float
    public var keyDims: Int
    public var count: Int
    public var documents: Int
    public var partitions: Int
    /// The thread blocks the index was keyed with (sha256 of blocks.safetensors; the pack's name when untrained).
    public var blocksSHA256: String
    public var packSHA256: String
    public var seamSHA256: String
    public var vocabularySHA256: String
    public var corpusHash: String
    public var tokenizerSHA256: String
    public var threadID: String?
    public var evalLoss: Float
    public var evalEntropy: Float
    public var evalMemorisedFraction: Float
    public var defaultTau: Float = 0.05
    public var defaultK: Int = 16
    public var cut: Int
    public var paragraphBreak: [Int32]
    public var eos: Int32
    public var checkpointsSHA256: String
    public var indexSHA256: String
    public var createdAt: Date
    /// Documents trained but left out of the index (the stitched bench's withheld set, sorted); nil
    /// when every document is indexed.
    public var excluded: [String]? = nil
}

public enum IndexFiles {
    public static let safetensors = "index.safetensors"
    public static let info = "index.json"
    public static let partitions = "partitions.json"
    public static let ngrams = "shared-ngrams.bin"
    public static let checkpoints = "checkpoints.json"
    public static let checkpointDirectory = "checkpoints"

    public struct Arrays {
        public var keys: MLXArray        // [N, K] f16
        public var values: [Int32]
        public var keyRow: [Int32]
        public var keyOffset: [Int32]
        public var valueRow: [Int32]
        public var valueOffset: [Int32]
        public var loss: [Float]
        public var entropy: [Float]
    }

    public static func write(arrays: Arrays, info: inout IndexInfo, partitions: [PartitionRef], sharedNgrams: Set<UInt64>, manifest: CheckpointManifest, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tensors: [String: MLXArray] = [
            "keys": arrays.keys.asType(.float16), "values": MLXArray(arrays.values), "key_row": MLXArray(arrays.keyRow), "key_offset": MLXArray(arrays.keyOffset),
            "value_row": MLXArray(arrays.valueRow), "value_offset": MLXArray(arrays.valueOffset), "loss": MLXArray(arrays.loss), "entropy": MLXArray(arrays.entropy),
        ]
        try MLX.save(arrays: tensors, metadata: ["format": info.format, "scheme": info.keyScheme.description], url: directory.appendingPathComponent(safetensors))
        try JSONCoding.write(partitions, to: directory.appendingPathComponent(self.partitions))
        var words = sharedNgrams.sorted()
        try words.withUnsafeMutableBytes { Data($0) }.write(to: directory.appendingPathComponent(ngrams), options: .atomic)
        try JSONCoding.write(manifest, to: directory.appendingPathComponent(checkpoints))
        info.checkpointsSHA256 = try ContentHash.sha256Hex(fileAt: directory.appendingPathComponent(checkpoints))
        info.indexSHA256 = try ContentHash.sha256Hex(fileAt: directory.appendingPathComponent(safetensors))
        try JSONCoding.write(info, to: directory.appendingPathComponent(self.info))
    }

    public static func readNgrams(_ url: URL) throws -> Set<UInt64> {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let count = data.count / 8
        var words = [UInt64](repeating: 0, count: count)
        _ = words.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return Set(words)
    }
}
