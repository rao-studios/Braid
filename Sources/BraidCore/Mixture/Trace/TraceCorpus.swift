//
//  TraceCorpus.swift
//  BraidCore
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Where each index entry sits in its document: what the tracker needs of a node's index.
//        Built from the index's values, key rows and offsets and its partition table, with the
//        break tokens between partitions counted so positions run on across a break.
//  PIN:  Pure: no tensors. The successor of an entry is the next position of the same document.
//

import Foundation

public struct TraceCorpus: Sendable {
    /// Per entry: the token that followed its context (the index's value), where its context sits.
    public let values: [Int32]
    public let keyRow: [Int32]
    public let keyOffset: [Int32]
    /// Per entry: its document's ordinal and its context's token index in that document.
    public let documents: [Int32]
    public let positions: [Int32]
    /// Per document ordinal: its tokens, the sum of its partitions' token counts and the breaks between.
    public let lengths: [Int32]
    /// Per row: the partition's own token count (a position past it is a break token).
    public let rowTokenCount: [Int: Int]

    public init(values: [Int32], keyRow: [Int32], keyOffset: [Int32], partitions: [PartitionRef], breakLength: Int = 0) {
        precondition(values.count == keyRow.count && values.count == keyOffset.count)
        var ordinal: [String: Int32] = [:]
        var byDocument: [String: [PartitionRef]] = [:]
        for partition in partitions {
            if ordinal[partition.documentID] == nil { ordinal[partition.documentID] = Int32(ordinal.count) }
            byDocument[partition.documentID, default: []].append(partition)
        }
        var rowDocument: [Int: Int32] = [:]
        var rowStart: [Int: Int32] = [:]
        var rowTokenCount: [Int: Int] = [:]
        var lengths = [Int32](repeating: 0, count: ordinal.count)
        for (documentID, rows) in byDocument {
            let document = ordinal[documentID]!
            var start: Int32 = 0
            let ordered = rows.sorted { $0.partitionIndex < $1.partitionIndex }
            for (n, partition) in ordered.enumerated() {
                rowDocument[partition.row] = document
                rowStart[partition.row] = start
                rowTokenCount[partition.row] = partition.tokenCount
                start += Int32(partition.tokenCount)
                if n < ordered.count - 1 { start += Int32(breakLength) }
            }
            lengths[Int(document)] = start
        }
        self.values = values
        self.keyRow = keyRow
        self.keyOffset = keyOffset
        documents = keyRow.map { rowDocument[Int($0)] ?? -1 }
        positions = zip(keyRow, keyOffset).map { row, offset in (rowStart[Int(row)] ?? 0) + offset }
        self.lengths = lengths
        self.rowTokenCount = rowTokenCount
    }

    public var count: Int { values.count }

    /// The entry of the next position of the same document, if the index holds it.
    public func successor(of entry: Int) -> Int? {
        let next = entry + 1
        guard entry >= 0, next < count, documents[next] == documents[entry], documents[entry] >= 0, positions[next] == positions[entry] + 1 else { return nil }
        return next
    }

    public func position(of entry: Int) -> TokenPosition { TokenPosition(row: Int(keyRow[entry]), offset: Int(keyOffset[entry])) }

    /// Whether two entries sit in the same partition (the partition-bounded run).
    public func samePartition(_ a: Int, _ b: Int) -> Bool { keyRow[a] == keyRow[b] }
}
