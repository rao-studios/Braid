//
//  CorpusSnapshot.swift
//  BraidCore
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: A corpus exactly as a source returned it: document ids, names, groups, partition texts
//        in stored order, and the lane's own partition ids and urls.
//  PIN:  Training and indexing only ever consume a snapshot, and the snapshot's corpus hash goes
//        into every version and index manifest, so a Thread can prove which lane state it saw.
//

import Foundation

public struct SnapshotPartition: Codable, Sendable, Equatable {
    public var index: Int
    public var text: String
    public var textSHA256: String
    public var url: String?
    public var threadPartitionID: String?

    public init(index: Int, text: String, url: String? = nil, threadPartitionID: String? = nil) {
        self.index = index
        self.text = text
        self.textSHA256 = ContentHash.sha256Hex(text)
        self.url = url
        self.threadPartitionID = threadPartitionID
    }
}

public struct SnapshotDocument: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var ownerID: String
    public var groupID: String
    public var groupLabel: String
    /// Milliseconds since 1970, as the lane reports it; 0 when unknown.
    public var createdAt: Int64
    public var mediaType: String
    public var partitions: [SnapshotPartition]

    public init(id: String, name: String, ownerID: String, groupID: String, groupLabel: String, createdAt: Int64, mediaType: String,
                partitions: [SnapshotPartition]) {
        self.id = id
        self.name = name
        self.ownerID = ownerID
        self.groupID = groupID
        self.groupLabel = groupLabel
        self.createdAt = createdAt
        self.mediaType = mediaType
        self.partitions = partitions
    }

    public var text: String { partitions.map(\.text).joined(separator: "\n\n") }
}

public struct CorpusSnapshot: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var corpusHash: String
    public var slug: String?
    /// `aii:<aii>/<lane>`, `app:<aii>/<app>`, `dataset:<name>#<node>`, `dir:<path>`.
    public var source: String
    public var threadID: String?
    public var owner: String
    /// The group exported; empty for an app's records, which span every group of the app's owner.
    public var group: String
    public var documentIDPrefix: String
    public var exportedAt: Date
    public var documentCount: Int
    public var partitionCount: Int
    /// Sorted by document id (ExportCorpus order).
    public var documents: [SnapshotDocument]

    public init(documents: [SnapshotDocument], slug: String?, source: String, threadID: String?, owner: String, group: String,
                documentIDPrefix: String, exportedAt: Date = Date()) {
        let sorted = documents.sorted { $0.id < $1.id }
        schemaVersion = 1
        self.documents = sorted
        self.slug = slug
        self.source = source
        self.threadID = threadID
        self.owner = owner
        self.group = group
        self.documentIDPrefix = documentIDPrefix
        self.exportedAt = exportedAt
        documentCount = sorted.count
        partitionCount = sorted.reduce(0) { $0 + $1.partitions.count }
        corpusHash = ContentHash.corpusHash(sorted.flatMap { document in
            document.partitions.map { ContentHash.CorpusEntry(documentID: document.id, partitionIndex: $0.index, textSHA256: $0.textSHA256) }
        })
    }

    /// A snapshot built straight from a corpus, without a lane: dataset nodes and directories.
    public static func offline(_ corpus: GeneratedCorpus, source: String, owner: String = "offline", group: String = "offline",
                               createdAt: (CorpusDocument) -> Int64 = { _ in 0 }) -> CorpusSnapshot {
        let documents = corpus.documents.map { document in
            SnapshotDocument(id: document.id, name: document.name, ownerID: owner, groupID: group, groupLabel: group,
                             createdAt: createdAt(document), mediaType: "text",
                             partitions: document.partitions.map { SnapshotPartition(index: $0.index, text: $0.text, url: $0.url) })
        }
        let prefix = corpus.documents.first.map { id -> String in
            // The ids' common `<scheme>-<slug>-` prefix, whatever generator wrote them.
            let parts = id.id.split(separator: "-")
            return parts.count >= 3 ? parts.dropLast().joined(separator: "-") + "-" : ""
        } ?? ""
        return CorpusSnapshot(documents: documents, slug: corpus.manifest.slug, source: source, threadID: nil, owner: owner, group: group,
                              documentIDPrefix: prefix, exportedAt: Date(timeIntervalSince1970: 0))
    }

    public func document(id: String) -> SnapshotDocument? { documents.first { $0.id == id } }

    /// What changed since `previous`, keyed by (document id, partition index, text SHA-256).
    /// Nil `previous` means everything was added.
    public func changes(since previous: CorpusSnapshot?) -> SnapshotChange {
        func table(_ snapshot: CorpusSnapshot?) -> [String: String] {
            var result: [String: String] = [:]
            for document in snapshot?.documents ?? [] {
                for partition in document.partitions { result["\(document.id)#\(partition.index)"] = partition.textSHA256 }
            }
            return result
        }
        let now = table(self)
        let before = table(previous)
        let documentsNow = Set(documents.map(\.id))
        let documentsBefore = Set(previous?.documents.map(\.id) ?? [])
        return SnapshotChange(
            added: now.keys.filter { before[$0] == nil }.sorted(),
            removed: before.keys.filter { now[$0] == nil }.sorted(),
            changed: now.keys.filter { before[$0] != nil && before[$0] != now[$0] }.sorted(),
            addedDocuments: documentsNow.subtracting(documentsBefore).sorted(),
            removedDocuments: documentsBefore.subtracting(documentsNow).sorted())
    }

    public static let fileName = "snapshot.json"

    public func save(to directory: URL) throws { try JSONCoding.write(self, to: directory.appendingPathComponent(Self.fileName)) }

    public static func load(from directory: URL) throws -> CorpusSnapshot {
        let url = directory.lastPathComponent.hasSuffix(".json") ? directory : directory.appendingPathComponent(fileName)
        return try JSONCoding.read(CorpusSnapshot.self, from: url)
    }
}

/// The partitions (as `documentID#index`) and documents one snapshot adds, removes or changes
/// relative to another.
public struct SnapshotChange: Codable, Sendable, Equatable {
    public var added: [String]
    public var removed: [String]
    public var changed: [String]
    public var addedDocuments: [String]
    public var removedDocuments: [String]

    public init(added: [String] = [], removed: [String] = [], changed: [String] = [], addedDocuments: [String] = [], removedDocuments: [String] = []) {
        self.added = added
        self.removed = removed
        self.changed = changed
        self.addedDocuments = addedDocuments
        self.removedDocuments = removedDocuments
    }

    public var isEmpty: Bool { added.isEmpty && removed.isEmpty && changed.isEmpty }
    /// `+8 −2 ~1` in partitions.
    public var summary: String { "+\(added.count) −\(removed.count) ~\(changed.count)" }
}
