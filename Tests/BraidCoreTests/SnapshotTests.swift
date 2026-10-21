//
//  SnapshotTests.swift
//  BraidCoreTests
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation
import Testing
@testable import BraidCore

@Suite("Corpus snapshots")
struct SnapshotTests {
    static func corpus() -> GeneratedCorpus {
        let documents = [
            CorpusDocument(id: "braid-t-" + String(repeating: "a", count: 24), name: "A", kind: "note", subject: "a",
                           partitions: [CorpusPartition(index: 0, text: "First.", url: "u0"), CorpusPartition(index: 1, text: "Second.", url: "u1")], facts: []),
            CorpusDocument(id: "braid-t-" + String(repeating: "b", count: 24), name: "B", kind: "note", subject: "b",
                           partitions: [CorpusPartition(index: 0, text: "Third.", url: "u2")], facts: []),
        ]
        let manifest = CorpusManifest(schemaVersion: 1, slug: "t", generator: "test", generatorVersion: 1, seed: 1, documentCount: 2, partitionCount: 3,
                                      factCount: 0, chunkMaxChars: 600, chunkMinChars: 120, documentIDs: documents.map(\.id), corpusHash: "")
        return GeneratedCorpus(manifest: manifest, documents: documents)
    }

    @Test func offlineSnapshotHashesLikeTheCorpus() {
        let corpus = Self.corpus()
        let snapshot = CorpusSnapshot.offline(corpus, source: "dir:test")
        #expect(snapshot.documentCount == 2 && snapshot.partitionCount == 3)
        #expect(snapshot.corpusHash == corpus.recomputedCorpusHash)
        #expect(snapshot.documentIDPrefix == "braid-t-")
        #expect(snapshot.documents.map(\.id) == corpus.documents.map(\.id).sorted())
    }

    @Test func changes() {
        let corpus = Self.corpus()
        let before = CorpusSnapshot.offline(corpus, source: "dir:test")
        var edited = corpus
        edited.documents[0].partitions[1].text = "Second, edited."
        edited.documents.removeLast()
        let after = CorpusSnapshot.offline(edited, source: "dir:test")
        let change = after.changes(since: before)
        #expect(change.changed == ["\(corpus.documents[0].id)#1"])
        #expect(change.removed == ["\(corpus.documents[1].id)#0"])
        #expect(change.removedDocuments == [corpus.documents[1].id])
        #expect(change.added.isEmpty && change.summary == "+0 −1 ~1")
        #expect(after.changes(since: nil).added.count == 2)
    }

    @Test func roundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("braid-snapshot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = CorpusSnapshot.offline(Self.corpus(), source: "dir:test")
        try snapshot.save(to: directory)
        #expect(try CorpusSnapshot.load(from: directory) == snapshot)
    }
}
