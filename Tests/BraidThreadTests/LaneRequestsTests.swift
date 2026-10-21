//
//  LaneRequestsTests.swift
//  BraidThreadTests
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: What a deposit sends, without a Thread: every document under the braid owner and the
//        slug's group (mandatory, or ExportCorpus never returns it), exactly one tag, partitions in
//        index order with their URLs, batches that cover every document once; and an empty remove
//        is refused before anything is sent (AII's Remove with an empty list removes everything).
//        What an export asks for: Braid's own group, or every group of an app's owner under the
//        app's id prefix; a record read back keeps its own urls but not the Thread's storage address.
//

import AII
import BraidCore
import Foundation
import Seam
import Testing
@testable import BraidThread

@Suite("Lane requests")
struct LaneRequestsTests {
    static func document(_ id: String, texts: [String]) -> SnapshotDocument {
        SnapshotDocument(id: id, name: "Doc \(id)", ownerID: "braid", groupID: "braid-veil", groupLabel: "", createdAt: 0, mediaType: "text",
                         partitions: texts.enumerated().reversed().map { SnapshotPartition(index: $0.offset, text: $0.element) })
    }

    @Test("an index request files every document under the owner and the slug's group, with one tag and ordered partitions")
    func indexRequest() {
        let address = LaneAddress(aii: "demo-a", lane: .veil)
        let docs = [Self.document("braid-x-1", texts: ["first.", "second."]), Self.document("braid-x-2", texts: ["only."])]
        let request = LaneClient.indexRequest(docs[...], slug: "veil", address: address)
        #expect(request.ownerID == "braid")
        #expect(request.groupID == "braid-veil" && !request.groupID.isEmpty)
        #expect(request.items.count == 2)
        #expect(request.items.allSatisfy { $0.tags == ["braid:veil"] && $0.mediaType == "text" })
        #expect(request.items[0].texts == ["first.", "second."], "partitions in index order")
        #expect(request.items[0].partitions.map(\.url) == [
            DocumentID.partitionURL(aii: "demo-a", lane: "veil", documentID: "braid-x-1", index: 0),
            DocumentID.partitionURL(aii: "demo-a", lane: "veil", documentID: "braid-x-1", index: 1),
        ])
    }

    @Test("batches cover every document exactly once", arguments: [(0, 16), (1, 16), (16, 16), (17, 16), (40, 7)])
    func batches(count: Int, size: Int) {
        let ranges = LaneClient.batches(count, size: size)
        #expect(ranges.allSatisfy { $0.count <= size && !$0.isEmpty })
        #expect(ranges.flatMap { Array($0) } == Array(0 ..< count))
    }

    @Test("an empty remove is refused before anything is sent")
    func emptyRemove() async {
        let endpoint = LaneEndpoint(address: LaneAddress(aii: "nowhere", lane: .veil), home: URL(fileURLWithPath: "/nonexistent"), httpPort: 1, grpcPort: 1)
        let client = LaneClient(endpoint: endpoint, secret: "")
        await #expect(throws: LaneError.self) { try await client.remove(ids: []) }
        await #expect(throws: LaneError.self) { try await client.remove(ids: [], owner: "local-notes") }
    }

    @Test("Braid's export asks for its own group as before; an app's asks for every group of the app's owner under its prefix")
    func exportRequests() throws {
        var before = Thread_V1_ThreadExportCorpusRequest()
        before.ownerID = "braid"
        before.groupIds = ["braid-veil"]
        before.afterID = "braid-x-1"
        before.limit = 100
        before.includeEmbeddings = true
        let braid = LaneClient.exportRequest(owner: LaneClient.owner, groups: [LaneClient.group(slug: "veil")], after: "braid-x-1", limit: LaneClient.pageSize)
        #expect(braid == before, "no prefix is sent: the request is the one Braid always sent")
        #expect(try braid.serializedData() == before.serializedData())
        let app = LaneClient.exportRequest(owner: "local-notes", groups: [], prefix: LaneClient.recordPrefix("notes"), after: "", limit: LaneClient.recordsPageSize)
        #expect(app.ownerID == "local-notes" && app.groupIds.isEmpty && app.documentIDPrefix == "notes/")
        #expect(app.limit == 25 && app.includeEmbeddings && app.afterID.isEmpty)
    }

    @Test("a record read back keeps its own urls and partition ids, but not the Thread's storage address")
    func recordDocument() {
        var content = Thread_V1_ThreadDocumentContent()
        content.id = "notes/note/a"
        content.name = "A note"
        content.ownerID = "local-notes"
        content.groupID = "notes-notes"
        content.texts = ["first.", "second."]
        var stored = Thread_V1_ThreadPartitionOutput()
        stored.id = "p0"
        stored.url = "file:///Users/x/.rao/aii/thread/db/documents/notes/note/a"
        var own = Thread_V1_ThreadPartitionOutput()
        own.id = "p1"
        own.url = "https://example.org/a#1"
        content.partitions = [stored, own]
        let record = LaneClient.recordDocument(content)
        #expect(record.id == "notes/note/a" && record.name == "A note" && record.ownerID == "local-notes" && record.groupID == "notes-notes")
        #expect(record.partitions.map(\.text) == ["first.", "second."])
        #expect(record.partitions.map(\.url) == [nil, "https://example.org/a#1"])
        #expect(record.partitions.map(\.threadPartitionID) == ["p0", "p1"])
        #expect(LaneClient.snapshotDocument(content).partitions[0].url == stored.url, "Braid's own documents keep every url, as before")
    }

    @Test("an empty lane is refused in today's words; an empty app says it has filed nothing")
    func emptyRefusals() {
        let veil = LaneAddress(aii: "demo-a", lane: .veil)
        #expect("\(LaneSource.emptyRefusal(.braid(veil)))" == "demo-a/veil holds no Braid documents\n  braid aii ingest demo-a/veil --from dataset:<name>#<node>")
        #expect("\(LaneSource.emptyRefusal(.app(LaneAddress(aii: "home", lane: "notes"))))".hasPrefix("notes has filed no records in home/notes"))
    }

    @Test("an app's records are read under the owner its lane names: local-<app>, or aii-local once it opts in")
    func owners() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("braid-owner-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = AIIHome(root: root.appendingPathComponent("t", isDirectory: true))
        _ = try home.provision(by: .ambient)
        try home.register("notes")
        let notes = LaneAddress(aii: "t", lane: "notes")
        #expect(LaneHomes.owner(for: notes, demoRoot: root) == "local-notes")
        try home.setOwner(.local, for: "notes")
        #expect(LaneHomes.owner(for: notes, demoRoot: root) == "aii-local")
        #expect(LaneHomes.owner(for: LaneAddress(aii: "t", lane: "other"), demoRoot: root) == "local-other", "an app not yet registered")
        #expect(LaneSource.owner(of: .braid(notes), demoRoot: root) == "braid")
        #expect(LaneSource.owner(of: .app(notes), demoRoot: root) == "aii-local")
    }
}
