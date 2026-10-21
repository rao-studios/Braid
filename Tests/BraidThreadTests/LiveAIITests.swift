//
//  LiveAIITests.swift
//  BraidThreadTests
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Against the AIIs running on this machine (BRAID_AII_TESTS=1): the machine's AII is ours
//        (provisioned, three lanes, contract 1); every demo AII answers on its own ports; a scratch
//        corpus deposited into a demo lane exports byte-identical and is removed again; the demo
//        lane fed from braid-n3 exports the dataset's own texts.
//

import AII
import BraidCore
import Foundation
import Testing
@testable import BraidThread

let liveAII: Bool = ProcessInfo.processInfo.environment["BRAID_AII_TESTS"] == "1"

/// The repo's aii/ folder, found from this source file (the test binary lives under .build).
let testDemoRoot: URL = {
    if let override = ProcessInfo.processInfo.environment["BRAID_DEMO_HOMES"], !override.isEmpty { return URL(fileURLWithPath: override, isDirectory: true) }
    return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("aii", isDirectory: true)
}()

@Suite("Live AII", .enabled(if: liveAII), .serialized)
struct LiveAIITests {
    @Test("the machine's AII is ours: provisioned, three lanes, healthy, contract 1")
    func machineAII() async {
        let report = await AIIDetect.status(aii: LaneAddress.machine, demoRoot: testDemoRoot)
        #expect(report.provisioned, Comment(rawValue: report.problem ?? ""))
        #expect(report.layoutVersion == 1)
        #expect(Set(report.lanes) == ["ambient", "craft", "veil"])
        #expect(report.up, Comment(rawValue: report.problem ?? ""))
        #expect(report.health?.contract == AIIContract.version)
    }

    @Test("every demo AII answers on its own ports with the same contract")
    func demos() async throws {
        let names = AIIDetect.demos(demoRoot: testDemoRoot)
        try #require(!names.isEmpty, "no demo AII under \(testDemoRoot.path): braid aii create demo-a")
        var ports: Set<Int> = []
        let machine = await AIIDetect.status(aii: LaneAddress.machine, demoRoot: testDemoRoot)
        ports.insert(machine.httpPort)
        ports.insert(machine.grpcPort)
        for name in names {
            let report = await AIIDetect.status(aii: name, demoRoot: testDemoRoot)
            #expect(report.up, "\(name): \(report.problem ?? "down")")
            #expect(report.health?.contract == AIIContract.version)
            #expect(!ports.contains(report.httpPort) && !ports.contains(report.grpcPort), "\(name) shares a port")
            ports.insert(report.httpPort)
            ports.insert(report.grpcPort)
        }
    }

    @Test("a scratch corpus deposited into a demo lane exports byte-identical, then is removed")
    func roundTrip() async throws {
        let names = AIIDetect.demos(demoRoot: testDemoRoot)
        try #require(!names.isEmpty)
        let address = LaneAddress(aii: names[0], lane: .veil)
        let client = try LaneSource.client(for: address, demoRoot: testDemoRoot)
        let slug = "test-" + UUID().uuidString.prefix(8).lowercased()
        let texts = [["A scratch document about the braid.", "Its second partition."], ["Another, one partition long."], ["Third.", "With", "three partitions."]]
        let documents = texts.enumerated().map { i, parts in
            let id = DocumentID.make(slug: slug, canonicalText: parts.joined(separator: "\n\n") + "\(i)")
            return SnapshotDocument(id: id, name: "scratch \(i)", ownerID: LaneClient.owner, groupID: LaneClient.group(slug: slug), groupLabel: "", createdAt: 0, mediaType: "text",
                                    partitions: parts.enumerated().map { SnapshotPartition(index: $0.offset, text: $0.element) })
        }
        try await client.deposit(documents, slug: slug, batchSize: 2, timeout: 180)
        let exported = try await client.exportCorpus(slug: slug)
        #expect(exported.documents.count == documents.count)
        for document in documents {
            let found = exported.documents.first { $0.id == document.id }
            #expect(found?.partitions.map(\.text) == document.partitions.map(\.text), "\(document.id) round-trips byte for byte")
            #expect(found?.groupID == LaneClient.group(slug: slug) && found?.ownerID == LaneClient.owner)
            #expect(found?.partitions.allSatisfy { $0.url?.hasPrefix("braid://") == true } == true)
        }
        let removed = try await client.remove(ids: documents.map(\.id))
        #expect(removed == documents.count)
        // Removal is visible to the export (poll briefly: the Thread may persist after replying).
        var left = Set(documents.map(\.id))
        for _ in 0..<40 where !left.isEmpty {
            left = try await client.exportedIDs(slug: slug)
            if !left.isEmpty { try await Task.sleep(nanoseconds: 250_000_000) }
        }
        #expect(left.isEmpty, "removed documents are still exported: \(left)")
    }

    @Test("the demo lane fed from braid-n3 exports the dataset's own texts")
    func laneMatchesDataset() async throws {
        let names = AIIDetect.demos(demoRoot: testDemoRoot)
        guard let aii = names.first else { return }
        let address = LaneAddress(aii: aii, lane: .ambient)
        let client = try LaneSource.client(for: address, demoRoot: testDemoRoot)
        let exported = try await client.exportCorpus(slug: address.lane.rawValue)
        guard !exported.documents.isEmpty else { return }
        let root = try #require(DatasetsRoot.resolve(workArea: nil))
        let dataset = try BraidDataset.load(try DatasetsRoot.locate("braid-n3", root: root))
        let corpus = try dataset.corpus(node: "ambient")
        let byID = Dictionary(uniqueKeysWithValues: corpus.documents.map { ($0.id, $0) })
        var compared = 0
        for document in exported.documents {
            guard let source = byID[document.id] else { continue }
            #expect(document.partitions.map(\.text) == source.partitions.sorted { $0.index < $1.index }.map(\.text), "\(document.id)")
            compared += 1
        }
        #expect(compared == exported.documents.count, "every exported document is a braid-n3 ambient document")
        print("LIVE AII: \(compared) documents of \(address) equal braid-n3#ambient byte for byte")
    }
}
