//
//  DocumentSegments.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Where one document's state-carrying segments end, before the index builder keys them.
//        Each segment ends on a partition's last token (before a break or the closing eos), at a
//        boundary the checkpoint policy picks; the last segment runs to the closing eos.
//  PIN:  Every segment but the last is followed by a checkpoint of the state after it.
//

import BraidCore
import Foundation

struct DocumentSegments {
    /// Each segment's stream positions, in order, from the opening eos to the closing one.
    var ranges: [ClosedRange<Int>]

    init(_ document: TokenizedDocument, corpus: TokenizedCorpus, policy: CheckpointPolicy) {
        let ends = Self.segmentEnds(at: Self.partitionEnds(of: document, corpus: corpus), policy: policy) + [document.tokens.count - 1]
        var start = 0
        ranges = ends.map { end in
            defer { start = end + 1 }
            return start ... end
        }
    }

    /// The last token index of each partition (before a break or the final eos).
    private static func partitionEnds(of document: TokenizedDocument, corpus: TokenizedCorpus) -> [Int] {
        var ends: [Int] = []
        var position = 1
        for (n, row) in document.rows.enumerated() {
            position += corpus.partitions[row].tokens.count
            ends.append(position - 1)
            if n < document.rows.count - 1 { position += corpus.breakLength }
        }
        return ends
    }

    /// The partition ends that close a segment: every one under `everyPartition`, else the first
    /// once `strideTokens` have passed since the last. A segment has no length cap; the builder runs
    /// a long one in pieces (`IndexBuildOptions.pieceTokens`), so its memory does not grow with it.
    private static func segmentEnds(at partitionEnds: [Int], policy: CheckpointPolicy) -> [Int] {
        var ends: [Int] = []
        var start = 0
        var sinceCheckpoint = 0
        for boundary in partitionEnds {
            sinceCheckpoint += boundary - start + 1
            if policy.everyPartition || sinceCheckpoint >= policy.strideTokens {
                ends.append(boundary)
                sinceCheckpoint = 0
            }
            start = boundary + 1
        }
        return ends
    }
}
