//
//  Fakes.swift
//  BraidCoreTests
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: A braid with no model: a tokenizer of 16 tokens, a reed whose logits are the states,
//        and nodes that "memorised" a few documents as bigrams. Enough for the gate, the mixer,
//        the trace, the spans, the credit, the session log and attach/detach to be exercised
//        exactly, with numbers a test can reason about.
//

import Foundation
@testable import BraidCore

struct FakeTokenizer: Tokenizing {
    static let texts = ["<eos>", " the", " cat", " sat", " on", " mat", ".", " dog", " ran", " far", " away", " Big", " birds", " fly", " high", " today"]
    var eos: Int32 { 0 }
    var sha256: String { "fake-tokenizer" }
    func encode(_ text: String) -> [Int32] {
        var tokens: [Int32] = []
        var rest = text[...]
        while !rest.isEmpty {
            guard let (i, t) = Self.texts.enumerated().filter({ !$0.element.isEmpty && rest.hasPrefix($0.element) }).max(by: { $0.element.count < $1.element.count }) else {
                rest = rest.dropFirst(); continue
            }
            tokens.append(Int32(i)); rest = rest.dropFirst(t.count)
        }
        return tokens
    }
    func decode(_ tokens: [Int32]) -> String { tokens.map { text($0) }.joined() }
    func text(_ token: Int32) -> String { Self.texts.indices.contains(Int(token)) ? Self.texts[Int(token)] : "<\(token)>" }
}

struct FakeReed: Reed {
    var vocabulary: Int { 16 }
    var vocabularySHA256: String { "fake-vocabulary" }
    var hiddenSize: Int { 16 }
    func logits(_ states: [[Float]]) throws -> [[Float]] { states }
}

/// A node that knows its documents as bigrams: its state puts +`sharpness` on every successor its
/// corpus gives the last token; its hits are the corpus positions whose token is the last token.
final class FakeNode: Node {
    let descriptor: NodeDescriptor
    let documents: [[Int32]]
    let sharpness: Float
    private var sessions: [SessionID: [Int32]] = [:]
    private(set) var advances = 0
    private(set) var opens = 0

    init(name: String, documents: [[Int32]], commons: Bool = false, sharpness: Float = 4, pack: String? = "fake-pack", vocabulary: String = "fake-vocabulary",
         hidden: Int = 16, tokenizer: String = "fake-tokenizer", createdAt: Int64? = nil) {
        descriptor = NodeDescriptor(name: name, kind: commons ? .commons : .thread, vocabularySHA256: vocabulary, packSHA256: pack, hiddenSize: hidden,
                                    tokenizerSHA256: tokenizer, indexSHA256: commons ? nil : "index-\(name)", threadID: commons ? nil : "thread-\(name)")
        self.documents = documents
        self.sharpness = sharpness
        self.createdAt = createdAt
    }

    let createdAt: Int64?

    /// Entry e covers (document d, position i) for every position but the last of each document.
    var entries: [(document: Int, position: Int)] {
        documents.enumerated().flatMap { d, doc in (0..<max(0, doc.count - 1)).map { (d, $0) } }
    }

    func layout() throws -> IndexLayout? {
        guard !descriptor.isCommons else { return nil }
        let entries = entries
        let partitions = documents.enumerated().map { d, doc in
            PartitionRef(row: d, documentID: "doc-\(descriptor.name)-\(d)", documentName: "D\(d)", partitionIndex: 0, textSHA256: ContentHash.sha256Hex(FakeTokenizer().decode(doc)), tokenCount: doc.count,
                         threadID: descriptor.threadID, createdAt: createdAt)
        }
        return IndexLayout(values: entries.map { documents[$0.document][$0.position + 1] }, keyRow: entries.map { Int32($0.document) },
                           keyOffset: entries.map { Int32($0.position) }, partitions: partitions, breakLength: 0)
    }

    private func emission(position: Int, tokens: [Int32], k: Int) -> NodeStep {
        let last = tokens[position]
        var state = [Float](repeating: 0, count: 16)
        var hits: [Hit] = []
        if !descriptor.isCommons {
            for (e, entry) in entries.enumerated() where documents[entry.document][entry.position] == last {
                let value = documents[entry.document][entry.position + 1]
                state[Int(value)] += sharpness
                // A hit that also matches the token before scores higher: a longer context.
                let longer = position > 0 && entry.position > 0 && documents[entry.document][entry.position - 1] == tokens[position - 1]
                hits.append(Hit(entry: Int32(e), score: longer ? 0.99 : 0.9, value: value, row: Int32(entry.document), offset: Int32(entry.position + 1), loss: 0.05))
            }
            hits.sort { $0.score != $1.score ? $0.score > $1.score : $0.entry < $1.entry }
            hits = Array(hits.prefix(k))
        } else {
            state[1] += 1  // the commons likes " the"
            state[6] += 0.5
        }
        return NodeStep(position: position, state: state, hits: hits)
    }

    func open(session: SessionID, tokens: [Int32], k: Int) throws -> [NodeStep] {
        opens += 1
        sessions[session] = tokens
        return tokens.indices.map { emission(position: $0, tokens: tokens, k: k) }
    }

    func advance(session: SessionID, token: Int32, k: Int) throws -> NodeStep {
        advances += 1
        var tokens = sessions[session] ?? []
        tokens.append(token)
        sessions[session] = tokens
        return emission(position: tokens.count - 1, tokens: tokens, k: k)
    }

    func context(stem: [Int32], subject: Range<Int>?, k: Int, floor: Float) throws -> NodeContext? { nil }

    func checkpoint(session: SessionID) throws -> NodeCheckpoint {
        let tokens = sessions[session] ?? []
        return NodeCheckpoint(node: descriptor.name, position: tokens.count - 1, prefixSHA256: NodeCheckpoint.prefixHash(tokens), packSHA256: descriptor.packSHA256,
                              versionSHA256: nil, bytes: Data(tokens.flatMap { withUnsafeBytes(of: $0.littleEndian, Array.init) }))
    }

    func restore(session: SessionID, checkpoint: NodeCheckpoint, tokens: [Int32]) throws {
        precondition(checkpoint.prefixSHA256 == NodeCheckpoint.prefixHash(tokens))
        sessions[session] = tokens
    }

    func close(session: SessionID) { sessions[session] = nil }
    func cancel() {}
}

enum Fixtures {
    static let catDocument: [Int32] = [1, 2, 3, 4, 1, 5, 6]            // the cat sat on the mat.
    static let dogDocument: [Int32] = [1, 7, 8, 9, 10, 6]              // the dog ran far away.
    static let birdDocument: [Int32] = [11, 12, 13, 14, 15, 6]         // Big birds fly high today.
    static let pack = PackIdentity(sha256: "fake-pack", name: "fake", vocabularySHA256: "fake-vocabulary", tokenizerSHA256: "fake-tokenizer", hiddenSize: 16, vocabulary: 16)

    static func cluster(settings: ClusterSettings = ClusterSettings()) -> Cluster {
        Cluster(reed: FakeReed(), tokenizer: FakeTokenizer(), pack: pack, settings: settings)
    }

    static func threeStrands(into cluster: Cluster) throws -> (a: FakeNode, b: FakeNode, commons: FakeNode) {
        let commons = FakeNode(name: "commons", documents: [], commons: true)
        let a = FakeNode(name: "a", documents: [catDocument], createdAt: 100)
        let b = FakeNode(name: "b", documents: [dogDocument, birdDocument], createdAt: 200)
        try cluster.attach(commons)
        try cluster.attach(a)
        try cluster.attach(b)
        return (a, b, commons)
    }
}
