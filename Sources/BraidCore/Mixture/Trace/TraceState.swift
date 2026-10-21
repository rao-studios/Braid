//
//  TraceState.swift
//  BraidCore
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: A node's trace at one position, as the tracker reports it and the session log records
//        it: the longest live chain's length and trace, the entry it sits on, the token it
//        expects, and the longest run inside one partition.
//

import Foundation

/// A node's trace at one position: the longest live chain and where it sits.
public struct TraceState: Codable, Sendable, Equatable {
    /// Tokens the longest live chain has followed through one document, bridged runs included.
    public var length: Int
    public var trace: Float
    /// The chain's entry now (it expects the next token), the position of that entry's context,
    /// and the token it expects. Nil without a chain.
    public var entry: Int32?
    public var row: Int32?
    public var offset: Int32?
    public var next: Int32?
    /// The longest run that stayed inside one partition (reported beside the document-bounded chain).
    public var partitionRun: Int

    public init(length: Int, trace: Float, entry: Int32? = nil, row: Int32? = nil, offset: Int32? = nil, next: Int32? = nil, partitionRun: Int = 0) {
        self.length = length
        self.trace = trace
        self.entry = entry
        self.row = row
        self.offset = offset
        self.next = next
        self.partitionRun = partitionRun
    }

    enum CodingKeys: String, CodingKey { case length = "L", trace = "tr", entry = "e", row = "row", offset = "off", next = "nx", partitionRun = "pr" }
}
