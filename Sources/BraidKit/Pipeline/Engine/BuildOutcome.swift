//
//  BuildOutcome.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: What a build leaves: the version it made live, and the one line `braid thread` prints for
//        it. A sync also carries what changed in the source, whether or not a version was made.
//

import BraidCore
import Foundation

public struct BuildOutcome: Sendable {
    public var name: String
    public var version: ThreadVersionInfo
    public var keyScheme: KeyScheme
    public var corpusHash: String
    public var documents: Int
    public var partitions: Int
    public var attached: Bool
    public var seconds: Double

    /// The one line `braid thread create` prints.
    public var summary: String {
        "\(name)  v\(version.version)  \(keyScheme)  index \(version.indexSHA256.prefix(12))  corpus \(corpusHash.prefix(12))  \(attached ? "attached" : "")"
    }
}

public struct SyncOutcome: Sendable {
    /// The new live version; nil when the source had not changed.
    public var outcome: BuildOutcome?
    public var diff: SnapshotDiff
}
