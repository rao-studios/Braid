//
//  TokenizedCorpus.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: A snapshot tokenized the way the index and training read it: each partition on its own
//        (so a token offset can be recomputed from the partition's text alone), a document as
//        `eos ‖ p0 ‖ break ‖ p1 ‖ … ‖ eos`, and every stream position addressed by (row, offset).
//        Break tokens are addressed to the preceding partition at offsets tokenCount and above, so
//        chains run across them and nothing is ever cited to one.
//

import BraidCore
import Foundation

public struct TokenizedPartition: Sendable {
    public var row: Int
    public var ref: PartitionRef
    public var tokens: [Int32]
}

public struct TokenizedDocument: Sendable {
    public var documentID: String
    /// The partition rows in order.
    public var rows: [Int]
    /// eos ‖ p0 ‖ break ‖ p1 ‖ … ‖ eos.
    public var tokens: [Int32]
    /// Per stream position: the (row, offset) address; eos positions have row −1.
    public var addresses: [TokenPosition]
}

public struct TokenizedCorpus: Sendable {
    public var partitions: [TokenizedPartition]
    public var documents: [TokenizedDocument]
    public var eos: Int32
    public var paragraphBreak: [Int32]
    public var sharedNgrams: Set<UInt64>

    public var partitionRefs: [PartitionRef] { partitions.map(\.ref) }
    public var breakLength: Int { paragraphBreak.count }
    public var tokenCount: Int { documents.reduce(0) { $0 + $1.tokens.count } }

    /// Tokenizes every partition of the snapshot; documents in the snapshot's (sorted) order.
    public init(snapshot: CorpusSnapshot, tokenizer: any Tokenizing, paragraphBreak: [Int32], threadID: String?) {
        eos = tokenizer.eos
        self.paragraphBreak = paragraphBreak
        var partitions: [TokenizedPartition] = []
        var documents: [TokenizedDocument] = []
        var ngramCounts: [UInt64: Set<String>] = [:]
        for document in snapshot.documents {
            var rows: [Int] = []
            var tokens: [Int32] = [eos]
            var addresses: [TokenPosition] = [TokenPosition(row: -1, offset: 0)]
            let ordered = document.partitions.sorted { $0.index < $1.index }
            for (n, partition) in ordered.enumerated() {
                let row = partitions.count
                let ids = tokenizer.encode(partition.text)
                let ref = PartitionRef(row: row, documentID: document.id, documentName: document.name, partitionIndex: partition.index, partitionURL: partition.url,
                                       textSHA256: partition.textSHA256, tokenCount: ids.count, threadID: threadID, createdAt: document.createdAt == 0 ? nil : document.createdAt)
                partitions.append(TokenizedPartition(row: row, ref: ref, tokens: ids))
                rows.append(row)
                for (i, id) in ids.enumerated() {
                    tokens.append(id)
                    addresses.append(TokenPosition(row: row, offset: i))
                }
                if n < ordered.count - 1 {
                    for (j, id) in paragraphBreak.enumerated() {
                        tokens.append(id)
                        addresses.append(TokenPosition(row: row, offset: ids.count + j))
                    }
                }
                if ids.count >= 3 {
                    for i in 0...(ids.count - 3) { ngramCounts[Spans.ngramKey(ids[i], ids[i + 1], ids[i + 2]), default: []].insert(document.id) }
                }
            }
            tokens.append(eos)
            addresses.append(TokenPosition(row: -1, offset: 0))
            documents.append(TokenizedDocument(documentID: document.id, rows: rows, tokens: tokens, addresses: addresses))
        }
        self.partitions = partitions
        self.documents = documents
        sharedNgrams = Set(ngramCounts.filter { $0.value.count >= 2 }.keys)
    }

    public func row(documentID: String, partitionIndex: Int) -> Int? {
        partitions.first { $0.ref.documentID == documentID && $0.ref.partitionIndex == partitionIndex }?.row
    }

    public func document(ofRow row: Int) -> TokenizedDocument? { documents.first { $0.rows.contains(row) } }
}
