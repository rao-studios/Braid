//
//  BenchBraid.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The braid a bench runs against, assembled from the work area the way `braid cluster spawn`
//        does: the pack's reed and tokenizer, the commons, the named Threads on their live versions,
//        braid.toml's gate and index constants. Scores a text (every strand asked at every prompt
//        position, nothing generated) or generates a few tokens, and maps each Thread back to the
//        dataset node it was fed from and the documents present in its snapshot.
//        A bench keeps its session log (`keepSession`) so `braid verify` can replay what it measured;
//        a sub-braid (the copy braid G3 and Q5b read) shares the nodes already loaded.
//  PIN:  Nothing is written to a node. The commons is always built, since every Thread runs behind its
//        trunk, and attached only when the braid wants it. The commons-alone braid (the lift bench's
//        NLL reference) is a second cluster holding the same commons node under its own session, and
//        keeps no log.
//

import BraidCore
import Foundation
import MLX

public final class BenchBraid {
    public let area: WorkArea
    public let config: BraidConfig
    public let pack: Pack
    public let tokenizer: BraidTokenizer
    public let reed: MLXReed
    public let scheme: KeyScheme
    public let settings: ClusterSettings
    public let cluster: Cluster
    public let threads: [LoadedThread]
    public let hasCommons: Bool
    /// The commons node: the trunk every Thread here runs behind, attached when `hasCommons`, shared with any sub-braid.
    public let commonsNode: LocalNode
    /// The session logs this braid wrote, in order.
    public private(set) var sessions: [URL] = []
    private var commonsAlone: Cluster?

    public init(area: WorkArea, config: BraidConfig, pack: Pack, tokenizer: BraidTokenizer, reed: MLXReed, scheme: KeyScheme, settings: ClusterSettings,
                cluster: Cluster, threads: [LoadedThread], hasCommons: Bool, commonsNode: LocalNode) {
        self.area = area
        self.config = config
        self.pack = pack
        self.tokenizer = tokenizer
        self.reed = reed
        self.scheme = scheme
        self.settings = settings
        self.cluster = cluster
        self.threads = threads
        self.hasCommons = hasCommons
        self.commonsNode = commonsNode
    }

    /// The bench's settings: braid.toml's gate (κ included) and index constants; the trajectory module
    /// runs (its e_t is logged), entering the gate only when κ > 0.
    public static func settings(config: BraidConfig, commons: Bool) -> ClusterSettings {
        var settings = ClusterSettings()
        settings.gate = config.gate
        if !commons { settings.gate.evidence = .absolute }
        settings.k = config.index.k
        settings.module?.k = config.index.k
        return settings
    }

    /// The commons (unless `commons` is false) and the named Threads (default: braid.toml's attach list).
    public static func assemble(area: WorkArea, config: BraidConfig, pack: Pack, threadNames: [String]?, commons: Bool = true,
                                progress: (String) -> Void = { _ in }) throws -> BenchBraid {
        let names = (threadNames ?? config.attach).filter { !$0.isEmpty }
        guard !names.isEmpty else { throw BraidFailure.usage("no Threads: pass --threads or create one") }
        let tokenizer = try BraidTokenizer(folder: pack.tokenizerFolder)
        let reed = pack.reed(tokens: tokenizer.vocabSize)
        let settings = settings(config: config, commons: commons)
        let cluster = Cluster(reed: reed, tokenizer: tokenizer, pack: pack.identity, settings: settings)
        let scheme = KeyScheme(parsing: config.pack?.keyScheme ?? "") ?? .residual(afterBlocks: pack.config.tapAfterBlocks)
        progress("loading the commons")
        let commonsNode = try ThreadStore.commons(pack: pack, scheme: scheme)
        if commons { try cluster.attach(commonsNode) }
        var threads: [LoadedThread] = []
        for name in names {
            progress("loading \(name)")
            let loaded = try ThreadStore.load(name, in: area, pack: pack, commons: commonsNode, tau: Float(config.index.tau))
            try cluster.attach(loaded.node)
            threads.append(loaded)
        }
        return BenchBraid(area: area, config: config, pack: pack, tokenizer: tokenizer, reed: reed, scheme: scheme, settings: settings, cluster: cluster,
                          threads: threads, hasCommons: commons, commonsNode: commonsNode)
    }

    /// A second braid under the same reed and settings: the commons and the named Threads, reusing the
    /// nodes this braid loaded (a node keeps one state per session, so two clusters can share it).
    public func subBraid(threads names: [String], progress: (String) -> Void = { _ in }) throws -> BenchBraid {
        let cluster = Cluster(reed: reed, tokenizer: tokenizer, pack: pack.identity, settings: settings)
        if hasCommons { try cluster.attach(commonsNode) }
        var loaded: [LoadedThread] = []
        for name in names {
            if let existing = threads.first(where: { $0.info.name == name }) {
                loaded.append(existing)
            } else {
                progress("loading \(name)")
                loaded.append(try ThreadStore.load(name, in: area, pack: pack, commons: commonsNode, tau: Float(config.index.tau)))
            }
            try cluster.attach(loaded[loaded.count - 1].node)
        }
        return BenchBraid(area: area, config: config, pack: pack, tokenizer: tokenizer, reed: reed, scheme: scheme, settings: settings, cluster: cluster,
                          threads: loaded, hasCommons: hasCommons, commonsNode: commonsNode)
    }

    /// Starts this braid's session log under the work area's sessions/ (what `braid verify` replays);
    /// every generation from here on is written to it.
    @discardableResult
    public func keepSession() throws -> URL {
        cluster.closeLog()
        try FileManager.default.createDirectory(at: area.sessions, withIntermediateDirectories: true)
        let url = area.sessions.appendingPathComponent(SessionLog.fileName(sessionID: cluster.sessionID))
        try cluster.startLog(at: url)
        sessions.append(url)
        return url
    }

    public func finishSession() { cluster.closeLog() }

    public var names: [String] { cluster.strandNames }
    public var commonsIndex: Int? { cluster.commonsIndex }
    public func index(of thread: String) -> Int? { names.firstIndex(of: thread) }

    /// Per Thread, `v<version>/<index sha256>`: what the report names.
    public var threadRecords: [String: String] {
        Dictionary(uniqueKeysWithValues: threads.map { ($0.info.name, "v\($0.version.version)/\($0.version.indexSHA256)") })
    }

    public var documents: [String: Int] {
        Dictionary(uniqueKeysWithValues: threads.map { thread in (thread.info.name, Set(thread.node.index?.partitions.map(\.documentID) ?? []).count) })
    }

    public var memorised: [String: Float] { Dictionary(uniqueKeysWithValues: threads.map { ($0.info.name, $0.version.memorised) }) }

    /// Per strand, its node-local row → document id (what the wire-chain audit needs).
    public var documentOfRow: [[Int32: String]] {
        names.map { name in
            guard let thread = threads.first(where: { $0.info.name == name }), let index = thread.node.index else { return [:] }
            return Dictionary(uniqueKeysWithValues: index.partitions.map { (Int32($0.row), $0.documentID) })
        }
    }

    /// Each Thread as the text builders see it: the dataset node its source names (or, for another
    /// source, the node holding most of its documents) and the ids present in its live snapshot.
    public func benchThreads(world: BenchWorld, warn: (String) -> Void = { _ in }) throws -> [BenchThread] {
        var result: [BenchThread] = []
        for thread in threads {
            let snapshot = try CorpusSnapshot.load(from: area.thread(thread.info.name).snapshot(hash: thread.version.snapshotHash))
            let present = Set(snapshot.documents.map(\.id))
            var node: String? = nil
            if case .dataset(let nameOrPath, let named)? = try? CorpusSourceSpec(parsing: thread.info.source) {
                node = named
                let datasetName = URL(fileURLWithPath: nameOrPath).lastPathComponent
                if datasetName != world.name { warn("thread \(thread.info.name) was fed from dataset \(datasetName), not \(world.name)") }
            }
            if node == nil || world.corpora[node!] == nil {
                let best = world.corpora.map { name, corpus in (name, corpus.documents.filter { present.contains($0.id) }.count) }.max { $0.1 < $1.1 }
                guard let best, best.1 > 0 else { throw BraidFailure.data("thread \(thread.info.name) holds no document of dataset \(world.name)") }
                if let named = node { warn("thread \(thread.info.name) names node \(named), which \(world.name) lacks; using \(best.0) by its documents") }
                node = best.0
            }
            result.append(BenchThread(name: thread.info.name, node: node!, present: present))
        }
        return result
    }

    /// Every token of `tokens` scored with every strand asked; nothing generated.
    public func score(_ tokens: [Int32]) throws -> Generation {
        var params = GenerationParameters()
        params.maxTokens = 0
        params.tau = Float(config.index.tau)
        params.k = config.index.k
        return try cluster.generate(prompt: GenerationPrompt(text: tokenizer.decode(tokens), tokens: tokens), params: params)
    }

    /// `maxTokens` greedy tokens after the prompt.
    public func generate(_ tokens: [Int32], maxTokens: Int) throws -> Generation {
        var params = GenerationParameters()
        params.maxTokens = maxTokens
        params.tau = Float(config.index.tau)
        params.k = config.index.k
        return try cluster.generate(prompt: GenerationPrompt(text: tokenizer.decode(tokens), tokens: tokens), params: params)
    }

    /// The same text scored by the commons alone (the lift bench's held-out reference).
    public func scoreCommonsAlone(_ tokens: [Int32]) throws -> Generation {
        if commonsAlone == nil {
            let alone = Cluster(reed: reed, tokenizer: tokenizer, pack: pack.identity, settings: settings)
            try alone.attach(commonsNode)
            commonsAlone = alone
        }
        var params = GenerationParameters()
        params.maxTokens = 0
        return try commonsAlone!.generate(prompt: GenerationPrompt(text: tokenizer.decode(tokens), tokens: tokens), params: params)
    }

    /// Frees MLX's cached buffers between texts.
    public func relax() { Memory.clearCache() }
}

/// One generated position, read through the strands it was recorded with.
public struct GeneratedToken: Sendable {
    public var step: Step
    /// The strands' names at this position, in the record's order.
    public var names: [String]
    public var credit: CreditRow?
    public var annotation: SpanAnnotation?

    /// The credit of `name` at this position (0 when it was not a strand here).
    public func credit(of name: String) -> Float {
        guard let row = credit, let t = names.firstIndex(of: name), t < row.credit.count else { return 0 }
        return row.credit[t]
    }
}

extension Generation {
    /// The generated positions, each with its strands' names, its credit row and its citations
    /// (credits and annotations are aligned with the non-context steps).
    public var generatedTokens: [GeneratedToken] {
        let shared = steps.indices.filter { steps[$0].source != .ctx }
        var tokens: [GeneratedToken] = []
        for (i, k) in shared.enumerated() where steps[k].source == .gen {
            tokens.append(GeneratedToken(step: steps[k], names: k < slots.count ? slots[k].map(\.name) : [],
                                         credit: i < credits.count ? credits[i] : nil, annotation: i < annotations.count ? annotations[i] : nil))
        }
        return tokens
    }
}

/// What a generation's first generated position says about the gate: who leads, whether everyone
/// was asked, how much the largest Thread holds.
public struct FirstTokenGate: Sendable, Equatable {
    public var allOpen: Bool
    public var largestThreadMemory: Float
    public var leader: Int
    public var commonsLeads: Bool?

    public init?(_ generation: Generation, commons: Int?) {
        guard let records = generation.generated.first?.threads, !records.isEmpty else { return nil }
        allOpen = records.allSatisfy(\.open)
        let threads = records.indices.filter { $0 != commons }
        largestThreadMemory = threads.map { records[$0].memory }.max() ?? 0
        var best = 0
        for t in records.indices where records[t].memory > records[best].memory { best = t }
        leader = best
        commonsLeads = commons.map { records[$0].memory >= largestThreadMemory }
    }
}
