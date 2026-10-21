//
//  LaneClient.swift
//  BraidThread
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Braid's client for one lane of an AII Thread over the direct gRPC port, presenting the
//        lane's secret: health, stats, export (paged), the deposit of documents (one tag so no
//        extraction runs, the caller's ids and partition urls, a mandatory group), removal by id,
//        and single-document reads for the verifier. One short-lived connection per call. Besides
//        Braid's own corpus (owner `braid`), it exports the records the lane's app filed itself
//        (`exportRecords`: the app's owner, all its groups, ids under `<app>/`).
//  PIN:  Index replies before anything is persisted, so `waitUntilIndexed` polls the exported ids.
//        ExportCorpus walks only the owner's groups in the caller's lane. An empty remove list
//        would remove everything: refused.
//

import AII
import BraidCore
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import Seam

public struct LaneStats: Sendable, Equatable {
    public var documents: Int
    public var groups: Int
    public var owners: Int
}

public struct LaneHealth: Sendable, Equatable {
    public var status: String
    public var stack: String?
    public var contract: Int?
    public var embedderPhase: String?
}

public enum LaneError: Error, CustomStringConvertible {
    case notReachable(String, String)
    case rejected(String)
    case timeout(missing: [String])
    case emptyRemove

    public var description: String {
        switch self {
        case .notReachable(let endpoint, let why): return "\(endpoint) is not reachable: \(why)"
        case .rejected(let why): return "the lane rejected the request: \(why)"
        case .timeout(let missing): return "the lane did not index \(missing.count) document(s) in time: \(missing.prefix(3).joined(separator: ", "))"
        case .emptyRemove: return "an empty remove list would remove everything; refused"
        }
    }
}

public actor LaneClient {
    public nonisolated let endpoint: LaneEndpoint
    private let secret: String
    /// The owner every Braid document is filed under, and the group per corpus slug.
    public static let owner = "braid"
    public static func group(slug: String) -> String { "braid-\(slug)" }
    public static let pageSize = 100

    public init(endpoint: LaneEndpoint, secret: String) {
        self.endpoint = endpoint
        self.secret = secret
    }

    private func withClient<R: Sendable>(_ body: (GRPCClient<HTTP2ClientTransport.Posix>) async throws -> R) async throws -> R {
        do {
            let transport = try HTTP2ClientTransport.Posix.http2NIOPosix(target: .ipv4(host: endpoint.host, port: endpoint.grpcPort), transportSecurity: .plaintext)
            let interceptor = StackSecretClientInterceptor(secret: secret)
            return try await withGRPCClient(transport: transport, interceptors: [interceptor]) { client in try await body(client) }
        } catch let error as RPCError where error.code == .unavailable {
            throw LaneError.notReachable(endpoint.description, error.message)
        } catch let error as RPCError where error.code == .unauthenticated || error.code == .permissionDenied {
            throw LaneError.rejected(error.message)
        }
    }

    private func options(seconds: Int64) -> CallOptions {
        var options = CallOptions.defaults
        options.timeout = .seconds(seconds)
        options.maxRequestMessageBytes = 16 << 20
        options.maxResponseMessageBytes = 16 << 20
        return options
    }

    // MARK: Health and stats

    public nonisolated func health(timeout: TimeInterval = 3) async throws -> LaneHealth {
        var request = URLRequest(url: endpoint.healthURL)
        request.timeoutInterval = timeout
        request.setValue("braid", forHTTPHeaderField: "X-AII-App")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LaneError.notReachable(endpoint.description, "health returned \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        return LaneHealth(status: object["status"] as? String ?? "?", stack: object["stack"] as? String, contract: object["contract"] as? Int,
                          embedderPhase: (object["embedder"] as? [String: Any])?["phase"] as? String)
    }

    public func stats() async throws -> LaneStats {
        let options = options(seconds: 10)
        let response = try await withClient { client in
            try await Thread_V1_ThreadUpdate.Client(wrapping: client).stats(Thread_V1_ThreadStatsRequest(), options: options)
        }
        return LaneStats(documents: Int(response.documentCount), groups: Int(response.groupCount), owners: Int(response.ownerCount))
    }

    // MARK: Deposit

    /// The batches a deposit of `count` documents is sent in.
    public static func batches(_ count: Int, size: Int) -> [Range<Int>] {
        let size = max(1, size)
        return stride(from: 0, to: count, by: size).map { $0 ..< min($0 + size, count) }
    }

    /// One Index request: every document filed under the `braid` owner and the slug's group (a group
    /// is mandatory: ExportCorpus exports only groups the owner holds), one tag (so the Thread skips
    /// graph extraction), partitions in order with their URLs.
    public static func indexRequest(_ documents: ArraySlice<SnapshotDocument>, slug: String, address: LaneAddress) -> Thread_V1_ThreadIndexRequest {
        var request = Thread_V1_ThreadIndexRequest()
        request.ownerID = owner
        request.groupID = group(slug: slug)
        request.groupLabel = "Braid · \(slug)"
        request.scope = ""
        request.items = documents.map { document in
            var item = Thread_V1_ThreadIndexItem()
            item.documentID = document.id
            item.name = document.name
            let ordered = document.partitions.sorted { $0.index < $1.index }
            item.texts = ordered.map(\.text)
            item.tags = ["braid:\(slug)"]
            item.mediaType = "text"
            item.partitions = ordered.map { partition in
                var input = Thread_V1_ThreadPartitionInput()
                input.url = partition.url ?? DocumentID.partitionURL(aii: address.aii, lane: address.lane.rawValue, documentID: document.id, index: partition.index)
                return input
            }
            return item
        }
        return request
    }

    /// Deposits documents under the lane's `braid` owner and the slug's group, in batches; waits until every id is exported.
    public func deposit(_ documents: [SnapshotDocument], slug: String, batchSize: Int = 16, timeout: TimeInterval = 600, progress: (@Sendable (Int, Int) -> Void)? = nil) async throws {
        var done = 0
        let options = options(seconds: 600)
        for range in Self.batches(documents.count, size: batchSize) {
            let request = Self.indexRequest(documents[range], slug: slug, address: endpoint.address)
            var attempt = 0
            while true {
                do {
                    let response = try await withClient { client in try await Thread_V1_ThreadQuery.Client(wrapping: client).index(request, options: options) }
                    guard response.success else { throw LaneError.rejected("success=false for a batch of \(request.items.count)") }
                    break
                } catch let error as RPCError where error.code == .unavailable && attempt < 60 {
                    // The embedder is still loading: wait and retry.
                    attempt += 1
                    _ = error
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } catch let error as RPCError where error.code == .invalidArgument || error.code == .failedPrecondition {
                    throw LaneError.rejected(error.message)
                }
            }
            done += range.count
            progress?(done, documents.count)
        }
        try await waitUntilIndexed(expected: Set(documents.map(\.id)), slug: slug, timeout: timeout)
    }

    public func exportedIDs(slug: String) async throws -> Set<String> {
        var ids = Set<String>()
        var after = ""
        while true {
            let page = try await exportPage(Self.exportRequest(owner: Self.owner, groups: [Self.group(slug: slug)], after: after, limit: 500))
            for document in page.documents { ids.insert(document.id) }
            guard page.hasMore_p, let last = page.documents.last else { break }
            after = last.id
        }
        return ids
    }

    public func waitUntilIndexed(expected: Set<String>, slug: String, timeout: TimeInterval = 300, poll: TimeInterval = 0.5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var missing = expected
        while Date() < deadline {
            missing = expected.subtracting(try await exportedIDs(slug: slug))
            if missing.isEmpty { return }
            try await Task.sleep(nanoseconds: UInt64(poll * 1_000_000_000))
        }
        throw LaneError.timeout(missing: missing.sorted())
    }

    // MARK: Export

    /// Records are exported in small pages: each carries its aii-record/1 envelope, up to 1 MB.
    public static let recordsPageSize = 25

    /// The id prefix of every record an app files: `<app>/<kind>/<id>`.
    public static func recordPrefix(_ app: AIIApp) -> String { "\(app.rawValue)/" }

    /// One page of ExportCorpus: the owner's documents in the caller's lane, in the groups named
    /// (none: every group the owner holds there), whose ids start with `prefix`, after `after`.
    /// The Thread describes each partition (its id and URL) only alongside embeddings; Braid never
    /// supplies vectors at index time, so the descriptions come back without any.
    public static func exportRequest(owner: String, groups: [String], prefix: String = "", after: String, limit: Int) -> Thread_V1_ThreadExportCorpusRequest {
        var request = Thread_V1_ThreadExportCorpusRequest()
        request.ownerID = owner
        request.groupIds = groups
        request.documentIDPrefix = prefix
        request.afterID = after
        request.limit = Int32(limit)
        request.includeEmbeddings = true
        return request
    }

    private func exportPage(_ request: Thread_V1_ThreadExportCorpusRequest) async throws -> Thread_V1_ThreadExportCorpusResponse {
        let options = options(seconds: 120)
        return try await withClient { client in try await Thread_V1_ThreadLibrary.Client(wrapping: client).exportCorpus(request, options: options) }
    }

    /// Every page of an export, documents in id order.
    private func exportAll(owner: String, groups: [String], prefix: String = "", pageSize: Int) async throws -> [Thread_V1_ThreadDocumentContent] {
        var documents: [Thread_V1_ThreadDocumentContent] = []
        var after = ""
        while true {
            let page = try await exportPage(Self.exportRequest(owner: owner, groups: groups, prefix: prefix, after: after, limit: pageSize))
            documents.append(contentsOf: page.documents)
            guard page.hasMore_p, let last = page.documents.last else { break }
            after = last.id
        }
        return documents
    }

    /// The whole corpus of the slug's group, exactly as the lane stores it.
    public func exportCorpus(slug: String) async throws -> CorpusSnapshot {
        let documents = try await exportAll(owner: Self.owner, groups: [Self.group(slug: slug)], pageSize: Self.pageSize).map(Self.snapshotDocument)
        let prefix = documents.first.map { id -> String in
            let parts = id.id.split(separator: "-")
            return parts.count >= 3 ? parts.dropLast().joined(separator: "-") + "-" : ""
        } ?? ""
        return CorpusSnapshot(documents: documents, slug: slug, source: "aii:\(endpoint.address)", threadID: nil, owner: Self.owner, group: Self.group(slug: slug), documentIDPrefix: prefix)
    }

    /// Every record the lane's app filed under `owner`, in all of the owner's groups in this lane,
    /// as a snapshot (source `app:<aii>/<app>`, group empty for every group).
    public func exportRecords(app: AIIApp, owner: String) async throws -> CorpusSnapshot {
        let prefix = Self.recordPrefix(app)
        let documents = try await exportAll(owner: owner, groups: [], prefix: prefix, pageSize: Self.recordsPageSize).map(Self.recordDocument)
        return CorpusSnapshot(documents: documents, slug: app.rawValue, source: "\(LaneCorpus.app(endpoint.address))", threadID: nil, owner: owner, group: "",
                              documentIDPrefix: prefix)
    }

    public func documents(ids: [String], owner: String = LaneClient.owner) async throws -> [SnapshotDocument] {
        guard !ids.isEmpty else { return [] }
        var request = Thread_V1_ThreadDocumentsRequest()
        request.ownerID = owner
        request.documentIds = ids
        request.includeEmbeddings = true
        let options = options(seconds: 60)
        let response = try await withClient { client in try await Thread_V1_ThreadLibrary.Client(wrapping: client).documents(request, options: options) }
        return response.documents.map(owner == Self.owner ? Self.snapshotDocument : Self.recordDocument)
    }

    @discardableResult
    public func remove(ids: [String], owner: String = LaneClient.owner) async throws -> Int {
        guard !ids.isEmpty else { throw LaneError.emptyRemove }
        var request = Thread_V1_ThreadRemoveRequest()
        request.ownerID = owner
        request.documentIds = ids
        let options = options(seconds: 60)
        let response = try await withClient { client in try await Thread_V1_ThreadQuery.Client(wrapping: client).remove(request, options: options) }
        return Int(response.removedCount)
    }

    static func snapshotDocument(_ content: Thread_V1_ThreadDocumentContent) -> SnapshotDocument {
        let described = content.partitions.count == content.texts.count
        let partitions = content.texts.enumerated().map { index, text in
            SnapshotPartition(index: index, text: text, url: described ? content.partitions[index].url : nil, threadPartitionID: described ? content.partitions[index].id : nil)
        }
        return SnapshotDocument(id: content.id, name: content.name, ownerID: content.ownerID, groupID: content.groupID, groupLabel: content.groupLabel,
                                createdAt: content.createdAt, mediaType: content.mediaType, partitions: partitions)
    }

    /// An app's record as a snapshot document: as `snapshotDocument`, except that a partition with no
    /// url of its own, which the Thread describes by its storage address (`file:…/documents/<id>`),
    /// has none (AII's own rule for a record read back).
    static func recordDocument(_ content: Thread_V1_ThreadDocumentContent) -> SnapshotDocument {
        var document = snapshotDocument(content)
        let storage = "/documents/\(content.id)"
        for i in document.partitions.indices {
            if let url = document.partitions[i].url, url.hasPrefix("file:"), url.hasSuffix(storage) { document.partitions[i].url = nil }
        }
        return document
    }
}

/// Reads live partition texts from a lane for the verifier, caching documents.
public actor LaneReader {
    private let client: LaneClient
    private let owner: String
    private var cache: [String: [String]] = [:]

    /// `owner`: whose documents these are (Braid's own corpus, or the lane app's records).
    public init(client: LaneClient, owner: String = LaneClient.owner) {
        self.client = client
        self.owner = owner
    }

    public func partitionText(documentID: String, partitionIndex: Int) async throws -> String? {
        if cache[documentID] == nil {
            let documents = try await client.documents(ids: [documentID], owner: owner)
            cache[documentID] = documents.first?.partitions.sorted { $0.index < $1.index }.map(\.text) ?? []
        }
        guard let partitions = cache[documentID], partitions.indices.contains(partitionIndex) else { return nil }
        return partitions[partitionIndex]
    }
}
