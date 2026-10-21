//
//  LocalNode.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The Node protocol in process: a pack, a trunk (the commons runs the pack whole; a Thread runs
//        its own head, blocks 0..<cut, in front of the commons' tail), an index (none for the commons)
//        and the open sessions, each a recurrent state stack and the tokens it consumed. At every
//        position it emits the normed last state and the hits its key retrieved. The history artifact
//        is the state stack as safetensors.
//

import BraidCore
import Foundation
import MLX

public final class LocalNode: Node {
    public let descriptor: NodeDescriptor
    public let pack: Pack
    public let trunk: Trunk
    public let index: ProvenanceIndex?
    public let scheme: KeyScheme
    /// The tail this node's trunk lends (the commons') or borrows (a Thread's): blocks cut..<L, the
    /// embedding and the final norm, named by the seam.
    public var tail: Trunk.Tail { trunk.tail }

    private struct Session {
        var state: StateStack
        var tokens: [Int32]
    }

    private var sessions: [SessionID: Session] = [:]
    private var cancelled = false

    public init(name: String, label: String? = nil, pack: Pack, trunk: Trunk, index: ProvenanceIndex?, scheme: KeyScheme, threadID: String?, lane: String? = nil,
                versionSHA256: String? = nil, tau: Float = 0.05, lambdaScale: Float = 1) {
        self.pack = pack
        self.trunk = trunk
        self.index = index
        self.scheme = scheme
        descriptor = NodeDescriptor(name: name, label: label, kind: index == nil ? .commons : .thread, vocabularySHA256: pack.info.vocabularySHA256,
                                    packSHA256: pack.sha256, seamSHA256: trunk.seamSHA256, hiddenSize: pack.config.hiddenSize, tokenizerSHA256: pack.info.tokenizerSHA256,
                                    indexSHA256: index?.info.indexSHA256, checkpointsSHA256: index?.info.checkpointsSHA256, versionSHA256: versionSHA256,
                                    corpusHash: index?.info.corpusHash, threadID: threadID, lane: lane, lambdaScale: lambdaScale, tau: tau)
    }

    public func layout() throws -> IndexLayout? { index?.layout }

    private func hits(for keys: MLXArray, k: Int) -> [[Hit]] {
        guard let index, k > 0 else { return (0..<keys.dim(0)).map { _ in [] } }
        return index.query(keys, k: k)
    }

    public func open(session: SessionID, tokens: [Int32], k: Int) throws -> [NodeStep] {
        guard !tokens.isEmpty else { throw BraidFailure.usage("a session opens on at least the eos token") }
        if scheme.stateLayer != nil {
            // Pooled-state keys need the state at every position: step through the prefix.
            var state = StateStack.zeros(config: pack.config, batch: 1)
            var steps: [NodeStep] = []
            for (t, token) in tokens.enumerated() {
                let previous = state
                let out = trunk.step(token: MLXArray([token]), state: state, reset: nil, taps: scheme.taps)
                state = out.state
                let key = ProvenanceKey.make(mid: ProvenanceKey.mid(scheme: scheme, output: out, previousState: previous), final: out.final)
                steps.append(NodeStep(position: t, state: out.final[0].asArray(Float.self), hits: hits(for: key, k: k)[0]))
            }
            state.prefixSHA256 = NodeCheckpoint.prefixHash(tokens)
            sessions[session] = Session(state: state, tokens: tokens)
            return steps
        }
        let out = trunk.forward(tokens: MLXArray(tokens, [1, tokens.count]), state: nil, resets: nil, taps: scheme.taps)
        let final = out.final[0]                                                              // [L, D]
        let keys = ProvenanceKey.make(mid: ProvenanceKey.mid(scheme: scheme, output: out, previousState: nil)[0], final: final)
        eval(keys)
        let allHits = index == nil ? [] : hits(for: keys, k: k)
        let states = final.asArray(Float.self)
        let d = pack.config.hiddenSize
        var stack = out.state
        stack.prefixSHA256 = NodeCheckpoint.prefixHash(tokens)
        sessions[session] = Session(state: stack, tokens: tokens)
        return tokens.indices.map { t in
            NodeStep(position: t, state: Array(states[t * d ..< (t + 1) * d]), hits: allHits.isEmpty ? [] : allHits[t])
        }
    }

    public func advance(session: SessionID, token: Int32, k: Int) throws -> NodeStep {
        guard var current = sessions[session] else { throw BraidFailure.usage("session \(session) is not open on \(descriptor.name)") }
        let previous = current.state
        let out = trunk.step(token: MLXArray([token]), state: current.state, reset: nil, taps: scheme.taps)
        let key = ProvenanceKey.make(mid: ProvenanceKey.mid(scheme: scheme, output: out, previousState: previous), final: out.final)
        current.tokens.append(token)
        var stack = out.state
        stack.prefixSHA256 = NodeCheckpoint.prefixHash(current.tokens)
        current.state = stack
        sessions[session] = current
        return NodeStep(position: current.tokens.count - 1, state: out.final[0].asArray(Float.self), hits: hits(for: key, k: k)[0])
    }

    /// The question path's context, RaoLM's rule. The stem's template positions (after the subject;
    /// the whole stem when no subject is placed) are scored against the index; a hit counts when its
    /// score reaches `floor` and its document writes the subject's text somewhere. Behind the best such
    /// hit — the place where the Thread recognises the template inside a document about the subject —
    /// the context is the whole sentence before the hit's, read from the index's own values: what the
    /// corpus had before the fact, which is what the Thread memorised it with. Nil when no document
    /// both names the subject and writes the template, or the hit's sentence is the document's first.
    public func context(stem: [Int32], subject: Range<Int>?, k: Int, floor: Float) throws -> NodeContext? {
        try context(stem: stem, subject: subject, k: k, floor: floor, maxTokens: 48)
    }

    public func context(stem: [Int32], subject: Range<Int>?, k: Int, floor: Float, maxTokens: Int) throws -> NodeContext? {
        guard let index, !stem.isEmpty, let textOf, let decodeTokens else { return nil }
        let tokens: [Int32] = [tokenizerEOS] + stem
        let out = trunk.forward(tokens: MLXArray(tokens, [1, tokens.count]), state: nil, resets: nil, taps: scheme.taps)
        let keys = ProvenanceKey.make(mid: ProvenanceKey.mid(scheme: scheme, output: out, previousState: nil)[0], final: out.final[0])
        eval(keys)
        let hitsByStemPosition = index.query(keys[1...], k: k)                                     // [stem.count][k]
        let subjectRange = subject.map { $0.clamped(to: 0 ..< stem.count) } ?? 0 ..< stem.count
        // The subject as text: a sentence-initial name tokenises without the leading space the corpus
        // writes it with, so words are compared, not tokens.
        let subjectText = decodeTokens(Array(stem[subjectRange])).trimmingCharacters(in: .whitespaces)
        let template = subject == nil ? 0 ..< stem.count : subjectRange.upperBound ..< stem.count
        let positions = template.isEmpty ? subjectRange : template
        var best: (hit: Hit, position: Int)?
        var checked: [String: Bool] = [:]
        for j in positions where j < hitsByStemPosition.count {
            for hit in hitsByStemPosition[j] where hit.score >= floor && (best.map { hit.score > $0.hit.score } ?? true) {
                let entry = Int(hit.entry)
                guard let partition = index.partition(row: Int(index.keyRow[entry])), let range = index.entriesByDocument[partition.documentID] else { continue }
                if checked[partition.documentID] == nil {
                    checked[partition.documentID] = !subjectText.isEmpty && decodeTokens(Array(index.values[range])).contains(subjectText)
                }
                guard checked[partition.documentID] == true else { continue }
                best = (hit, j)
            }
        }
        guard let best else { return nil }
        // The hit's key sits in the fact's sentence. The context is the whole sentence before it, read
        // from the index's values (entry e's value is the document's token after its key).
        let entry = Int(best.hit.entry)
        let row = Int(index.keyRow[entry])
        guard let partition = index.partition(row: row), let range = index.entriesByDocument[partition.documentID] else { return nil }
        func endsSentence(_ e: Int) -> Bool {
            let text = textOf(index.values[e])
            return text.contains("\n") || text.last.map { ".?!".contains($0) } == true
        }
        // Back to the end of the sentence before the subject's. A paragraph break belongs to the
        // sentence it closes: when the hit's sentence opens a paragraph, the previous sentence is the
        // one before the break, and the break itself is not returned (the stem follows as a sentence
        // in the same paragraph, with its leading space).
        var e = entry - 1
        while e >= range.lowerBound, !endsSentence(e) { e -= 1 }
        guard e >= range.lowerBound else { return nil }
        var end = e
        while end >= range.lowerBound, textOf(index.values[end]).contains("\n") { end -= 1 }
        guard end >= range.lowerBound, endsSentence(end) else { return nil }
        // Then to the end of the sentence before that: the previous sentence is (start, end].
        e = end - 1
        var count = 0
        while e >= range.lowerBound, !endsSentence(e), count < maxTokens { e -= 1; count += 1 }
        let start = e + 1
        guard start <= end else { return nil }
        let context = Array(index.values[start ... end])
        guard !context.isEmpty, !textOf(context[0]).contains("\n") || context.count > 1 else { return nil }
        return NodeContext(tokens: context, score: best.hit.score, documentID: partition.documentID, position: TokenPosition(row: row, offset: Int(index.keyOffset[entry])))
    }

    // The tokenizer's services the context lookup needs, set by the store (the node protocol does not carry a tokenizer).
    public var tokenizerEOS: Int32 = 0
    public var textOf: ((Int32) -> String)?
    public var decodeTokens: (([Int32]) -> String)?

    public func checkpoint(session: SessionID) throws -> NodeCheckpoint {
        guard let current = sessions[session] else { throw BraidFailure.usage("session \(session) is not open on \(descriptor.name)") }
        return NodeCheckpoint(node: descriptor.name, position: current.tokens.count - 1, prefixSHA256: NodeCheckpoint.prefixHash(current.tokens),
                              packSHA256: pack.sha256, versionSHA256: descriptor.versionSHA256, bytes: try current.state.data(packSHA256: pack.sha256))
    }

    public func restore(session: SessionID, checkpoint: NodeCheckpoint, tokens: [Int32]) throws {
        guard checkpoint.prefixSHA256 == NodeCheckpoint.prefixHash(tokens) else { throw BraidFailure.data("the checkpoint is bound to another prefix") }
        guard checkpoint.packSHA256 == pack.sha256 else { throw BraidFailure.data("the checkpoint belongs to another pack") }
        var stack = try StateStack.from(data: checkpoint.bytes, expecting: pack.config)
        stack.position = tokens.count - 1
        stack.prefixSHA256 = checkpoint.prefixSHA256
        sessions[session] = Session(state: stack, tokens: tokens)
    }

    public func close(session: SessionID) { sessions[session] = nil }
    public func cancel() { cancelled = true }
}
