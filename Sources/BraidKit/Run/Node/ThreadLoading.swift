//
//  ThreadLoading.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: A Thread's live version as a running strand: its head, blocks 0..<cut from the version's
//        file, in front of the commons' tail; its index opened; every hash in the chain re-derived
//        on the way; the version's seam and cut held against the commons' before anything runs; and
//        the tokenizer services the context lookup needs. The commons is the pack's language module
//        whole, with no index, and it is built first: a Thread is loaded with the commons it runs
//        behind.
//

import BraidCore
import Foundation
import MLX

public struct LoadedThread {
    public var info: ThreadInfo
    public var version: ThreadVersionInfo
    public var directory: URL
    public var node: LocalNode
}

extension ThreadStore {
    /// The live version as a node: its head in front of `commons`' tail, its index loaded, every hash checked.
    public static func load(_ name: String, in area: WorkArea, pack: Pack, commons: LocalNode, tau: Float = 0.05) throws -> LoadedThread {
        guard commons.descriptor.isCommons else {
            throw BraidFailure.usage("\(commons.descriptor.name) is a Thread; a Thread runs in front of the commons' tail, not another Thread's")
        }
        let layout = area.thread(name)
        let info = try info(layout)
        guard let version = try live(layout) else { throw BraidFailure.missing("thread \(name) has no live version") }
        guard version.packSHA256 == pack.sha256 else { throw BraidFailure.data("thread \(name) was built on pack \(version.packSHA256.prefix(12)), not \(pack.sha256.prefix(12))") }
        let tail = commons.languageModule.tail
        let directory = layout.version(version.version)
        let index = try ProvenanceIndex(directory: directory.appendingPathComponent(indexDirectory))
        try checkSeam(version, index: index.info, tail: tail, thread: name)
        guard index.info.blocksSHA256 == version.blocksSHA256, index.info.packSHA256 == pack.sha256 else { throw BraidFailure.data("thread \(name): the index was keyed with other weights") }
        let head: [Mamba2Block]
        let blocksURL = directory.appendingPathComponent(blocksFile)
        if FileManager.default.fileExists(atPath: blocksURL.path) {
            guard try ContentHash.sha256Hex(fileAt: blocksURL) == version.blocksSHA256 else { throw BraidFailure.data("thread \(name) v\(version.version): blocks.safetensors does not hash to its record") }
            head = try LanguageModule.makeHead(arrays: try loadArrays(url: blocksURL), config: pack.config)
        } else {
            guard version.blocksSHA256 == pack.sha256 else { throw BraidFailure.data("thread \(name) v\(version.version) names blocks that are not on disk") }
            head = try LanguageModule.packHead(pack)
        }
        let languageModule = LanguageModule(head: head, tail: tail)
        eval(languageModule)
        let node = LocalNode(name: name, label: info.label, pack: pack, languageModule: languageModule, index: index, scheme: version.keyScheme, threadID: info.threadID, lane: info.lane,
                             versionSHA256: version.indexSHA256, tau: tau)
        let tokenizer = try BraidTokenizer(folder: pack.tokenizerFolder)
        node.tokenizerEOS = tokenizer.eos
        node.textOf = { tokenizer.text($0) }
        node.decodeTokens = { tokenizer.decode($0) }
        return LoadedThread(info: info, version: version, directory: directory, node: node)
    }

    /// The seam and the cut a version (and its index) name, against the tail a head is about to run on.
    /// A Thread trained against one tail never runs on another.
    public static func checkSeam(_ version: ThreadVersionInfo, index: IndexInfo?, tail: LanguageModule.Tail, thread name: String) throws {
        guard version.seamSHA256 == tail.seamSHA256 else {
            throw BraidFailure.data("thread \(name) v\(version.version) was trained against seam \(version.seamSHA256.prefix(12)), not the commons' tail \(tail.seamSHA256.prefix(12))")
        }
        guard version.cut == tail.cut else { throw BraidFailure.data("thread \(name) v\(version.version) is cut at \(version.cut); the commons' tail is cut at \(tail.cut)") }
        if let index {
            guard index.seamSHA256 == tail.seamSHA256 else {
                throw BraidFailure.data("thread \(name) v\(version.version): the index was keyed against seam \(index.seamSHA256.prefix(12)), not the commons' tail \(tail.seamSHA256.prefix(12))")
            }
            guard index.cut == tail.cut else { throw BraidFailure.data("thread \(name) v\(version.version): the index was keyed at cut \(index.cut); the commons' tail is cut at \(tail.cut)") }
        }
    }

    /// The commons: the pack's language module whole, frozen, with no index. Built first; every Thread runs behind its tail.
    public static func commons(pack: Pack, scheme: KeyScheme) throws -> LocalNode {
        LocalNode(name: "commons", label: "Commons", pack: pack, languageModule: try LanguageModule(pack: pack), index: nil, scheme: scheme, threadID: nil, lambdaScale: 0)
    }
}
