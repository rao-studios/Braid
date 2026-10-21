//
//  Hit.swift
//  BraidCore
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: One retrieved corpus position, as a node emits it beside its normed state: the index
//        entry, its cosine, the token that followed it, where that token sits and the loss of the
//        transition. The trace, the spans and the session log all read hits.
//  PIN:  Logged as `[entry, score, value, row, offset, loss]`.
//

import Foundation

/// One retrieved corpus position: the index entry, its cosine, the token that followed it, where
/// that token sits (the citation address, in the node's own partition table), and the eval loss
/// of the transition (citation confidence reads it).
public struct Hit: Codable, Sendable, Equatable {
    public var entry: Int32
    public var score: Float
    public var value: Int32
    public var row: Int32
    public var offset: Int32
    public var loss: Float

    public init(entry: Int32, score: Float, value: Int32, row: Int32, offset: Int32, loss: Float = 0) {
        self.entry = entry
        self.score = score
        self.value = value
        self.row = row
        self.offset = offset
        self.loss = loss
    }

    public var cited: TokenPosition { TokenPosition(row: Int(row), offset: Int(offset)) }

    enum CodingKeys: String, CodingKey { case entry = "e", score = "s", value = "v", row = "r", offset = "o", loss = "l" }

    /// Logged as a compact array `[entry, score, value, row, offset, loss]` (hits are most of a log's
    /// bytes); the object form `{"e":…,"s":…}` of the first logs is still read.
    public init(from decoder: Decoder) throws {
        if var array = try? decoder.unkeyedContainer() {
            entry = try array.decode(Int32.self)
            score = try array.decode(Float.self)
            value = try array.decode(Int32.self)
            row = try array.decode(Int32.self)
            offset = try array.decode(Int32.self)
            loss = try array.decode(Float.self)
        } else {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            entry = try c.decode(Int32.self, forKey: .entry)
            score = try c.decode(Float.self, forKey: .score)
            value = try c.decode(Int32.self, forKey: .value)
            row = try c.decode(Int32.self, forKey: .row)
            offset = try c.decode(Int32.self, forKey: .offset)
            loss = try c.decodeIfPresent(Float.self, forKey: .loss) ?? 0
        }
    }

    public func encode(to encoder: Encoder) throws {
        var array = encoder.unkeyedContainer()
        try array.encode(entry)
        try array.encode(score)
        try array.encode(value)
        try array.encode(row)
        try array.encode(offset)
        try array.encode(loss)
    }
}
