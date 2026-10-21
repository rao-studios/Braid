//
//  LaneSource.swift
//  BraidThread
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: A lane as a corpus: export what Braid deposited there (owner `braid`, group `braid-<lane>`)
//        as a snapshot, deposit a corpus into it (ingest), remove what was deposited (wipe). The
//        slug of a lane's group is the lane's own name, so one lane holds one Braid corpus.
//

import AII
import BraidCore
import Foundation

public enum LaneSource {
    public static func client(for address: LaneAddress, demoRoot: URL) throws -> LaneClient {
        let endpoint = try LaneHomes.endpoint(for: address, demoRoot: demoRoot)
        let secret = try LaneHomes.secret(for: address, demoRoot: demoRoot)
        return LaneClient(endpoint: endpoint, secret: secret)
    }

    /// The lane's Braid corpus, exactly as the Thread stores it.
    public static func snapshot(address: LaneAddress, demoRoot: URL) throws -> CorpusSnapshot {
        let client = try client(for: address, demoRoot: demoRoot)
        return try Blocking.run { try await client.exportCorpus(slug: address.lane.rawValue) }
    }

    /// Deposits a snapshot's documents into the lane and waits until they are exported.
    public static func ingest(_ snapshot: CorpusSnapshot, into address: LaneAddress, demoRoot: URL, batchSize: Int = 16, progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) throws {
        let client = try client(for: address, demoRoot: demoRoot)
        let slug = address.lane.rawValue
        let documents = snapshot.documents.map { document -> SnapshotDocument in
            var copy = document
            copy.partitions = document.partitions.map { partition in
                var p = partition
                p.url = DocumentID.partitionURL(aii: address.aii, lane: slug, documentID: document.id, index: partition.index)
                return p
            }
            return copy
        }
        try Blocking.run { try await client.deposit(documents, slug: slug, batchSize: batchSize, progress: progress) }
    }

    /// Removes every Braid document of the lane; returns how many.
    public static func wipe(address: LaneAddress, demoRoot: URL) throws -> Int {
        let client = try client(for: address, demoRoot: demoRoot)
        return try Blocking.run {
            let ids = try await client.exportedIDs(slug: address.lane.rawValue)
            guard !ids.isEmpty else { return 0 }
            return try await client.remove(ids: ids.sorted())
        }
    }

    public static func stats(address: LaneAddress, demoRoot: URL) throws -> LaneStats {
        let client = try client(for: address, demoRoot: demoRoot)
        return try Blocking.run { try await client.stats() }
    }

    // MARK: An app's records

    /// Every record the lane's app filed there itself (with AIIInstance.remember): its owner's
    /// documents in all of the owner's groups in the lane, as the Thread stores them.
    public static func records(app address: LaneAddress, demoRoot: URL) throws -> CorpusSnapshot {
        let client = try client(for: address, demoRoot: demoRoot)
        let owner = LaneHomes.owner(for: address, demoRoot: demoRoot)
        return try Blocking.run { try await client.exportRecords(app: address.lane, owner: owner) }
    }

    /// The owner a lane corpus is read under: `braid` for Braid's own corpus, the app's for its records.
    public static func owner(of corpus: LaneCorpus, demoRoot: URL) -> String {
        switch corpus {
        case .braid: return LaneClient.owner
        case .app(let address): return LaneHomes.owner(for: address, demoRoot: demoRoot)
        }
    }

    /// Why no Thread can be made from an empty lane corpus.
    public static func emptyRefusal(_ corpus: LaneCorpus) -> BraidFailure {
        switch corpus {
        case .braid(let address):
            return BraidFailure.missing("\(address) holds no Braid documents", hint: "braid aii ingest \(address) --from dataset:<name>#<node>")
        case .app(let address):
            return BraidFailure.missing("\(address.lane.rawValue) has filed no records in \(address)",
                                        hint: "an app files records with AIIInstance.remember once it has joined that AII")
        }
    }
}
