//
//  CorpusSources.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Where a Thread's documents come from, as `braid thread create --corpus` names them:
//        `dataset:<name or path>#<node>` (one node of a braid dataset on the T9, in feeding order,
//        optionally the first N), `dir:<path>` (a folder of .txt files, one document each, paragraphs
//        as partitions), `aii:<aii>/<lane>` (Braid's corpus deposited in a lane, exported through
//        BraidThread) and `app:<aii>/<app>` (the records an app filed in its own lane with
//        AIIInstance.remember). Each becomes a CorpusSnapshot; `read` is the one dispatch every
//        caller goes through.
//

import BraidCore
import BraidThread
import Foundation

public enum CorpusSourceSpec: Equatable, Sendable {
    case dataset(nameOrPath: String, node: String)
    case directory(URL)
    case lane(String)
    /// The records an app filed in its own lane: `home/notes`.
    case app(String)

    public init(parsing text: String) throws {
        if text.hasPrefix("dataset:") {
            let body = String(text.dropFirst(8))
            guard let hash = body.lastIndex(of: "#") else { throw BraidFailure.usage("dataset sources name a node: dataset:<name>#<node>") }
            self = .dataset(nameOrPath: String(body[..<hash]), node: String(body[body.index(after: hash)...]))
        } else if text.hasPrefix("dir:") {
            self = .directory(URL(fileURLWithPath: (String(text.dropFirst(4)) as NSString).expandingTildeInPath, isDirectory: true))
        } else if text.hasPrefix("aii:") {
            self = .lane(String(text.dropFirst(4)))
        } else if text.hasPrefix(LaneCorpus.appPrefix) {
            self = .app(String(text.dropFirst(LaneCorpus.appPrefix.count)))
        } else {
            throw BraidFailure.usage("unknown corpus source \(text)", hint: "use dataset:<name>#<node>, dir:<path>, aii:<aii>/<lane> or app:<aii>/<app>")
        }
    }

    public var description: String {
        switch self {
        case .dataset(let name, let node): return "dataset:\(name)#\(node)"
        case .directory(let url): return "dir:\(url.path)"
        case .lane(let lane): return "aii:\(lane)"
        case .app(let app): return LaneCorpus.appPrefix + app
        }
    }
}

/// A source as read: its snapshot, the dataset's facts (none for a folder or a lane), the lane a
/// Thread records when the source is one (`home/veil`, or `app:home/notes` for an app's records),
/// and why a Thread can't be made when a lane source turns out empty.
public struct SourceRead: Sendable {
    public var snapshot: CorpusSnapshot
    public var facts: [Fact]
    public var lane: String?
    public var whenEmpty: BraidFailure? = nil
}

public enum CorpusSources {
    /// Any source: a dataset node (its first `limit` documents in feeding order), a folder (its
    /// documents named under `slug`), Braid's corpus in a lane, or an app's records in its lane,
    /// exported from their AII.
    public static func read(_ spec: CorpusSourceSpec, slug: String, limit: Int?, datasetsRoot: URL?, demoRoot: URL) throws -> SourceRead {
        switch spec {
        case .dataset(let nameOrPath, let node):
            let (made, generated) = try snapshot(dataset: nameOrPath, node: node, limit: limit, datasetsRoot: datasetsRoot)
            return SourceRead(snapshot: made, facts: generated.facts, lane: nil)
        case .directory(let url):
            return SourceRead(snapshot: try snapshot(directory: url, slug: slug), facts: [], lane: nil)
        case .lane(let text):
            guard let address = LaneAddress(parsing: text) else { throw BraidFailure.usage("lane addresses are <aii>/<lane>: home or a demo AII, and a lane registered on it") }
            return SourceRead(snapshot: try LaneSource.snapshot(address: address, demoRoot: demoRoot), facts: [], lane: LaneCorpus.braid(address).description,
                              whenEmpty: LaneSource.emptyRefusal(.braid(address)))
        case .app(let text):
            guard let address = LaneAddress(parsing: text) else {
                throw BraidFailure.usage("app sources are app:<aii>/<app>: home or a demo AII, and an app registered on it (app:home/notes)")
            }
            return SourceRead(snapshot: try LaneSource.records(app: address, demoRoot: demoRoot), facts: [], lane: LaneCorpus.app(address).description,
                              whenEmpty: LaneSource.emptyRefusal(.app(address)))
        }
    }

    /// A dataset node's corpus as a snapshot: the first `limit` documents in feeding order.
    public static func snapshot(dataset nameOrPath: String, node: String, limit: Int?, datasetsRoot: URL?) throws -> (CorpusSnapshot, GeneratedCorpus) {
        let directory = try DatasetsRoot.locate(nameOrPath, root: datasetsRoot)
        let dataset = try BraidDataset.load(directory)
        var corpus = try dataset.corpus(node: node)
        if let limit { corpus.documents = Array(corpus.documents.prefix(limit)) }
        let name = directory.lastPathComponent
        let snapshot = CorpusSnapshot.offline(corpus, source: "dataset:\(name)#\(node)", owner: "braid", group: "braid-\(node)") { _ in 0 }
        return (snapshot, corpus)
    }

    /// A folder of .txt files: one document each, blank-line paragraphs as partitions.
    public static func snapshot(directory: URL, slug: String) throws -> CorpusSnapshot {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])
            .filter { $0.pathExtension == "txt" && !$0.lastPathComponent.hasPrefix("._") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { throw BraidFailure.missing("no .txt files in \(directory.path)") }
        var documents: [SnapshotDocument] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let canonical = ContentHash.canonical(text)
            let paragraphs = canonical.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard !paragraphs.isEmpty else { continue }
            let id = DocumentID.make(slug: slug, canonicalText: canonical)
            let created = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
            documents.append(SnapshotDocument(id: id, name: file.deletingPathExtension().lastPathComponent, ownerID: "braid", groupID: "braid-\(slug)", groupLabel: "Braid · \(slug)",
                                              createdAt: created, mediaType: "text",
                                              partitions: paragraphs.enumerated().map { SnapshotPartition(index: $0.offset, text: $0.element, url: DocumentID.partitionURL(aii: "dir", lane: slug, documentID: id, index: $0.offset)) }))
        }
        return CorpusSnapshot(documents: documents, slug: slug, source: "dir:\(directory.path)", threadID: nil, owner: "braid", group: "braid-\(slug)", documentIDPrefix: DocumentID.prefix(slug: slug))
    }
}
