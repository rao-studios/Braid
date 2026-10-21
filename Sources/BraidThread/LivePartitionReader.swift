//
//  LivePartitionReader.swift
//  BraidThread
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The verifier's reader for `braid verify --live`: a document held in an AII lane is re-read
//        from that lane as it stands now (so an edit or a removal since the session shows as stale or
//        missing), under the owner it was read with (Braid's corpus, or the lane app's records); any
//        other document is read from the fallback (the Thread's snapshot).
//

import BraidCore
import Foundation

public final class LivePartitionReader: PartitionReading, @unchecked Sendable {
    private let lanes: [String: LaneCorpus]
    private let demoRoot: URL
    private let fallback: PartitionReading?
    private var readers: [LaneCorpus: LaneReader] = [:]
    private let lock = NSLock()
    /// Every lane read so far.
    public private(set) var used: Set<LaneCorpus> = []

    /// `lanes` maps a document id to the lane that holds it.
    public init(lanes: [String: LaneCorpus], demoRoot: URL, fallback: PartitionReading?) {
        self.lanes = lanes
        self.demoRoot = demoRoot
        self.fallback = fallback
    }

    public func partitionText(documentID: String, partitionIndex: Int) throws -> String? {
        guard let corpus = lanes[documentID] else { return try fallback?.partitionText(documentID: documentID, partitionIndex: partitionIndex) }
        let reader = try reader(for: corpus)
        return try Blocking.run { try await reader.partitionText(documentID: documentID, partitionIndex: partitionIndex) }
    }

    private func reader(for corpus: LaneCorpus) throws -> LaneReader {
        lock.lock()
        defer { lock.unlock() }
        if let existing = readers[corpus] { return existing }
        let reader = LaneReader(client: try LaneSource.client(for: corpus.address, demoRoot: demoRoot), owner: LaneSource.owner(of: corpus, demoRoot: demoRoot))
        readers[corpus] = reader
        used.insert(corpus)
        return reader
    }

    /// Which lane holds each document a session's generations touched: a partition's Thread (by its
    /// thread id) names its lane in the session header or an attach line.
    public static func lanes(for session: LoggedSession) -> [String: LaneCorpus] {
        let threads = session.header.threads + session.membership.filter { $0.kind == "attach" }.map(\.thread)
        var laneOfThread: [String: LaneCorpus] = [:]
        for thread in threads {
            guard let id = thread.threadID, let lane = thread.lane, let corpus = LaneCorpus(recorded: lane) else { continue }
            laneOfThread[id] = corpus
        }
        var lanes: [String: LaneCorpus] = [:]
        for generation in session.generations {
            for partition in generation.end?.partitions ?? [] {
                guard let id = partition.threadID, let corpus = laneOfThread[id] else { continue }
                lanes[partition.documentID] = corpus
            }
        }
        return lanes
    }
}
