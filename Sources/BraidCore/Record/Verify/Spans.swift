//
//  Spans.swift
//  BraidCore
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Turns a generation's per-position hits into citations: groups each token's matching hits
//        by partition, scores them, and finds verbatim spans — runs of emitted tokens that walk
//        one partition position by position. A derived view over the session log; nothing here
//        is stored per token.
//  PIN:  RaoLM's rules: a hit matches when its value is the token that was chosen; a span needs at
//        least three tokens, each with a matching hit of rank ≤ 3 at (row, offset + t); overlaps
//        are resolved greedily (longest, then heaviest), the losers kept as alternatives; break
//        positions (past a partition's own tokens) are never cited. Confidence is
//        (simTerm(best cosine) · support · e^{−loss})^{1/3}: evidence of memorisation and retrieval
//        support, not an influence certificate.
//

import Foundation

public enum CitationMath {
    /// Cosine 0.5 → 0, cosine 1.0 → 1.
    public static func simTerm(_ score: Float) -> Float { min(max((score - 0.5) / 0.5, 0), 1) }

    public static func confidence(score: Float, support: Float, sourceLoss: Float) -> Float {
        let product = simTerm(score) * min(max(support, 0), 1) * exp(-max(sourceLoss, 0))
        return product > 0 ? Float(pow(Double(product), 1.0 / 3.0)) : 0
    }
}

/// Retrieval support for one emitted token, grouped by partition (global rows).
public struct Citation: Codable, Sendable, Equatable {
    public var row: Int
    public var address: SourceAddress
    /// Σ weight of the matching hits in this partition (each hit's softmax weight times its strand's w′).
    public var weight: Float
    public var bestRank: Int
    public var bestScore: Float
    public var sourceLoss: Float
    public var confidence: Float
}

public struct SpanAlternative: Codable, Sendable, Equatable {
    public var row: Int
    public var source: SourceAddress
    public var length: Int
    public var cumulativeWeight: Float
}

public enum VerificationStatus: String, Codable, Sendable {
    case verified, stale, mismatch, tokenizerDrift, missing, unverified
}

public struct SpanVerification: Codable, Sendable, Equatable {
    public var status: VerificationStatus
    public var liveTextSHA256: String?
    public var detail: String?

    public init(status: VerificationStatus, liveTextSHA256: String? = nil, detail: String? = nil) {
        self.status = status
        self.liveTextSHA256 = liveTextSHA256
        self.detail = detail
    }
}

public struct TokenRange: Codable, Sendable, Equatable {
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }

    public var count: Int { end - start }
}

/// A run of emitted tokens that reproduces a corpus partition verbatim, token by token.
public struct CitedSpan: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case verbatim, promptVerbatim }

    public var kind: Kind
    /// Positions in prompt ++ generated, half-open.
    public var tokenRange: TokenRange
    public var promptTokens: Int
    public var tokens: [Int32]
    public var text: String
    public var row: Int
    public var source: SourceAddress
    public var documentName: String
    public var textSHA256: String
    public var ranks: [Int]
    public var weights: [Float]
    /// Weakest-link confidence over the span's tokens.
    public var confidence: Float
    public var meanConfidence: Float
    /// 1 − (token 3-grams shared by ≥ 2 documents) / (token 3-grams). 0 means boilerplate.
    public var distinctiveness: Float
    public var alternatives: [SpanAlternative]
    public var verification: SpanVerification?
}

/// Per position, the citations found and the span the token belongs to.
public struct SpanAnnotation: Sendable, Equatable {
    public var citations: [Citation]
    public var confidence: Float?
    public var spanIndex: Int?
    public var uncited: Bool { citations.isEmpty }
}

/// One matching hit in the braid's global row space, as the span finder sees it.
struct GlobalHit {
    var strand: Int
    var rank: Int
    var score: Float
    var weight: Float
    var value: Int32
    var cited: TokenPosition
    var loss: Float
}

public enum Spans {
    public struct Settings: Sendable {
        public var rankThreshold = 3
        public var minSpanLength = 3
        public var maxCitations = 3
        public var maxAlternatives = 5
        public init() {}
    }

    /// Token 3-grams packed into one integer (token ids are below 2^20).
    public static func ngramKey(_ a: Int32, _ b: Int32, _ c: Int32) -> UInt64 {
        (UInt64(UInt32(bitPattern: a) & 0xFFFFF) << 40) | (UInt64(UInt32(bitPattern: b) & 0xFFFFF) << 20) | UInt64(UInt32(bitPattern: c) & 0xFFFFF)
    }

    public static func distinctiveness(tokens: [Int32], sharedNgrams: Set<UInt64>) -> Float {
        guard tokens.count >= 3 else { return 0 }
        var shared = 0
        for i in 0...(tokens.count - 3) where sharedNgrams.contains(ngramKey(tokens[i], tokens[i + 1], tokens[i + 2])) { shared += 1 }
        return 1 - Float(shared) / Float(tokens.count - 2)
    }

    static func isBreak(_ position: TokenPosition, _ partitions: [Int: PartitionRef]) -> Bool {
        guard let partition = partitions[position.row] else { return false }
        return position.offset >= partition.tokenCount
    }

    /// Every strand's hits at a step in the global row space, weighted by the strand's w′ and its
    /// own softmax over its hits (the mass the mixture gave each). The step's own slots map strand
    /// t's node-local rows onto the global table.
    static func globalHits(_ step: Step, slots: [StrandSlot]) -> [GlobalHit] {
        guard let threads = step.threads else { return [] }
        var hits: [GlobalHit] = []
        for (t, record) in threads.enumerated() where t < slots.count {
            let weights = Mixer.weights(record.hits.map { Double($0.score) }, tau: slots[t].tau)
            for (i, hit) in record.hits.enumerated() {
                hits.append(GlobalHit(strand: t, rank: i + 1, score: hit.score, weight: Float(Double(record.weight) * weights[i]), value: hit.value,
                                      cited: TokenPosition(row: slots[t].rowOffset + Int(hit.row), offset: Int(hit.offset)), loss: hit.loss))
            }
        }
        return hits
    }

    /// Every partition the token's matching hits come from, strongest first.
    static func groupedCitations(_ hits: [GlobalHit], token: Int32, partitions: [Int: PartitionRef], threadID: String?) -> [Citation] {
        var groups: [Int: (weight: Float, best: GlobalHit)] = [:]
        for hit in hits where hit.value == token && !isBreak(hit.cited, partitions) {
            let row = hit.cited.row
            if let existing = groups[row] {
                let better = hit.score > existing.best.score || (hit.score == existing.best.score && hit.rank < existing.best.rank)
                groups[row] = (existing.weight + hit.weight, better ? hit : existing.best)
            } else {
                groups[row] = (hit.weight, hit)
            }
        }
        let citations: [Citation] = groups.compactMap { row, group in
            guard let partition = partitions[row] else { return nil }
            return Citation(row: row, address: partition.address(offset: group.best.cited.offset, threadID: threadID), weight: group.weight,
                            bestRank: group.best.rank, bestScore: group.best.score, sourceLoss: group.best.loss,
                            confidence: CitationMath.confidence(score: group.best.score, support: group.weight, sourceLoss: group.best.loss))
        }
        return citations.sorted {
            if $0.weight != $1.weight { return $0.weight > $1.weight }
            if $0.bestScore != $1.bestScore { return $0.bestScore > $1.bestScore }
            return $0.row < $1.row
        }
    }

    private struct Chain {
        var start: Int
        var length: Int
        var position: TokenPosition
        var ranks: [Int]
        var weights: [Float]
        var totalWeight: Float { weights.reduce(0, +) }
    }

    /// The same strands at every step.
    public static func annotate(steps: [Step], rowOffsets: [Int], taus: [Double], partitions: [Int: PartitionRef], sharedNgrams: Set<UInt64> = [],
                                threadID: String? = nil, settings: Settings = Settings()) -> (annotations: [SpanAnnotation], spans: [CitedSpan]) {
        let slots = StrandSlots.indexed(rowOffsets: rowOffsets, taus: taus)
        return annotate(steps: steps, slots: steps.map { _ in slots }, partitions: partitions, sharedNgrams: sharedNgrams, threadID: threadID, settings: settings)
    }

    /// Citations per step and the selected spans. `steps` are consecutive (step k has index
    /// `steps[0].index + k`); `slots[k]` names step k's strands (attach and detach move them);
    /// `partitions` is the braid's global table by row.
    public static func annotate(steps: [Step], slots: [[StrandSlot]], partitions: [Int: PartitionRef], sharedNgrams: Set<UInt64> = [],
                                threadID: String? = nil, settings: Settings = Settings()) -> (annotations: [SpanAnnotation], spans: [CitedSpan]) {
        let hits = steps.indices.map { k in globalHits(steps[k], slots: k < slots.count ? slots[k] : []) }
        var allCitations: [[Citation]] = []
        var annotations: [SpanAnnotation] = []
        for k in steps.indices {
            let grouped = groupedCitations(hits[k], token: steps[k].token, partitions: partitions, threadID: threadID)
            allCitations.append(grouped)
            annotations.append(SpanAnnotation(citations: Array(grouped.prefix(settings.maxCitations)), confidence: grouped.first?.confidence, spanIndex: nil))
        }
        var eligible: [[TokenPosition: (rank: Int, weight: Float)]] = steps.indices.map { k in
            var map: [TokenPosition: (rank: Int, weight: Float)] = [:]
            for hit in hits[k] where hit.value == steps[k].token && hit.rank <= settings.rankThreshold && !isBreak(hit.cited, partitions) {
                if let existing = map[hit.cited], existing.rank <= hit.rank { continue }
                map[hit.cited] = (hit.rank, hit.weight)
            }
            return map
        }
        var chains: [Chain] = []
        for k in steps.indices {
            for position in eligible[k].keys.sorted() {
                let previous = TokenPosition(row: position.row, offset: position.offset - 1)
                if k > 0, eligible[k - 1][previous] != nil { continue }
                var chain = Chain(start: k, length: 0, position: position, ranks: [], weights: [])
                while k + chain.length < steps.count, let info = eligible[k + chain.length][TokenPosition(row: position.row, offset: position.offset + chain.length)] {
                    chain.ranks.append(info.rank)
                    chain.weights.append(info.weight)
                    chain.length += 1
                }
                if chain.length >= settings.minSpanLength { chains.append(chain) }
            }
        }
        eligible.removeAll()
        func sortKey(_ chain: Chain) -> (Int, Float, String, Int, Int) {
            let partition = partitions[chain.position.row]
            return (chain.length, chain.totalWeight, partition?.documentID ?? "", partition?.partitionIndex ?? 0, chain.position.offset)
        }
        let ordered = chains.sorted { a, b in
            let ka = sortKey(a), kb = sortKey(b)
            if ka.0 != kb.0 { return ka.0 > kb.0 }
            if ka.1 != kb.1 { return ka.1 > kb.1 }
            if ka.2 != kb.2 { return ka.2 < kb.2 }
            if ka.3 != kb.3 { return ka.3 < kb.3 }
            return ka.4 < kb.4
        }
        var selected: [Chain] = []
        var alternatives: [[SpanAlternative]] = []
        for chain in ordered {
            let range = chain.start..<(chain.start + chain.length)
            if let owner = selected.firstIndex(where: { range.overlaps($0.start..<($0.start + $0.length)) }) {
                if alternatives[owner].count < settings.maxAlternatives, let partition = partitions[chain.position.row] {
                    alternatives[owner].append(SpanAlternative(row: chain.position.row, source: partition.address(offset: chain.position.offset, threadID: threadID),
                                                               length: chain.length, cumulativeWeight: chain.totalWeight))
                }
                continue
            }
            selected.append(chain)
            alternatives.append([])
        }
        let order = selected.indices.sorted { selected[$0].start < selected[$1].start }
        var spans: [CitedSpan] = []
        for index in order {
            let chain = selected[index]
            guard let partition = partitions[chain.position.row] else { continue }
            let members = Array(steps[chain.start..<(chain.start + chain.length)])
            let confidences = members.indices.map { t in allCitations[chain.start + t].first { $0.row == chain.position.row }?.confidence ?? Float(0) }
            let tokens = members.map(\.token)
            let promptTokens = members.filter(\.isPrompt).count
            let span = CitedSpan(kind: promptTokens == members.count ? .promptVerbatim : .verbatim,
                                 tokenRange: TokenRange(start: members[0].index, end: members[members.count - 1].index + 1), promptTokens: promptTokens,
                                 tokens: tokens, text: members.map(\.text).joined(), row: chain.position.row,
                                 source: partition.address(offset: chain.position.offset, threadID: threadID), documentName: partition.documentName,
                                 textSHA256: partition.textSHA256, ranks: chain.ranks, weights: chain.weights, confidence: confidences.min() ?? 0,
                                 meanConfidence: Stats.mean(confidences), distinctiveness: distinctiveness(tokens: tokens, sharedNgrams: sharedNgrams),
                                 alternatives: alternatives[index], verification: nil)
            let spanIndex = spans.count
            spans.append(span)
            for t in 0..<chain.length {
                let k = chain.start + t
                annotations[k].spanIndex = spanIndex
                if let own = allCitations[k].first(where: { $0.row == chain.position.row }) {
                    annotations[k].citations = Array(([own] + allCitations[k].filter { $0.row != chain.position.row }).prefix(settings.maxCitations))
                    annotations[k].confidence = own.confidence
                }
            }
        }
        return (annotations, spans)
    }
}
