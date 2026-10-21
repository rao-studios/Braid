//
//  SnapshotDiff.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: What changed between two snapshots of a Thread's source, by document id and the text
//        hashes of its partitions: the line `braid thread sync` prints when a source moved.
//

import BraidCore
import Foundation

/// What changed between two snapshots, by document id and partition text hash.
public struct SnapshotDiff: Sendable, Equatable {
    public var added: [String] = []
    public var removed: [String] = []
    public var changed: [String] = []
    public var isEmpty: Bool { added.isEmpty && removed.isEmpty && changed.isEmpty }
    public var summary: String { "\(added.count) added, \(removed.count) removed, \(changed.count) changed" }

    public init(from old: CorpusSnapshot, to new: CorpusSnapshot) {
        let before = Dictionary(old.documents.map { ($0.id, $0.partitions.sorted { $0.index < $1.index }.map(\.textSHA256)) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(new.documents.map { ($0.id, $0.partitions.sorted { $0.index < $1.index }.map(\.textSHA256)) }, uniquingKeysWith: { first, _ in first })
        added = after.keys.filter { before[$0] == nil }.sorted()
        removed = before.keys.filter { after[$0] == nil }.sorted()
        changed = after.keys.filter { before[$0] != nil && before[$0] != after[$0] }.sorted()
    }
}
