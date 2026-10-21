//
//  ThreadStore.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: A Thread on disk under threads/<name>/: its record, its snapshots by hash, its versions
//        (version.json, blocks.safetensors when trained, index/ with checkpoints/), and live.json
//        pointing at the version that serves. Loading a Thread gives a LocalNode on the live
//        version (Run/Node/ThreadLoading.swift); every hash in the chain is re-derived on the way.
//

import BraidCore
import Foundation
import MLX

public enum ThreadStore {
    public static let blocksFile = "blocks.safetensors"
    public static let indexDirectory = "index"

    public static func list(in area: WorkArea) throws -> [ThreadInfo] {
        guard FileManager.default.fileExists(atPath: area.threads.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: area.threads, includingPropertiesForKeys: nil)
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("thread.json").path) }
            .map { try JSONCoding.read(ThreadInfo.self, from: $0.appendingPathComponent("thread.json")) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Creates the Thread's record and saves its first snapshot; returns the layout.
    public static func create(name: String, label: String?, source: CorpusSourceSpec, lane: String?, limit: Int? = nil, snapshot: CorpusSnapshot, in area: WorkArea) throws -> ThreadLayout {
        guard DocumentID.isValidHandle(name) else { throw BraidFailure.usage("thread names are lowercase handles: \(name)") }
        let layout = area.thread(name)
        if FileManager.default.fileExists(atPath: layout.record.path) { throw BraidFailure.exists("thread \(name) exists at \(layout.root.path)") }
        try FileManager.default.createDirectory(at: layout.versions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: layout.snapshots, withIntermediateDirectories: true)
        let info = ThreadInfo(name: name, label: label ?? name.prefix(1).uppercased() + name.dropFirst(), source: source.description, lane: lane, threadID: UUID().uuidString.lowercased(),
                              createdAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)), limit: limit)
        try JSONCoding.write(info, to: layout.record)
        try snapshot.save(to: layout.snapshot(hash: snapshot.corpusHash))
        return layout
    }

    public static func info(_ layout: ThreadLayout) throws -> ThreadInfo { try JSONCoding.read(ThreadInfo.self, from: layout.record) }

    public static func live(_ layout: ThreadLayout) throws -> ThreadVersionInfo? {
        guard FileManager.default.fileExists(atPath: layout.live.path) else { return nil }
        let live = try JSONCoding.read(LiveInfo.self, from: layout.live)
        return try JSONCoding.read(ThreadVersionInfo.self, from: layout.version(live.version).appendingPathComponent("version.json"))
    }

    public static func nextVersion(_ layout: ThreadLayout) -> Int {
        let existing = (try? FileManager.default.contentsOfDirectory(at: layout.versions, includingPropertiesForKeys: nil))?.compactMap { Int($0.lastPathComponent.dropFirst()) } ?? []
        return (existing.max() ?? 0) + 1
    }

    /// Indexes a snapshot with the given trunk (the pack's blocks, or a trained version's) into a new
    /// version and makes it live: `writeIndex`, `writeVersion`, `promote`.
    @discardableResult
    public static func index(_ layout: ThreadLayout, pack: Pack, trunk: Trunk, tokenizer: BraidTokenizer, snapshot: CorpusSnapshot, scheme: KeyScheme,
                             blocks: [String: MLXArray]?, training: TrainingTotals?, checkpoints: CheckpointPolicy = CheckpointPolicy(),
                             exclude: Set<String> = [], progress: (String) -> Void = { _ in }) throws -> ThreadVersionInfo {
        let info = try info(layout)
        let corpus = TokenizedCorpus(snapshot: snapshot, tokenizer: tokenizer, paragraphBreak: tokenizer.paragraphBreak, threadID: info.threadID)
        let written = try writeIndex(layout, pack: pack, trunk: trunk, reed: pack.reed(tokens: tokenizer.vocabSize), corpus: corpus, threadID: info.threadID,
                                     scheme: scheme, blocks: blocks, checkpoints: checkpoints, exclude: exclude, progress: progress)
        let record = try writeVersion(written, pack: pack, snapshot: snapshot, scheme: scheme, training: training)
        try promote(layout, version: record.version)
        return record
    }

    /// A new version's directory with its blocks (when they are the Thread's own) and its index,
    /// keyed on `trunk`. The version takes the next number when its directory is made.
    public static func writeIndex(_ layout: ThreadLayout, pack: Pack, trunk: Trunk, reed: MLXReed, corpus: TokenizedCorpus, threadID: String, scheme: KeyScheme,
                                  blocks: [String: MLXArray]?, checkpoints: CheckpointPolicy, exclude: Set<String>, progress: (String) -> Void) throws -> WrittenIndex {
        let number = nextVersion(layout)
        let directory = layout.version(number)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var blocksSHA256 = pack.sha256
        if let blocks {
            let url = directory.appendingPathComponent(blocksFile)
            try MLX.save(arrays: blocks, metadata: ["format": "braid-thread-blocks-v1", "pack": pack.sha256], url: url)
            blocksSHA256 = try ContentHash.sha256Hex(fileAt: url)
        }
        var options = IndexBuildOptions(scheme: scheme)
        options.checkpoints = checkpoints
        options.exclude = exclude
        let built = try IndexBuilder.build(trunk: trunk, reed: reed, corpus: corpus, pack: pack, blocksSHA256: blocksSHA256, threadID: threadID, options: options,
                                           into: directory.appendingPathComponent(indexDirectory, isDirectory: true)) { d, n in if d % 50 == 0 { progress("indexing \(d)/\(n) documents") } }
        return WrittenIndex(version: number, directory: directory, trained: blocks != nil, blocksSHA256: blocksSHA256, built: built)
    }

    /// The version's record, version.json, binding what `writeIndex` wrote.
    public static func writeVersion(_ written: WrittenIndex, pack: Pack, snapshot: CorpusSnapshot, scheme: KeyScheme, training: TrainingTotals?) throws -> ThreadVersionInfo {
        let built = written.built
        let record = ThreadVersionInfo(version: written.version, packSHA256: pack.sha256, seamSHA256: built.info.seamSHA256, vocabularySHA256: pack.info.vocabularySHA256,
                                       tokenizerSHA256: pack.info.tokenizerSHA256, cut: built.info.cut, keyScheme: scheme, corpusHash: snapshot.corpusHash, snapshotHash: snapshot.corpusHash,
                                       trained: written.trained, steps: training?.steps ?? 0, epochs: training?.epochs ?? 0, learned: training?.learned ?? false,
                                       memorised: built.memorised, meanLoss: built.meanLoss, heldOutLoss: training?.heldOutLoss, blocksSHA256: written.blocksSHA256,
                                       indexSHA256: built.info.indexSHA256, checkpointsSHA256: built.info.checkpointsSHA256, entries: built.info.count,
                                       createdAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)))
        try JSONCoding.write(record, to: written.directory.appendingPathComponent("version.json"))
        return record
    }

    /// Makes `version` the one that serves (live.json).
    public static func promote(_ layout: ThreadLayout, version: Int) throws {
        try JSONCoding.write(LiveInfo(version: version), to: layout.live)
    }

    // MARK: The live version's inputs

    /// The live version's own blocks, hash-checked (nil when it indexes the pack's blocks).
    static func liveBlocks(_ layout: ThreadLayout, version: ThreadVersionInfo, pack: Pack) throws -> [String: MLXArray]? {
        let url = layout.version(version.version).appendingPathComponent(ThreadStore.blocksFile)
        guard FileManager.default.fileExists(atPath: url.path) else {
            guard version.blocksSHA256 == pack.sha256 else { throw BraidFailure.data("v\(version.version) names blocks that are not on disk") }
            return nil
        }
        guard try ContentHash.sha256Hex(fileAt: url) == version.blocksSHA256 else { throw BraidFailure.data("v\(version.version): blocks.safetensors does not hash to its record") }
        return try loadArrays(url: url)
    }

    /// The documents the live version trained on but left out of its index (`--withhold`), kept out again.
    static func liveWithheld(_ layout: ThreadLayout, version: ThreadVersionInfo) throws -> Set<String> {
        let info = try JSONCoding.read(IndexInfo.self, from: layout.version(version.version).appendingPathComponent(ThreadStore.indexDirectory).appendingPathComponent(IndexFiles.info))
        return Set(info.excluded ?? [])
    }
}

/// A version's index on disk before its record is written: the number it took, its directory,
/// whether its blocks are the Thread's own, their hash, and what the build measured.
public struct WrittenIndex {
    public var version: Int
    public var directory: URL
    public var trained: Bool
    public var blocksSHA256: String
    public var built: IndexBuildResult
}
