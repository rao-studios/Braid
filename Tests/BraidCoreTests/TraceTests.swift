//
//  TraceTests.swift
//  BraidCoreTests
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation
import Testing
@testable import BraidCore

@Suite("The trace")
struct TraceTests {
    /// One document of 150 tokens (100…249) in one partition, every position an entry.
    static func corpus() -> (TraceCorpus, [Int32]) {
        let tokens = (0..<150).map { Int32(100 + $0) }
        let entries = 0..<(tokens.count - 1)
        let corpus = TraceCorpus(values: entries.map { tokens[$0 + 1] }, keyRow: entries.map { _ in 0 }, keyOffset: entries.map { Int32($0) },
                                 partitions: [PartitionRef(row: 0, documentID: "d", documentName: "D", partitionIndex: 0, textSHA256: "s", tokenCount: tokens.count)])
        return (corpus, tokens)
    }

    static func hits(at position: Int) -> [Hit] { [Hit(entry: Int32(position), score: 0.95, value: Int32(100 + position + 1), row: 0, offset: Int32(position + 1))] }

    @Test("a text that walks the document in order traces 0 for 24 tokens, then rises to 1 by 96")
    func heldText() {
        let (corpus, tokens) = Self.corpus()
        var tracker = TraceTracker(corpus: corpus)
        var states: [TraceState] = []
        // Step j: the token at j arrived; this position's hits expect token j+1.
        for j in 0..<140 { states.append(tracker.step(token: tokens[j], hits: Self.hits(at: j))) }
        #expect(states[20].length == 20 && states[20].trace == 0)
        #expect(states[24].length == 24 && states[24].trace == 0)
        #expect(states[60].length == 60 && abs(states[60].trace - 0.5) < 1e-6)
        #expect(states[100].trace == 1)
        #expect(states[100].next == tokens[101] && states[100].partitionRun == 100)
        #expect(states[139].row == 0 && states[139].offset == 139)
    }

    @Test("shuffled tokens trace 0; a short gap is bridged, a long one is not")
    func shuffledAndBridged() {
        let (corpus, tokens) = Self.corpus()
        var shuffled = TraceTracker(corpus: corpus)
        var rng = SplitMix64(seed: 7)
        let order = (0..<140).shuffled(using: &rng)
        var longest = 0
        for j in order { longest = max(longest, shuffled.step(token: tokens[j], hits: Self.hits(at: j)).length) }
        #expect(longest < 24)
        // A changed token in the middle: the chain resumes and, once its run reaches 8, inherits the earlier mass.
        var bridged = TraceTracker(corpus: corpus)
        var lengths: [Int] = []
        for j in 0..<60 {
            let token = j == 30 ? Int32(5) : tokens[j]
            lengths.append(bridged.step(token: token, hits: Self.hits(at: j)).length)
        }
        #expect(lengths[29] == 29 && lengths[31] <= 1)
        #expect(lengths[40] >= 38, "bridged length \(lengths[40])")
        #expect(lengths[59] >= 57)
    }

    @Test("wire lengths follow consecutive hits through one document")
    func audit() {
        let tokens: [Int32] = [100, 101, 102, 103, 104]
        let hits = (0..<5).map { Self.hits(at: $0) }
        let lengths = TraceAudit.wireLengths(tokens: tokens, hits: hits, documentOfRow: [0: "d"])
        #expect(lengths == [0, 1, 2, 3, 4])
    }
}
