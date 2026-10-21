//
//  Checkpoints.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The state checkpoints an index carries: the policy that places them (a partition boundary
//        once 1,024 tokens have passed, or every partition), each checkpoint's record (document,
//        position, file, hash, the prefix it is bound to), and checkpoints.json, the manifest.
//  PIN:  A checkpoint's file name is its document id and position when the id is plain (letters,
//        digits, `.`, `_`, `-`: every dataset, folder and Braid lane id, so those names never
//        change). Any other id, such as an app's record id `<app>/<kind>/<id>`, which may hold `/`,
//        `:` or capitals, is folded into one safe path component with its hash beside it, so ids
//        that differ only in case or punctuation stay apart on a case-insensitive volume.
//

import BraidCore
import Foundation

public struct CheckpointPolicy: Codable, Sendable, Equatable {
    /// A checkpoint is written at a partition boundary once this many tokens have passed since the last one in the document.
    public var strideTokens = 1024
    public var everyPartition = false
    public init() {}
}

public struct CheckpointRef: Codable, Sendable, Equatable {
    public var documentID: String
    /// The stream position (in the document's eos-opened sequence) of the last token consumed.
    public var position: Int
    public var file: String
    public var sha256: String
    public var prefixSHA256: String
}

extension CheckpointRef {
    /// The file a checkpoint is saved as, in the index's checkpoints/ folder.
    public static func fileName(documentID: String, position: Int) -> String {
        if !documentID.isEmpty, documentID.unicodeScalars.allSatisfy({ plain.contains($0) }) {
            return "\(documentID)-\(position).safetensors"
        }
        let folded = String(String.UnicodeScalarView(documentID.lowercased().unicodeScalars.prefix(64).map { folding.contains($0) ? $0 : "_" }))
        return "\(folded)~\(ContentHash.sha256Hex(Data(documentID.utf8)).prefix(24))-\(position).safetensors"
    }

    private static let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    private static let folding = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
}

public struct CheckpointManifest: Codable, Sendable, Equatable {
    public var version = 1
    public var policy: CheckpointPolicy
    public var checkpoints: [CheckpointRef]
    public var totalBytes: Int
}
