//
//  TraceTracker.swift
//  BraidCore
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Follows one text through one node's corpus, a position at a time: whether the text
//        follows one document the node holds, in order, for longer than a sentence. Retrieval only
//        seeds a chain; a chain advances only when the token that arrives is the corpus's next
//        token, so no score from one node's key space enters it. Manner is gone; the trace is
//        instrumentation that the log can replay exactly.
//  PIN:  RaoLM's tracker, step for step (the 0.938 was measured with it): heads extend on the
//        arrived token and move to the successor; a run of `bridge` tokens inherits a dormant
//        chain of the same document that ended at most `bridge` tokens before, in the text and in
//        the corpus; the top `seeds` hits start chains; `heads` live chains are kept; dormant
//        chains expire after 2·bridge steps. Chains are document-bounded (they run across the
//        break tokens between partitions); the longest run inside one partition is reported too.
//

import Foundation

public struct TraceTracker: Sendable {
    struct Head {
        var entry: Int
        var document: Int32
        var mass: Int
        var run: Int
        var start: Int
        var startPosition: Int32
        var ended = 0
        var endPosition: Int32 = 0
        /// Tokens matched without leaving the partition the run began in.
        var partitionRun: Int = 0
        var partitionRow: Int32
    }

    public let corpus: TraceCorpus
    public let rule: TraceRule
    private var live: [Head] = []
    private var fresh: [Head] = []
    private var dormant: [Head] = []
    private var steps = 0

    public init(corpus: TraceCorpus, rule: TraceRule = .standard) {
        self.corpus = corpus
        self.rule = rule
    }

    /// One position: `token` is the token at this position (the one the previous position's hits
    /// expected), `hits` what this position's key retrieved (they expect the next token).
    public mutating func step(token: Int32, hits: [Hit]) -> TraceState {
        let step = steps
        steps += 1
        var moved: [Head] = []
        var finished: [Head] = []
        for var head in live + fresh {
            guard head.entry < corpus.count else { continue }
            if corpus.values[head.entry] == token {
                head.mass += 1
                head.run += 1
                head.partitionRun = corpus.keyRow[head.entry] == head.partitionRow ? head.partitionRun + 1 : 1
                if corpus.keyRow[head.entry] != head.partitionRow { head.partitionRow = corpus.keyRow[head.entry] }
                if head.run == rule.bridge { bridge(&head) }
                if let next = corpus.successor(of: head.entry) {
                    head.entry = next
                    moved.append(head)
                } else {
                    head.ended = step + 1
                    head.endPosition = corpus.positions[head.entry] + 1
                    dormant.append(head)
                    finished.append(head)
                }
            } else if head.run > 0 {
                head.ended = step
                head.endPosition = corpus.positions[head.entry]
                dormant.append(head)
            }
        }
        var byEntry: [Int: Head] = [:]
        for head in moved where (byEntry[head.entry]?.mass ?? -1) < head.mass { byEntry[head.entry] = head }
        live = Array(byEntry.values.sorted { $0.mass != $1.mass ? $0.mass > $1.mass : $0.entry < $1.entry }.prefix(rule.heads))

        let sitting = Set(live.map(\.entry))
        fresh = hits.prefix(rule.seeds).compactMap { hit in
            let entry = Int(hit.entry)
            guard entry >= 0, entry < corpus.count, !sitting.contains(entry) else { return nil }
            return Head(entry: entry, document: corpus.documents[entry], mass: 0, run: 0, start: step + 1, startPosition: corpus.positions[entry],
                        partitionRow: corpus.keyRow[entry])
        }
        dormant = Array(dormant.filter { step - $0.ended <= 2 * rule.bridge }
            .sorted { $0.mass != $1.mass ? $0.mass > $1.mass : $0.entry < $1.entry }.prefix(2 * rule.heads))

        let best = live.first
        let length = max(best?.mass ?? 0, finished.map(\.mass).max() ?? 0)
        let chain = best.flatMap { $0.mass == length ? $0 : nil }
        let partitionRun = max(live.map(\.partitionRun).max() ?? 0, finished.map(\.partitionRun).max() ?? 0)
        return TraceState(length: length, trace: rule.trace(length: length), entry: chain.map { Int32($0.entry) },
                          row: chain.map { corpus.keyRow[$0.entry] }, offset: chain.map { corpus.keyOffset[$0.entry] },
                          next: chain.map { corpus.values[$0.entry] }, partitionRun: partitionRun)
    }

    private mutating func bridge(_ head: inout Head) {
        let candidates = dormant.indices.filter { i in
            let d = dormant[i]
            let text = head.start - d.ended
            let corpus = Int(head.startPosition - d.endPosition)
            return d.document == head.document && d.run >= rule.bridge && (0...rule.bridge).contains(text) && (0...rule.bridge).contains(corpus)
        }
        guard let pick = candidates.max(by: { dormant[$0].mass < dormant[$1].mass }) else { return }
        head.mass += dormant[pick].mass
        dormant.remove(at: pick)
    }
}
