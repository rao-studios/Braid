//
//  ThreadRecords.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: A Thread's records on disk: thread.json (its name, label, source, lane, id and limit),
//        version.json (what one version binds by hash: pack, tokenizer, blocks, key scheme,
//        snapshot, index and checkpoints, with its training totals) and live.json (the version
//        that serves).
//

import BraidCore
import Foundation

public struct ThreadInfo: Codable, Sendable, Equatable {
    public var name: String
    public var label: String
    public var source: String
    public var lane: String?
    public var threadID: String
    public var createdAt: Date
    /// For a dataset source: how many documents (in feeding order) the Thread took; nil = all.
    public var limit: Int?
}

public struct ThreadVersionInfo: Codable, Sendable, Equatable {
    public var version: Int
    public var packSHA256: String
    public var seamSHA256: String
    public var vocabularySHA256: String
    public var tokenizerSHA256: String
    public var cut: Int
    public var keyScheme: KeyScheme
    public var corpusHash: String
    public var snapshotHash: String
    public var trained: Bool
    public var steps: Int
    public var epochs: Int
    public var learned: Bool
    public var memorised: Float
    public var meanLoss: Float
    public var heldOutLoss: Float?
    /// sha256 of blocks.safetensors, or the pack's name when the blocks are the pack's.
    public var blocksSHA256: String
    public var indexSHA256: String
    public var checkpointsSHA256: String
    public var entries: Int
    public var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case version, packSHA256, seamSHA256, vocabularySHA256, tokenizerSHA256, cut, keyScheme, corpusHash, snapshotHash, trained, steps, epochs, learned
        case memorised, meanLoss, heldOutLoss, blocksSHA256, indexSHA256, checkpointsSHA256, entries, createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        packSHA256 = try c.decode(String.self, forKey: .packSHA256)
        seamSHA256 = try c.decode(String.self, forKey: .seamSHA256)
        vocabularySHA256 = try c.decode(String.self, forKey: .vocabularySHA256)
        tokenizerSHA256 = try c.decode(String.self, forKey: .tokenizerSHA256)
        cut = try c.decode(Int.self, forKey: .cut)
        keyScheme = try c.decode(KeyScheme.self, forKey: .keyScheme)
        corpusHash = try c.decode(String.self, forKey: .corpusHash)
        snapshotHash = try c.decode(String.self, forKey: .snapshotHash)
        trained = try c.decode(Bool.self, forKey: .trained)
        steps = try c.decode(Int.self, forKey: .steps)
        epochs = try c.decode(Int.self, forKey: .epochs)
        learned = try c.decode(Bool.self, forKey: .learned)
        memorised = try c.decode(Float.self, forKey: .memorised)
        meanLoss = try c.decode(Float.self, forKey: .meanLoss)
        heldOutLoss = try c.decodeIfPresent(Float.self, forKey: .heldOutLoss)
        blocksSHA256 = try c.decode(String.self, forKey: .blocksSHA256)
        indexSHA256 = try c.decode(String.self, forKey: .indexSHA256)
        checkpointsSHA256 = try c.decode(String.self, forKey: .checkpointsSHA256)
        entries = try c.decodeIfPresent(Int.self, forKey: .entries) ?? 0
        createdAt = try c.decode(Date.self, forKey: .createdAt)
    }

    public init(version: Int, packSHA256: String, seamSHA256: String, vocabularySHA256: String, tokenizerSHA256: String, cut: Int, keyScheme: KeyScheme, corpusHash: String,
                snapshotHash: String, trained: Bool, steps: Int, epochs: Int, learned: Bool, memorised: Float, meanLoss: Float, heldOutLoss: Float?, blocksSHA256: String,
                indexSHA256: String, checkpointsSHA256: String, entries: Int, createdAt: Date) {
        self.version = version
        self.packSHA256 = packSHA256
        self.seamSHA256 = seamSHA256
        self.vocabularySHA256 = vocabularySHA256
        self.tokenizerSHA256 = tokenizerSHA256
        self.cut = cut
        self.keyScheme = keyScheme
        self.corpusHash = corpusHash
        self.snapshotHash = snapshotHash
        self.trained = trained
        self.steps = steps
        self.epochs = epochs
        self.learned = learned
        self.memorised = memorised
        self.meanLoss = meanLoss
        self.heldOutLoss = heldOutLoss
        self.blocksSHA256 = blocksSHA256
        self.indexSHA256 = indexSHA256
        self.checkpointsSHA256 = checkpointsSHA256
        self.entries = entries
        self.createdAt = createdAt
    }
}

public struct LiveInfo: Codable, Sendable, Equatable { public var version: Int }

/// What a version records of the training behind its blocks: optimizer steps and epochs in all,
/// whether the last run learned, and that run's held-out loss.
public struct TrainingTotals: Sendable, Equatable {
    public var steps: Int
    public var epochs: Int
    public var learned: Bool
    public var heldOutLoss: Float?

    public init(steps: Int, epochs: Int, learned: Bool, heldOutLoss: Float?) {
        self.steps = steps
        self.epochs = epochs
        self.learned = learned
        self.heldOutLoss = heldOutLoss
    }

    /// A version's own totals, carried to a version that is not trained further; nil when it never was trained.
    public init?(of version: ThreadVersionInfo) {
        guard version.trained else { return nil }
        self.init(steps: version.steps, epochs: version.epochs, learned: version.learned, heldOutLoss: version.heldOutLoss)
    }
}
