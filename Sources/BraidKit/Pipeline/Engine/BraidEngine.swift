//
//  BraidEngine.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Builds Threads from recipes. `plan` says what building would do and touches no MLX;
//        `build` runs a braid's recipes one Thread after another. The three things `braid thread`
//        does are its three intents, each the snapshot stage then the stages it needs:
//          create   read the source, write the record → train → index → promote → attach
//          sync     read the source again; when it changed → train on → index → promote
//          rekey    the live snapshot and blocks → index → promote
//        The CLI and the studio's new-Thread dialog go through it, so they build the same way.
//  PIN:  One MLX workload at a time: the engine runs on the thread that owns MLX (the CLI's main
//        thread, the studio's worker), synchronously. The tokenizer, the reed and the commons are
//        built once per engine (or handed in): a Thread's head trains and indexes in front of the
//        commons' tail, so the commons comes first. The corpus is tokenized once per build, and the
//        trained trunk is the one that is indexed. braid.toml is saved only when an attach changes it.
//

import BraidCore
import BraidThread
import Foundation
import MLX

public final class BraidEngine {
    public let area: WorkArea
    public let pack: Pack
    /// braid.toml as the engine holds it; an attach changes it and saves it.
    public private(set) var config: BraidConfig
    private let onEvent: (BuildEvent) -> Void
    private var loadedTokenizer: BraidTokenizer?
    private var loadedReed: MLXReed?
    private var loadedCommons: LocalNode?

    public init(area: WorkArea, config: BraidConfig, pack: Pack, tokenizer: BraidTokenizer? = nil, reed: MLXReed? = nil, commons: LocalNode? = nil,
                onEvent: @escaping (BuildEvent) -> Void = { _ in }) {
        self.area = area
        self.config = config
        self.pack = pack
        self.onEvent = onEvent
        loadedTokenizer = tokenizer
        loadedReed = reed
        loadedCommons = commons
    }

    // MARK: Plans

    /// What building `recipe` would do. Reads the work area and the source; refuses what a build would refuse.
    public func plan(_ recipe: ThreadRecipe) throws -> BuildPlan {
        let name = recipe.name
        let layout = area.thread(name)
        guard FileManager.default.fileExists(atPath: layout.record.path) else {
            guard let packRecord = config.pack else { throw BraidFailure.missing("braid.toml names no pack") }
            guard DocumentID.isValidHandle(name) else { throw BraidFailure.usage("thread names are lowercase handles: \(name)") }
            let read = try readSource(recipe.corpus, slug: name, limit: recipe.settings.limit)
            if let empty = read.whenEmpty, read.snapshot.documentCount == 0 { throw empty }
            if let fraction = recipe.settings.withhold { try Self.checkWithhold(fraction) }
            let key = recipe.settings.key ?? defaultKey(packRecord)
            return BuildPlan(name: name, intent: .create, stages: BuildPlanner.create(recipe, snapshot: read.snapshot, key: key, attached: config.attach.contains(name)),
                             diff: nil, read: read, existing: nil)
        }
        let existing = try loadExisting(name)
        let live = try liveThread(existing)
        if let refusal = BuildPlanner.refusal(recipe, live: live) { throw BraidFailure.usage(refusal) }
        let read = try readSource(recipe.corpus, slug: name, limit: existing.info.limit ?? existing.current.documentCount)
        let diff = SnapshotDiff(from: existing.current, to: read.snapshot)
        let (intent, stages) = BuildPlanner.update(recipe, live: live, snapshot: read.snapshot, diff: diff, attached: config.attach.contains(name))
        return BuildPlan(name: name, intent: intent, stages: stages, diff: diff, read: read, existing: existing)
    }

    /// Every Thread's plan, in order. A name may appear once.
    public func plan(_ braid: BraidRecipe) throws -> [BuildPlan] {
        var seen: Set<String> = []
        for recipe in braid.threads where !seen.insert(recipe.name).inserted {
            throw BraidFailure.usage("thread \(recipe.name) appears twice in the recipe")
        }
        return try braid.threads.map { try plan($0) }
    }

    // MARK: Builds

    /// Builds every Thread of `braid`: each is planned first (so a refusal stops the build before
    /// any MLX work), then created, synced or left as it is, one after another. Nil for a Thread
    /// that made no new version.
    @discardableResult
    public func build(_ braid: BraidRecipe) throws -> [BuildOutcome?] {
        let plans = try plan(braid)
        return try zip(braid.threads, plans).map { pair -> BuildOutcome? in
            let (recipe, plan) = pair
            switch plan.intent {
            case .create:
                return try create(recipe, read: plan.read)
            case .sync, .upToDate:
                guard let existing = plan.existing else { throw BraidFailure.data("thread \(recipe.name): a plan to update names no Thread") }
                onEvent(.stage(thread: recipe.name, .snapshot))
                let settings = recipe.settings
                let synced = try sync(existing, read: plan.read, training: settings.training, checkpoints: settings.checkpoints, seed: settings.seed)
                if settings.attach, !config.attach.contains(recipe.name) {
                    onEvent(.stage(thread: recipe.name, .attach))
                    try attach(recipe.name)
                }
                return synced.outcome.map { outcome in
                    var outcome = outcome
                    outcome.attached = config.attach.contains(recipe.name)
                    return outcome
                }
            }
        }
    }

    /// `braid thread create`: a new Thread from its recipe. Fails when the Thread exists.
    public func create(_ recipe: ThreadRecipe) throws -> BuildOutcome {
        try create(recipe, read: nil)
    }

    /// `braid thread sync`: the Thread's source read again. An unchanged corpus is left alone; a
    /// changed one is snapshotted, trained on from the live blocks (the continuing budget) unless
    /// `training` is off, and indexed under the live key as a new live version.
    public func sync(_ name: String, training: TrainingPlan) throws -> SyncOutcome {
        let existing = try loadExisting(name)
        let spec = try CorpusSourceSpec(parsing: existing.info.source)
        onEvent(.stage(thread: name, .snapshot))
        // A dataset is read in feeding order; the Thread's limit (or, for a record made before limits
        // were kept, the live snapshot's size) takes the same documents again.
        let read = try readSource(spec, slug: name, limit: existing.info.limit ?? existing.current.documentCount)
        return try sync(existing, read: read, training: training, checkpoints: CheckpointPolicy(), seed: nil)
    }

    /// `braid thread index`: the live version's blocks and snapshot keyed again, under another key
    /// scheme (nil keeps the live one) or checkpoint policy, as a new live version. Nothing is
    /// trained and the source is not read.
    public func rekey(_ name: String, key: KeyScheme?, checkpoints: CheckpointPolicy) throws -> BuildOutcome {
        let layout = area.thread(name)
        guard let live = try ThreadStore.live(layout) else { throw BraidFailure.missing("thread \(name) has no live version") }
        guard live.packSHA256 == pack.sha256 else { throw BraidFailure.data("thread \(name) was built on pack \(live.packSHA256.prefix(12))") }
        let keyScheme = key ?? live.keyScheme
        onEvent(.stage(thread: name, .snapshot))
        let snapshot = try CorpusSnapshot.load(from: layout.snapshot(hash: live.snapshotHash))
        let blocks = try ThreadStore.liveBlocks(layout, version: live, pack: pack)
        let trunk = try threadTrunk(head: blocks)
        _ = try tokenizer()
        let started = Date()
        note("thread \(name): re-keying v\(live.version) (\(live.keyScheme)) as \(keyScheme)\(checkpoints.everyPartition ? ", a checkpoint at every partition" : "")")
        let withheld = try ThreadStore.liveWithheld(layout, version: live)
        let info = try ThreadStore.info(layout)
        let context = BuildContext(name: name, layout: layout, threadID: info.threadID, snapshot: snapshot, facts: [], key: keyScheme, checkpoints: checkpoints,
                                   exclude: { withheld }, trunk: trunk, live: live, started: started)
        context.blocks = blocks
        context.totals = TrainingTotals(of: live)
        let version = try run([IndexStage(), PromoteStage(announce: false)], context)
        return BuildOutcome(name: name, version: version, keyScheme: keyScheme, corpusHash: snapshot.corpusHash, documents: snapshot.documentCount,
                            partitions: snapshot.partitionCount, attached: config.attach.contains(name), seconds: Date().timeIntervalSince(started))
    }

    // MARK: Intents

    func create(_ recipe: ThreadRecipe, read prepared: SourceRead?) throws -> BuildOutcome {
        guard let packRecord = config.pack else { throw BraidFailure.missing("braid.toml names no pack") }
        let name = recipe.name
        let settings = recipe.settings
        onEvent(.stage(thread: name, .snapshot))
        let read = try prepared ?? readSource(recipe.corpus, slug: name, limit: settings.limit)
        let snapshot = read.snapshot
        if let empty = read.whenEmpty, snapshot.documentCount == 0 { throw empty }
        let key = settings.key ?? defaultKey(packRecord)
        let seed = settings.seed ?? DeltaHyper().seed
        let withheld = try settings.withhold.map { fraction -> Set<String> in
            try Self.checkWithhold(fraction)
            return Withholding.draw(snapshot.documents.map(\.id), fraction: fraction, seed: seed)
        } ?? []
        let layout = try ThreadStore.create(name: name, label: settings.label, source: recipe.corpus, lane: read.lane, limit: settings.limit, snapshot: snapshot, in: area)
        note("thread \(name): \(snapshot.documentCount) documents, \(snapshot.partitionCount) partitions, corpus \(snapshot.corpusHash.prefix(12))")
        if !withheld.isEmpty { note("thread \(name): \(withheld.count) documents trained but withheld from the index (seed \(seed))") }
        _ = try tokenizer()
        let trunk = try threadTrunk(head: nil)
        let started = Date()
        let info = try ThreadStore.info(layout)
        let context = BuildContext(name: name, layout: layout, threadID: info.threadID, snapshot: snapshot, facts: read.facts, key: key, checkpoints: settings.checkpoints,
                                   exclude: { withheld }, trunk: trunk, live: nil, started: started)
        var stages: [BuildStage] = []
        if settings.training.trains { stages.append(TrainStage(plan: settings.training, seed: seed, continuing: false)) }
        stages += [IndexStage(), PromoteStage(announce: true)] as [BuildStage]
        if settings.attach, !config.attach.contains(name) { stages.append(AttachStage()) }
        let version = try run(stages, context)
        return BuildOutcome(name: name, version: version, keyScheme: key, corpusHash: snapshot.corpusHash, documents: snapshot.documentCount,
                            partitions: snapshot.partitionCount, attached: settings.attach, seconds: context.seconds ?? Date().timeIntervalSince(started))
    }

    func sync(_ existing: ExistingThread, read: SourceRead, training: TrainingPlan, checkpoints: CheckpointPolicy, seed: UInt64?) throws -> SyncOutcome {
        let info = existing.info
        let name = info.name
        let live = existing.live
        let layout = existing.layout
        let snapshot = read.snapshot
        let diff = SnapshotDiff(from: existing.current, to: snapshot)
        guard snapshot.corpusHash != live.corpusHash else {
            note("thread \(name): \(info.source) unchanged (corpus \(live.corpusHash.prefix(12))); v\(live.version) stays live")
            return SyncOutcome(outcome: nil, diff: diff)
        }
        note("thread \(name): \(info.source) changed: \(diff.summary); corpus \(live.corpusHash.prefix(12)) → \(snapshot.corpusHash.prefix(12))")
        guard snapshot.documentCount > 0 else { throw BraidFailure.missing("\(info.source) holds no documents now; the live version is kept") }
        try snapshot.save(to: layout.snapshot(hash: snapshot.corpusHash))
        let started = Date()
        _ = try tokenizer()
        let blocks = try ThreadStore.liveBlocks(layout, version: live, pack: pack)
        let trunk = try threadTrunk(head: blocks)
        // The withheld set is the live version's, read when the index needs it (after training).
        let context = BuildContext(name: name, layout: layout, threadID: info.threadID, snapshot: snapshot, facts: read.facts, key: live.keyScheme, checkpoints: checkpoints,
                                   exclude: { try ThreadStore.liveWithheld(layout, version: live) }, trunk: trunk, live: live, started: started)
        context.blocks = blocks
        context.totals = TrainingTotals(of: live)
        var stages: [BuildStage] = []
        if training.trains { stages.append(TrainStage(plan: training, seed: seed ?? DeltaHyper().seed, continuing: true)) }
        stages += [IndexStage(), PromoteStage(announce: false)] as [BuildStage]
        let version = try run(stages, context)
        let outcome = BuildOutcome(name: name, version: version, keyScheme: live.keyScheme, corpusHash: snapshot.corpusHash, documents: snapshot.documentCount,
                                   partitions: snapshot.partitionCount, attached: config.attach.contains(name), seconds: Date().timeIntervalSince(started))
        return SyncOutcome(outcome: outcome, diff: diff)
    }

    /// Runs the stages in order and returns the version the promote stage made live.
    private func run(_ stages: [BuildStage], _ context: BuildContext) throws -> ThreadVersionInfo {
        for stage in stages {
            onEvent(.stage(thread: context.name, stage.name))
            try stage.run(context, in: self)
        }
        guard let version = context.version else { throw BraidFailure.data("thread \(context.name): no version was made live") }
        return version
    }

    // MARK: Services the stages share

    func note(_ line: String) { onEvent(.note(line)) }

    func tokenizer() throws -> BraidTokenizer {
        if let loadedTokenizer { return loadedTokenizer }
        let tokenizer = try BraidTokenizer(folder: pack.tokenizerFolder)
        loadedTokenizer = tokenizer
        return tokenizer
    }

    func reed() throws -> MLXReed {
        if let loadedReed { return loadedReed }
        let reed = pack.reed(tokens: try tokenizer().vocabSize)
        loadedReed = reed
        return reed
    }

    /// The commons, built once per engine unless handed in: the pack whole, whose tail is the trunk
    /// every head this engine trains or indexes runs behind.
    public func commons() throws -> LocalNode {
        if let loadedCommons { return loadedCommons }
        guard let packRecord = config.pack else { throw BraidFailure.missing("braid.toml names no pack") }
        let node = try ThreadStore.commons(pack: pack, scheme: defaultKey(packRecord))
        note("the commons: the pack whole; its trunk \(node.trunk.seamSHA256.prefix(12)) serves every Thread")
        loadedCommons = node
        return node
    }

    /// A head in front of the commons' tail: `head`'s arrays (a live version's blocks) or, with nil, the pack's own blocks 0..<cut.
    private func threadTrunk(head arrays: [String: MLXArray]?) throws -> Trunk {
        let head = try arrays.map { try Trunk.makeHead(arrays: $0, config: pack.config) } ?? Trunk.packHead(pack)
        let trunk = Trunk(head: head, tail: try commons().trunk.tail)
        eval(trunk)
        return trunk
    }

    /// Adds `name` to `[cluster] attach`, saving braid.toml only when the list changes.
    func attach(_ name: String) throws {
        guard !config.attach.contains(name) else { return }
        config.attach.append(name)
        try config.save(to: area.configFile)
    }

    // MARK: Reading

    private func readSource(_ spec: CorpusSourceSpec, slug: String, limit: Int?) throws -> SourceRead {
        try CorpusSources.read(spec, slug: slug, limit: limit, datasetsRoot: DatasetsRoot.resolve(workArea: area.root), demoRoot: AIIDetect.demoRoot())
    }

    /// The Thread's record, its live version and the snapshot that version indexed.
    private func loadExisting(_ name: String) throws -> ExistingThread {
        let layout = area.thread(name)
        let info = try ThreadStore.info(layout)
        guard let live = try ThreadStore.live(layout) else { throw BraidFailure.missing("thread \(name) has no live version") }
        let current = try CorpusSnapshot.load(from: layout.snapshot(hash: live.snapshotHash))
        return ExistingThread(layout: layout, info: info, live: live, current: current)
    }

    private func liveThread(_ existing: ExistingThread) throws -> LiveThread {
        let index = existing.layout.version(existing.live.version).appendingPathComponent(ThreadStore.indexDirectory)
        let manifest = try JSONCoding.read(CheckpointManifest.self, from: index.appendingPathComponent(IndexFiles.checkpoints))
        return LiveThread(info: existing.info, version: existing.live, withheld: try ThreadStore.liveWithheld(existing.layout, version: existing.live),
                          checkpoints: manifest.policy)
    }

    /// braid.toml's key scheme, else the pack's tap.
    private func defaultKey(_ packRecord: BraidConfig.Pack) -> KeyScheme {
        KeyScheme(parsing: packRecord.keyScheme) ?? .residual(afterBlocks: pack.config.tapAfterBlocks)
    }

    private static func checkWithhold(_ fraction: Double) throws {
        guard fraction > 0, fraction < 1 else { throw BraidFailure.usage("--withhold takes a fraction between 0 and 1, not \(fraction)") }
    }
}
