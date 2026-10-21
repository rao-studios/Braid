//
//  TraceAudit.swift
//  BraidCore
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: What can be checked of a trace from the log alone: per position, the longest chain of
//        logged hits that follow one another through one document. The trace bench reads it.
//

import Foundation

/// What can be checked from the log alone.
public enum TraceAudit {
    /// Per position, the longest chain of hits that follow one another through one document:
    /// entry e at one position, e + 1 at the next, each expecting the token that came. Not a bound
    /// on a node's chain either way (it follows hits of any rank and never bridges).
    public static func wireLengths(tokens: [Int32], hits: [[Hit]], documentOfRow: [Int32: String]) -> [Int] {
        var lengths: [Int] = []
        var chains: [Int32: Int] = [:]
        for j in hits.indices {
            var next: [Int32: Int] = [:]
            if j > 0 {
                for hit in hits[j - 1] where hit.value == tokens[j] {
                    let before = hits.indices.contains(j - 2) ? hits[j - 2].first { $0.entry == hit.entry - 1 } : nil
                    let same = before.map { documentOfRow[$0.row] != nil && documentOfRow[$0.row] == documentOfRow[hit.row] } ?? false
                    next[hit.entry] = max(next[hit.entry] ?? 0, (same ? chains[hit.entry - 1] ?? 0 : 0) + 1)
                }
            }
            chains = next
            lengths.append(chains.values.max() ?? 0)
        }
        return lengths
    }
}
