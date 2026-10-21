//
//  RaoLMIndex.swift
//  BraidCore
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: A RaoLM node's provenance index as the trace needs it, read with no MLX: the values, key
//        rows and key offsets from index.safetensors, the node's partition table from
//        partitions.json and the paragraph break from index.json (what RaoLM's TrajectoryCorpus
//        reads; its tracker reads nothing else — shared n-grams and the keys serve spans and
//        retrieval only). Found under a RaoLM data root as RaoLM lays a version out:
//        nodes/<name>/versions/v<NNNN>/provenance/epoch-<E>/.
//  PIN:  The file's SHA-256 is RaoLM's index sha256 (its manifest's `indexSHA256`); a layout is
//        used only when they agree.
//

import Foundation

public struct RaoLMIndex: Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case missing(String)
        case sha256(directory: String, expected: String, found: String)
        case shape(String)

        public var description: String {
            switch self {
            case .missing(let what): return "RaoLM index: \(what)"
            case .sha256(let directory, let expected, let found):
                return "RaoLM index at \(directory) hashes to \(found.prefix(12)), the record names \(expected.prefix(12))"
            case .shape(let detail): return "RaoLM index: \(detail)"
            }
        }
    }

    /// RaoLM's index.json, as far as the trace reads it.
    struct Info: Decodable {
        var count: Int?
        var epoch: Int?
        var paragraphBreak: [Int]?
        var tokenizerSHA256: String?
    }

    public var node: String
    public var directory: URL
    public var sha256: String
    public var layout: IndexLayout

    public var count: Int { layout.values.count }

    /// `<dataRoot>/nodes/<node>/versions/v<NNNN>/provenance/epoch-<epoch>/`.
    public static func directory(dataRoot: URL, node: String, version: Int, epoch: Int) -> URL {
        dataRoot.appendingPathComponent("nodes", isDirectory: true).appendingPathComponent(node, isDirectory: true)
            .appendingPathComponent("versions", isDirectory: true).appendingPathComponent(String(format: "v%04d", version), isDirectory: true)
            .appendingPathComponent("provenance", isDirectory: true).appendingPathComponent("epoch-\(epoch)", isDirectory: true)
    }

    /// Loads one index directory; refuses it when `expectedSHA256` is given and the file's differs.
    public static func load(directory: URL, node: String, expectedSHA256: String? = nil) throws -> RaoLMIndex {
        let file = directory.appendingPathComponent("index.safetensors")
        guard FileManager.default.fileExists(atPath: file.path) else { throw Failure.missing("no index.safetensors in \(directory.path)") }
        let tensors = try SafetensorsFile(url: file)
        let sha256 = tensors.sha256
        if let expectedSHA256, expectedSHA256 != sha256 { throw Failure.sha256(directory: directory.path, expected: expectedSHA256, found: sha256) }
        let values = try tensors.int32("values")
        let keyRow = try tensors.int32("key_row")
        let keyOffset = try tensors.int32("key_offset")
        guard values.count == keyRow.count, values.count == keyOffset.count else {
            throw Failure.shape("\(values.count) values, \(keyRow.count) key rows, \(keyOffset.count) key offsets")
        }
        let info = try JSONCoding.read(Info.self, from: directory.appendingPathComponent("index.json"))
        if let count = info.count, count != values.count { throw Failure.shape("index.json counts \(count) entries, the arrays hold \(values.count)") }
        let partitions = try JSONCoding.read([RaoLMPartition].self, from: directory.appendingPathComponent("partitions.json")).map(\.partitionRef)
        let layout = IndexLayout(values: values, keyRow: keyRow, keyOffset: keyOffset, partitions: partitions, breakLength: info.paragraphBreak?.count ?? 0)
        return RaoLMIndex(node: node, directory: directory, sha256: sha256, layout: layout)
    }

    /// The index a strand of a RaoLM record names: its version and epoch under `dataRoot`, checked
    /// against the record's index sha256.
    public static func load(strand: RaoLMStrandRef, dataRoot: URL) throws -> RaoLMIndex {
        let directory = directory(dataRoot: dataRoot, node: strand.name, version: strand.version, epoch: strand.manifest.epoch)
        return try load(directory: directory, node: strand.name, expectedSHA256: strand.manifest.indexSHA256)
    }

    /// Scans every version and epoch of `node` under `dataRoot` for the index whose SHA-256 is
    /// `sha256` (a session header names the sha, not the epoch). Nil when none is.
    public static func find(dataRoot: URL, node: String, sha256: String) throws -> RaoLMIndex? {
        let versions = dataRoot.appendingPathComponent("nodes", isDirectory: true).appendingPathComponent(node, isDirectory: true)
            .appendingPathComponent("versions", isDirectory: true)
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: versions.path) else { return nil }
        for version in names.sorted() where version.hasPrefix("v") && !version.hasPrefix("._") {
            let provenance = versions.appendingPathComponent(version, isDirectory: true).appendingPathComponent("provenance", isDirectory: true)
            guard let epochs = try? manager.contentsOfDirectory(atPath: provenance.path) else { continue }
            for epoch in epochs.sorted() where epoch.hasPrefix("epoch-") {
                let directory = provenance.appendingPathComponent(epoch, isDirectory: true)
                let file = directory.appendingPathComponent("index.safetensors")
                guard manager.fileExists(atPath: file.path), (try? ContentHash.sha256Hex(fileAt: file)) == sha256 else { continue }
                return try load(directory: directory, node: node, expectedSHA256: sha256)
            }
        }
        return nil
    }

    /// Row → document id, for the wire audit.
    public var documentOfRow: [Int32: String] {
        Dictionary(layout.partitions.map { (Int32($0.row), $0.documentID) }, uniquingKeysWith: { first, _ in first })
    }
}
