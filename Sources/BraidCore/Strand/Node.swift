//
//  Node.swift
//  BraidCore
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The node protocol: what a Thread (or the commons) is to the cluster. A node emits a
//        normed state and its hits at every position, catches up on a prefix in one call, hands
//        out and takes back its history artifact (the recurrent state stack), and answers the
//        question path's context lookup. The protocol is the transfer logic over the wire; v1
//        implements it in process (BraidKit's LocalNode), later versions over a wire.
//  PIN:  The node's output boundary is a normalized state. The cluster runs the reed once per
//        node and computes H_lm, H_knn and the trace from what crosses, so every number in the
//        session log is a function of the log.
//

import Foundation

public enum NodeKind: String, Codable, Sendable { case thread, commons }

public struct NodeDescriptor: Codable, Sendable, Equatable {
    public var name: String
    public var label: String
    public var kind: NodeKind
    public var vocabularySHA256: String
    public var packSHA256: String?
    public var seamSHA256: String?
    public var hiddenSize: Int
    public var tokenizerSHA256: String
    public var indexSHA256: String?
    public var checkpointsSHA256: String?
    public var versionSHA256: String?
    public var corpusHash: String?
    public var threadID: String?
    public var lane: String?
    /// The strand's own λ scale (0 for the commons) and kNN temperature.
    public var lambdaScale: Float
    public var tau: Float

    public init(name: String, label: String? = nil, kind: NodeKind, vocabularySHA256: String, packSHA256: String?, seamSHA256: String? = nil,
                hiddenSize: Int, tokenizerSHA256: String, indexSHA256: String? = nil, checkpointsSHA256: String? = nil, versionSHA256: String? = nil,
                corpusHash: String? = nil, threadID: String? = nil, lane: String? = nil, lambdaScale: Float = 1, tau: Float = 0.05) {
        self.name = name
        self.label = label ?? name.prefix(1).uppercased() + name.dropFirst()
        self.kind = kind
        self.vocabularySHA256 = vocabularySHA256
        self.packSHA256 = packSHA256
        self.seamSHA256 = seamSHA256
        self.hiddenSize = hiddenSize
        self.tokenizerSHA256 = tokenizerSHA256
        self.indexSHA256 = indexSHA256
        self.checkpointsSHA256 = checkpointsSHA256
        self.versionSHA256 = versionSHA256
        self.corpusHash = corpusHash
        self.threadID = threadID
        self.lane = lane
        self.lambdaScale = kind == .commons ? 0 : lambdaScale
        self.tau = tau
    }

    public var isCommons: Bool { kind == .commons }
}

/// One position's emission: the normed state and the hits its key retrieved (expecting the next token).
public struct NodeStep: Sendable, Equatable {
    public var position: Int
    public var state: [Float]
    public var hits: [Hit]

    public init(position: Int, state: [Float], hits: [Hit]) {
        self.position = position
        self.state = state
        self.hits = hits
    }
}

/// The question path's context: the sentence before the node's best hit for a stem, from its own index.
public struct NodeContext: Sendable, Equatable {
    public var tokens: [Int32]
    public var score: Float
    public var documentID: String
    public var position: TokenPosition

    public init(tokens: [Int32], score: Float, documentID: String, position: TokenPosition) {
        self.tokens = tokens
        self.score = score
        self.documentID = documentID
        self.position = position
    }
}

/// The history artifact: a node's full recurrent state after a prefix, bound to that prefix.
public struct NodeCheckpoint: Codable, Sendable, Equatable {
    public var node: String
    public var position: Int
    public var prefixSHA256: String
    public var packSHA256: String?
    public var versionSHA256: String?
    /// The state stack, opaque to the cluster (safetensors bytes in BraidKit).
    public var bytes: Data
    public var sha256: String

    public init(node: String, position: Int, prefixSHA256: String, packSHA256: String?, versionSHA256: String?, bytes: Data) {
        self.node = node
        self.position = position
        self.prefixSHA256 = prefixSHA256
        self.packSHA256 = packSHA256
        self.versionSHA256 = versionSHA256
        self.bytes = bytes
        sha256 = ContentHash.sha256Hex(bytes)
    }

    /// sha256 of the consumed token ids as little-endian int32.
    public static func prefixHash(_ tokens: [Int32]) -> String {
        var data = Data(capacity: tokens.count * 4)
        for token in tokens { withUnsafeBytes(of: token.littleEndian) { data.append(contentsOf: $0) } }
        return ContentHash.sha256Hex(data)
    }
}

public typealias SessionID = String

public protocol Node: AnyObject {
    var descriptor: NodeDescriptor { get }
    /// The index layout (nil for the commons). Read once per version.
    func layout() throws -> IndexLayout?
    /// Opens a session on `tokens` (the eos opener included): one forward from a zero state,
    /// returning every position's emission. The catch-up when a node attaches mid-session.
    func open(session: SessionID, tokens: [Int32], k: Int) throws -> [NodeStep]
    func advance(session: SessionID, token: Int32, k: Int) throws -> NodeStep
    func context(stem: [Int32], subject: Range<Int>?, k: Int, floor: Float) throws -> NodeContext?
    func checkpoint(session: SessionID) throws -> NodeCheckpoint
    func restore(session: SessionID, checkpoint: NodeCheckpoint, tokens: [Int32]) throws
    func close(session: SessionID)
    func cancel()
}
