//
//  Reed.swift
//  BraidCore
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The two services a braid shares across its strands: the reed (logits from normed
//        states; BraidKit's runs on MLX, tests use a fake) and the tokenizer.
//

import Foundation

/// The reed: logits from normed states. BraidKit's reed runs on MLX; tests use a fake.
public protocol Reed: Sendable {
    var vocabulary: Int { get }
    var vocabularySHA256: String { get }
    var hiddenSize: Int { get }
    func logits(_ states: [[Float]]) throws -> [[Float]]
}

public protocol Tokenizing: Sendable {
    var eos: Int32 { get }
    var sha256: String { get }
    func encode(_ text: String) -> [Int32]
    func decode(_ tokens: [Int32]) -> String
    /// The token's own text, as it decodes alone (its leading space included).
    func text(_ token: Int32) -> String
}
