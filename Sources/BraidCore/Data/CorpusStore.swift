//
//  CorpusStore.swift
//  BraidCore
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Reads a corpus directory as RaoLM's dataset generator wrote it: manifest.json,
//        facts.jsonl, documents/<id>.json (and .txt, which Braid does not read).
//  PIN:  Read only. Braid does not write corpora of this shape; a dataset node is a source.
//

import Foundation

public enum CorpusStore {
    public static func load(_ directory: URL) throws -> GeneratedCorpus {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { throw CorpusStoreError.notACorpus(directory.path) }
        let manifest = try JSONCoding.read(CorpusManifest.self, from: manifestURL)
        let documentsDirectory = directory.appendingPathComponent("documents", isDirectory: true)
        let documents = try manifest.documentIDs.map { id in
            try JSONCoding.read(CorpusDocument.self, from: documentsDirectory.appendingPathComponent("\(id).json"))
        }
        return GeneratedCorpus(manifest: manifest, documents: documents)
    }

    public static func exists(at directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path)
    }
}

public enum CorpusStoreError: Error, CustomStringConvertible, Equatable {
    case notACorpus(String)

    public var description: String {
        switch self {
        case .notACorpus(let path): return "no corpus manifest.json in \(path)"
        }
    }
}
