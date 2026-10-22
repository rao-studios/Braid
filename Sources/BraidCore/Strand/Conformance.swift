//
//  Conformance.swift
//  BraidCore
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The checks every node passes before it joins a braid: the reed's vocabulary, its hidden
//        size, the braid's pack (the commons is exempt), the tokenizer, and the seam of the tail it
//        runs (the commons included: its tail is the one every Thread runs).
//

import Foundation

/// The checks every node passes before it joins a braid, exactly as RaoLM's umbrella applied them.
public enum Conformance {
    public enum Failure: Error, CustomStringConvertible, Equatable {
        case vocabulary(node: String, expected: String, found: String)
        case pack(node: String, expected: String, found: String?)
        case hiddenSize(node: String, expected: Int, found: Int)
        case tokenizer(node: String, expected: String, found: String)
        case seam(node: String, expected: String, found: String)

        public var description: String {
            switch self {
            case .vocabulary(let node, let expected, let found): return "\(node): vocabulary \(found.prefix(12)) is not the reed's \(expected.prefix(12))"
            case .pack(let node, let expected, let found): return "\(node): pack \(found?.prefix(12) ?? "none") is not the braid's \(expected.prefix(12))"
            case .hiddenSize(let node, let expected, let found): return "\(node): hidden size \(found) is not the reed's \(expected)"
            case .tokenizer(let node, let expected, let found): return "\(node): tokenizer \(found.prefix(12)) is not the braid's \(expected.prefix(12))"
            case .seam(let node, let expected, let found): return "\(node): seam \(found.prefix(12)) is not the braid's tail \(expected.prefix(12))"
            }
        }
    }

    /// `vocabularySHA256` → .vocabulary, `hiddenSize` → .hiddenSize, `packSHA256` → .pack (the commons is exempt), tokenizer → .tokenizer,
    /// `seamSHA256` → .seam when both the braid and the node name one.
    public static func check(_ descriptor: NodeDescriptor, vocabularySHA256: String, packSHA256: String?, hiddenSize: Int, tokenizerSHA256: String,
                             seamSHA256: String? = nil) throws {
        guard descriptor.vocabularySHA256 == vocabularySHA256 else {
            throw Failure.vocabulary(node: descriptor.name, expected: vocabularySHA256, found: descriptor.vocabularySHA256)
        }
        guard descriptor.hiddenSize == hiddenSize else { throw Failure.hiddenSize(node: descriptor.name, expected: hiddenSize, found: descriptor.hiddenSize) }
        if let packSHA256, !descriptor.isCommons, descriptor.packSHA256 != packSHA256 {
            throw Failure.pack(node: descriptor.name, expected: packSHA256, found: descriptor.packSHA256)
        }
        guard descriptor.tokenizerSHA256 == tokenizerSHA256 else {
            throw Failure.tokenizer(node: descriptor.name, expected: tokenizerSHA256, found: descriptor.tokenizerSHA256)
        }
        if let seamSHA256, let found = descriptor.seamSHA256, found != seamSHA256 {
            throw Failure.seam(node: descriptor.name, expected: seamSHA256, found: found)
        }
    }
}
