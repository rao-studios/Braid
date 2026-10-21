//
//  FactLocator.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: A dataset's facts placed on the tokenized corpus: each fact's byte offsets mapped onto its
//        partition's own tokens (the answer's first and last token, and where its context
//        sentence starts). Training scores facts through it; benches build prompts from it.
//

import BraidCore
import Foundation

/// A fact placed on its partition's own tokenization.
public struct LocatedFact: Sendable {
    public var fact: Fact
    public var row: Int
    /// First token of the sentence before the fact's sentence (or of the fact's sentence).
    public var contextToken: Int
    /// First answer token (the prompt ends just before it), and one past the last.
    public var answerToken: Int
    public var answerEndToken: Int

    public var answerLength: Int { answerEndToken - answerToken }
}

public enum FactLocator {
    /// Maps each fact's byte offsets onto its partition's own tokenization. Facts whose answer does
    /// not start on a token boundary come back in `unaligned`.
    public static func locate(_ facts: [Fact], corpus: TokenizedCorpus, byteOffsets: ([Int32]) -> [Int]) -> (located: [LocatedFact], unaligned: [String]) {
        var located: [LocatedFact] = []
        var unaligned: [String] = []
        var cache: [Int: [Int]] = [:]
        for fact in facts {
            guard let row = corpus.row(documentID: fact.documentID, partitionIndex: fact.partitionIndex) else { continue }
            let offsets: [Int]
            if let cached = cache[row] { offsets = cached } else {
                offsets = byteOffsets(corpus.partitions[row].tokens)
                cache[row] = offsets
            }
            guard let answerToken = offsets.firstIndex(of: fact.answerStart), let answerEnd = offsets.firstIndex(of: fact.answerEnd), answerEnd > answerToken, answerToken > 0 else {
                unaligned.append(fact.id)
                continue
            }
            let contextByte = max(fact.contextStart - 1, 0)
            let contextToken = fact.contextStart == 0 ? 0 : (offsets.lastIndex { $0 <= contextByte } ?? 0)
            located.append(LocatedFact(fact: fact, row: row, contextToken: min(contextToken, answerToken - 1), answerToken: answerToken, answerEndToken: answerEnd))
        }
        return (located, unaligned)
    }
}
