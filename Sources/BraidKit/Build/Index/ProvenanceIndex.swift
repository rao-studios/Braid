//
//  ProvenanceIndex.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: A loaded index: keys as float32 unit vectors on the GPU, every entry's value and
//        addresses on the CPU, exact cosine search (one matmul, the top k+8 by argPartition, a
//        CPU sort by score then entry), and the layout the trace tracker and the citations read.
//  PIN:  Loading re-hashes index.safetensors against index.json. Keys are stored float16 and
//        renormalised on load, as RaoLM did.
//

import BraidCore
import Foundation
import MLX

public final class ProvenanceIndex {
    public let directory: URL
    public let info: IndexInfo
    public let partitions: [PartitionRef]
    public let values: [Int32]
    public let keyRow: [Int32]
    public let keyOffset: [Int32]
    public let valueRow: [Int32]
    public let valueOffset: [Int32]
    public let loss: [Float]
    public let entropy: [Float]
    public let sharedNgrams: Set<UInt64>
    public let checkpoints: CheckpointManifest
    let keys: MLXArray

    public init(directory: URL) throws {
        self.directory = directory
        info = try JSONCoding.read(IndexInfo.self, from: directory.appendingPathComponent(IndexFiles.info))
        let tensorsURL = directory.appendingPathComponent(IndexFiles.safetensors)
        guard try ContentHash.sha256Hex(fileAt: tensorsURL) == info.indexSHA256 else { throw BraidFailure.data("\(directory.path): index.safetensors does not hash to index.json") }
        let arrays = try loadArrays(url: tensorsURL)
        guard let k = arrays["keys"] else { throw BraidFailure.data("the index has no keys") }
        keys = ProvenanceKey.normalized(k.asType(.float32))
        eval(keys)
        func ints(_ name: String) throws -> [Int32] {
            guard let a = arrays[name] else { throw BraidFailure.data("the index lacks \(name)") }
            return a.asArray(Int32.self)
        }
        func floats(_ name: String) throws -> [Float] {
            guard let a = arrays[name] else { throw BraidFailure.data("the index lacks \(name)") }
            return a.asArray(Float.self)
        }
        values = try ints("values")
        keyRow = try ints("key_row")
        keyOffset = try ints("key_offset")
        valueRow = try ints("value_row")
        valueOffset = try ints("value_offset")
        loss = try floats("loss")
        entropy = try floats("entropy")
        partitions = try JSONCoding.read([PartitionRef].self, from: directory.appendingPathComponent(IndexFiles.partitions))
        sharedNgrams = try IndexFiles.readNgrams(directory.appendingPathComponent(IndexFiles.ngrams))
        let manifestURL = directory.appendingPathComponent(IndexFiles.checkpoints)
        guard try ContentHash.sha256Hex(fileAt: manifestURL) == info.checkpointsSHA256 else { throw BraidFailure.data("\(directory.path): checkpoints.json does not hash to index.json") }
        checkpoints = try JSONCoding.read(CheckpointManifest.self, from: manifestURL)
    }

    public var count: Int { values.count }

    public var layout: IndexLayout {
        IndexLayout(values: values, keyRow: keyRow, keyOffset: keyOffset, partitions: partitions, breakLength: info.paragraphBreak.count, sharedNgrams: sharedNgrams)
    }

    /// The top `k` entries by cosine for each query row ([Q, K] unit keys), as hits.
    public func query(_ queries: MLXArray, k: Int) -> [[Hit]] {
        guard count > 0 else { return (0..<queries.dim(0)).map { _ in [] } }
        let scores = matmul(queries.asType(.float32), keys.T)                                        // [Q, N]
        let m = min(k + 8, count)
        let candidates = argPartition(-scores, kth: m - 1, axis: -1)[0..., 0 ..< m]                    // [Q, m]
        let picked = takeAlong(scores, candidates, axis: -1)
        eval(candidates, picked)
        let ids = candidates.asArray(Int32.self)
        let values = picked.asArray(Float.self)
        return (0..<queries.dim(0)).map { q in
            var rows: [(entry: Int, score: Float)] = (0..<m).map { (Int(ids[q * m + $0]), values[q * m + $0]) }
            rows.sort { $0.score != $1.score ? $0.score > $1.score : $0.entry < $1.entry }
            return rows.prefix(k).map { hit(entry: $0.entry, score: $0.score) }
        }
    }

    public func hit(entry: Int, score: Float) -> Hit {
        Hit(entry: Int32(entry), score: score, value: values[entry], row: valueRow[entry], offset: valueOffset[entry], loss: loss[entry])
    }

    /// Entries of one document, in order.
    public func entries(ofRows rows: Set<Int32>) -> [Int] { keyRow.indices.filter { rows.contains(keyRow[$0]) } }

    /// The partition table by row.
    public private(set) lazy var partitionByRow: [Int: PartitionRef] = Dictionary(partitions.map { ($0.row, $0) }, uniquingKeysWith: { first, _ in first })

    /// Each document's entries, a contiguous range in corpus order (entries are written document by document).
    public private(set) lazy var entriesByDocument: [String: Range<Int>] = {
        var ranges: [String: Range<Int>] = [:]
        var e = 0
        while e < keyRow.count {
            let row = Int(keyRow[e])
            guard let documentID = partitionByRow[row]?.documentID else { e += 1; continue }
            let start = e
            while e < keyRow.count, let d = partitionByRow[Int(keyRow[e])]?.documentID, d == documentID { e += 1 }
            ranges[documentID] = start ..< e
        }
        return ranges
    }()

    public func partition(row: Int) -> PartitionRef? { partitionByRow[row] }

    public func key(entry: Int) -> MLXArray { keys[entry] }
}
