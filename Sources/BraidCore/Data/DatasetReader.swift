//
//  DatasetReader.swift
//  BraidCore
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Loads a braid dataset directory: the manifest, every node's corpus in feeding order,
//        each node's meta.jsonl and the crosslinks. Resolves a dataset by name in the datasets
//        root, and a `dataset:<name or path>#<node>` source to one node's corpus.
//  PIN:  The dataset hash is recomputed the way RaoLM defines it, so `verify` can tell a dataset
//        that changed on disk from the one a Thread was fed.
//

import Foundation

public struct BraidDataset: Sendable {
    public var directory: URL
    public var manifest: DatasetManifest
    /// Per node, its corpus with documents in feeding order.
    public var corpora: [String: GeneratedCorpus]
    public var meta: [String: [DatasetDocumentMeta]]
    public var crosslinks: [DatasetCrosslink]

    public var names: [String] { manifest.names }

    public func corpus(node: String) throws -> GeneratedCorpus {
        guard let corpus = corpora[node] else { throw DatasetError.noSuchNode(node, available: names) }
        return corpus
    }

    public static func exists(at directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(DatasetManifest.fileName).path)
    }

    public static func nodeDirectory(_ directory: URL, _ name: String) -> URL {
        directory.appendingPathComponent("nodes", isDirectory: true).appendingPathComponent(name, isDirectory: true)
    }

    public static func load(_ directory: URL) throws -> BraidDataset {
        let manifestURL = directory.appendingPathComponent(DatasetManifest.fileName)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { throw DatasetError.notADataset(directory.path) }
        let manifest = try JSONCoding.read(DatasetManifest.self, from: manifestURL)
        var corpora: [String: GeneratedCorpus] = [:]
        var meta: [String: [DatasetDocumentMeta]] = [:]
        for name in manifest.names {
            let node = nodeDirectory(directory, name)
            corpora[name] = try CorpusStore.load(node)
            let metaURL = node.appendingPathComponent("meta.jsonl")
            meta[name] = FileManager.default.fileExists(atPath: metaURL.path) ? try JSONCoding.readLines(DatasetDocumentMeta.self, from: metaURL) : []
        }
        let links = try JSONCoding.readLines(DatasetCrosslink.self, from: directory.appendingPathComponent("crosslinks.jsonl"))
        return BraidDataset(directory: directory, manifest: manifest, corpora: corpora, meta: meta, crosslinks: links)
    }

    /// SHA-256 over every node's corpus hash and every link, in order (RaoLM's definition).
    public static func hash(corpusHashes: [(name: String, hash: String)], crosslinks: [DatasetCrosslink]) throws -> String {
        let encoder = JSONCoding.lineEncoder()
        var lines = corpusHashes.map { "\($0.name)\t\($0.hash)" }
        for link in crosslinks { lines.append(String(decoding: try encoder.encode(link), as: UTF8.self)) }
        return ContentHash.sha256Hex(lines.joined(separator: "\n"))
    }

    /// The hash of the dataset as it is now on disk (its corpora recomputed from their documents).
    public func recomputedHash() throws -> String {
        try Self.hash(corpusHashes: names.map { ($0, corpora[$0]?.recomputedCorpusHash ?? "") }, crosslinks: crosslinks)
    }
}

/// Where datasets live: `BRAID_DATASETS_DIR`, else the work area's `datasets/`, else RaoLM's
/// datasets on the T9 (the ones the benches were designed on).
public enum DatasetsRoot {
    public static let raolmDatasets = URL(fileURLWithPath: "/Volumes/T9/rao/projects/raolm/datasets", isDirectory: true)

    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment, workArea: URL?,
                               exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL? {
        if let override = environment["BRAID_DATASETS_DIR"], !override.isEmpty { return URL(fileURLWithPath: override, isDirectory: true) }
        if let workArea {
            let own = workArea.appendingPathComponent("datasets", isDirectory: true)
            if exists(own) { return own }
        }
        return exists(raolmDatasets) ? raolmDatasets : nil
    }

    /// `braid-n3` → `<root>/braid-n3`; a path (containing `/`) is taken as it is.
    public static func locate(_ nameOrPath: String, root: URL?) throws -> URL {
        if nameOrPath.contains("/") || nameOrPath.hasPrefix("~") { return URL(fileURLWithPath: (nameOrPath as NSString).expandingTildeInPath, isDirectory: true) }
        guard let root else { throw DatasetError.noDatasetsRoot }
        return root.appendingPathComponent(nameOrPath, isDirectory: true)
    }
}
