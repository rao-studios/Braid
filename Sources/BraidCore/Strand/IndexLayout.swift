//
//  IndexLayout.swift
//  BraidCore
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Where a node's index entries sit: its partition table (one row per partition, with the
//        document, the text hash and the Thread it lives on) and the layout the tracker and the
//        citations read (values, each entry's row and offset, the break length, shared n-grams).
//        Corpus positions order by (row, offset).
//

import Foundation

/// One row of the partition table an index was built over.
public struct PartitionRef: Codable, Sendable, Equatable {
    public var row: Int
    public var documentID: String
    public var documentName: String
    public var partitionIndex: Int
    public var partitionURL: String?
    public var textSHA256: String
    public var tokenCount: Int
    public var memorisedAtEpoch: Int?
    /// The Thread this partition lives on, when a table mixes Threads (the braid's global table).
    public var threadID: String?
    /// When its document was created in its lane, as the lane reports it (smaller is older). It
    /// breaks near-ties between tokens.
    public var createdAt: Int64?

    public init(row: Int, documentID: String, documentName: String, partitionIndex: Int, partitionURL: String? = nil, textSHA256: String,
                tokenCount: Int, memorisedAtEpoch: Int? = nil, threadID: String? = nil, createdAt: Int64? = nil) {
        self.row = row
        self.documentID = documentID
        self.documentName = documentName
        self.partitionIndex = partitionIndex
        self.partitionURL = partitionURL
        self.textSHA256 = textSHA256
        self.tokenCount = tokenCount
        self.memorisedAtEpoch = memorisedAtEpoch
        self.threadID = threadID
        self.createdAt = createdAt
    }

    public func address(offset: Int, threadID: String?) -> SourceAddress {
        SourceAddress(threadID: self.threadID ?? threadID, documentID: documentID, partitionIndex: partitionIndex, tokenOffset: offset, partitionURL: partitionURL)
    }
}

/// What the tracker and the citations need of a node's index: where every entry sits.
public struct IndexLayout: Sendable {
    public var values: [Int32]
    public var keyRow: [Int32]
    public var keyOffset: [Int32]
    public var partitions: [PartitionRef]
    public var breakLength: Int
    public var sharedNgrams: Set<UInt64>

    public init(values: [Int32], keyRow: [Int32], keyOffset: [Int32], partitions: [PartitionRef], breakLength: Int, sharedNgrams: Set<UInt64> = []) {
        self.values = values
        self.keyRow = keyRow
        self.keyOffset = keyOffset
        self.partitions = partitions
        self.breakLength = breakLength
        self.sharedNgrams = sharedNgrams
    }

    public var corpus: TraceCorpus { TraceCorpus(values: values, keyRow: keyRow, keyOffset: keyOffset, partitions: partitions, breakLength: breakLength) }
}

extension TokenPosition: Comparable {
    public static func < (lhs: TokenPosition, rhs: TokenPosition) -> Bool { (lhs.row, lhs.offset) < (rhs.row, rhs.offset) }
}
