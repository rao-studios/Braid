//
//  TraceRule.swift
//  BraidCore
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The trace's constants, in tokens or steps: a chain of `phrase` tokens or fewer traces 0
//        (longer than 95% of the datasets' sentences), a chain of `arc` traces 1 (about half a
//        document), a bridge skips at most `bridge` tokens, `heads` chains are kept and `seeds`
//        hits may start one at each step. RaoLM's numbers, fixed before any numbers.
//

import Foundation

public struct TraceRule: Codable, Sendable, Equatable {
    public var phrase = 24
    public var arc = 96
    public var bridge = 8
    public var heads = 8
    public var seeds = 4

    public init() {}

    public static let standard = TraceRule()

    /// clamp((length − phrase) / (arc − phrase), 0, 1).
    public func trace(length: Int) -> Float {
        guard arc > phrase else { return length > phrase ? 1 : 0 }
        return min(max(Float(length - phrase) / Float(arc - phrase), 0), 1)
    }
}
