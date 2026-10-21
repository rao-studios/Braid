//
//  PipelineTests.swift
//  BraidKitTests
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The pipeline's declarative layer. Without MLX: the builder (lines, loops, conditions),
//        the modifiers and their defaults, the training plan's budgets, and the planner's
//        decisions (create, up to date, sync, each refusal). With MLX and a work area: a recipe
//        built into a scratch work area, planned up to date, re-keyed, loaded and opened.
//

import Foundation
import Testing
@testable import BraidKit

@Suite("The pipeline's recipes and plans")
struct PipelineRecipeTests {
    @Test("a braid recipe reads like a body: lines, loops and conditions")
    func builder() throws {
        let withVeil = true
        let withCopy = false
        let braid = try BraidRecipe {
            for node in ["ambient", "craft"] {
                ThreadRecipe(node, corpus: .dataset("braid-n3", node: node))
            }
            if withVeil { try ThreadRecipe("veil", corpus: "aii:demo-a/veil").training(.off) }
            if withCopy {
                ThreadRecipe("copy", corpus: .folder("/tmp/copy"))
            } else {
                ThreadRecipe("plain", corpus: .folder("/tmp/plain")).attached(false)
            }
        }
        #expect(braid.threads.map(\.name) == ["ambient", "craft", "veil", "plain"])
        #expect(braid.threads[0].corpus.description == "dataset:braid-n3#ambient")
        #expect(braid.threads[2].corpus == .lane("demo-a/veil"))
        #expect(braid.threads[2].settings.training == .off)
        #expect(braid.threads[3].corpus.description == "dir:/tmp/plain")
        #expect(braid.threads[3].settings.attach == false)
    }

    @Test("modifiers return a changed copy; unset settings keep today's defaults")
    func modifiers() throws {
        let base = ThreadRecipe("ambient", corpus: .dataset("braid-n3", node: "ambient"))
        let tuned = base.limit(40).label("Ambient air").key(.pooledState(layer: 7)).checkpoints(.atEveryPartition)
            .training(.on(steps: 24, batchSize: 2, seqLen: 64)).withhold(0.2).seed(7).attached(false)
        #expect(base.settings == ThreadRecipe.Settings())
        #expect(base.settings.key == nil && base.settings.limit == nil && base.settings.label == nil && base.settings.withhold == nil && base.settings.seed == nil)
        #expect(base.settings.checkpoints == CheckpointPolicy() && base.settings.checkpoints.strideTokens == 1024 && !base.settings.checkpoints.everyPartition)
        #expect(base.settings.training == .standard && base.settings.attach)
        #expect(tuned.settings.limit == 40 && tuned.settings.label == "Ambient air" && tuned.settings.key == .pooledState(layer: 7))
        #expect(tuned.settings.checkpoints.everyPartition && tuned.settings.training == .on(steps: 24, batchSize: 2, seqLen: 64))
        #expect(tuned.settings.withhold == 0.2 && tuned.settings.seed == 7 && !tuned.settings.attach)
        #expect(try ThreadRecipe("a", corpus: "dataset:braid-n3#ambient") == ThreadRecipe("a", corpus: .dataset("braid-n3", node: "ambient")))
        #expect(throws: BraidFailure.self) { try ThreadRecipe("a", corpus: "ftp:nowhere") }
        #expect(try KeyScheme.parsed("residual:12") == .residual(afterBlocks: 12))
        #expect(throws: BraidFailure.self) { try KeyScheme.parsed("bogus:1") }
    }

    @Test("a training plan sets the scratch budget for a new Thread and the continuing one after")
    func trainingPlan() {
        let defaults = DeltaHyper()
        let scratch = TrainingPlan.on(steps: 24, batchSize: 2, seqLen: 64).hyper(continuing: false, seed: 7)
        #expect(scratch.scratchSteps == 24 && scratch.continueSteps == defaults.continueSteps)
        #expect(scratch.batchSize == 2 && scratch.seqLen == 64 && scratch.seed == 7)
        var expected = defaults
        expected.continueSteps = 12
        #expect(TrainingPlan.on(steps: 12).hyper(continuing: true, seed: defaults.seed) == expected)
        #expect(TrainingPlan.standard.hyper(continuing: false, seed: defaults.seed) == defaults)
        #expect(TrainingPlan.standard.trains && !TrainingPlan.off.trains)
    }

    // MARK: The planner

    static func folder(_ documents: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("braid-plan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (i, text) in documents.enumerated() { try text.write(to: url.appendingPathComponent("d\(i).txt"), atomically: true, encoding: .utf8) }
        return url
    }

    static let texts = ["The keeper lit the lamp at dusk.\n\nShips passed in the night.", "Tide tables hang by the door.\n\nThe bell rings at noon."]

    static func live(source: String, snapshot: CorpusSnapshot, trained: Bool = true, withheld: Set<String> = [], checkpoints: CheckpointPolicy = CheckpointPolicy(),
                     limit: Int? = nil) -> LiveThread {
        let info = ThreadInfo(name: "tiny", label: "Tiny", source: source, lane: nil, threadID: "t", createdAt: Date(timeIntervalSince1970: 0), limit: limit)
        let version = ThreadVersionInfo(version: 3, packSHA256: "p", seamSHA256: "s", vocabularySHA256: "v", tokenizerSHA256: "t", cut: 12, keyScheme: .residual(afterBlocks: 12),
                                        corpusHash: snapshot.corpusHash, snapshotHash: snapshot.corpusHash, trained: trained, steps: 10, epochs: 1, learned: true, memorised: 1,
                                        meanLoss: 0, heldOutLoss: nil, blocksSHA256: "b", indexSHA256: "i", checkpointsSHA256: "c", entries: 1, createdAt: Date(timeIntervalSince1970: 0))
        return LiveThread(info: info, version: version, withheld: withheld, checkpoints: checkpoints)
    }

    @Test("a recipe that restates a Thread is accepted; one that changes it is refused with the reason")
    func refusals() throws {
        let url = try Self.folder(Self.texts)
        defer { try? FileManager.default.removeItem(at: url) }
        let snapshot = try CorpusSources.snapshot(directory: url, slug: "tiny")
        let recipe = ThreadRecipe("tiny", corpus: .folder(url.path))
        let live = Self.live(source: recipe.corpus.description, snapshot: snapshot)
        #expect(BuildPlanner.refusal(recipe, live: live) == nil)
        #expect(BuildPlanner.refusal(recipe.label("Tiny").key(.residual(afterBlocks: 12)).training(.off).seed(9), live: live) == nil)

        #expect(BuildPlanner.refusal(ThreadRecipe("tiny", corpus: .folder("/elsewhere")), live: live)?.contains("reads dir:") == true)
        #expect(BuildPlanner.refusal(recipe.limit(5), live: live)?.contains("every document") == true)
        #expect(BuildPlanner.refusal(recipe.label("Other"), live: live)?.contains("labelled Tiny") == true)
        #expect(BuildPlanner.refusal(recipe.key(.pooledState(layer: 7)), live: live)?.contains("keyed residual:12") == true)
        #expect(BuildPlanner.refusal(recipe.checkpoints(.atEveryPartition), live: live)?.contains("every 1024 tokens") == true)
        #expect(BuildPlanner.refusal(recipe.withhold(0.2), live: live)?.contains("withholds no documents") == true)

        let everyPartition = Self.live(source: recipe.corpus.description, snapshot: snapshot, withheld: ["x"], checkpoints: .atEveryPartition, limit: 5)
        #expect(BuildPlanner.refusal(recipe, live: everyPartition)?.contains("at every partition") == true)
        #expect(BuildPlanner.refusal(recipe.checkpoints(.atEveryPartition).withhold(0.2).limit(5), live: everyPartition) == nil)
    }

    @Test("the plan creates a new Thread, leaves an unchanged one, and syncs a changed one")
    func decisions() throws {
        let url = try Self.folder(Self.texts)
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try CorpusSources.snapshot(directory: url, slug: "tiny")
        let recipe = ThreadRecipe("tiny", corpus: .folder(url.path))

        let created = BuildPlanner.create(recipe, snapshot: before, key: .residual(afterBlocks: 12), attached: false)
        #expect(created.filter(\.runs).map(\.stage) == StageName.allCases)
        #expect(BuildPlanner.create(recipe.training(.off).attached(false), snapshot: before, key: .residual(afterBlocks: 12), attached: false).filter(\.runs).map(\.stage)
                == [.snapshot, .index, .promote])

        let live = Self.live(source: recipe.corpus.description, snapshot: before)
        let (same, unchanged) = BuildPlanner.update(recipe, live: live, snapshot: before, diff: SnapshotDiff(from: before, to: before), attached: true)
        #expect(same == .upToDate && unchanged.filter(\.runs).map(\.stage) == [.snapshot])
        #expect(BuildPlanner.update(recipe, live: live, snapshot: before, diff: SnapshotDiff(from: before, to: before), attached: false).1.filter(\.runs).map(\.stage) == [.snapshot, .attach])

        try "A new log book arrived.".write(to: url.appendingPathComponent("d9.txt"), atomically: true, encoding: .utf8)
        let after = try CorpusSources.snapshot(directory: url, slug: "tiny")
        let diff = SnapshotDiff(from: before, to: after)
        #expect(diff.summary == "1 added, 0 removed, 0 changed")
        let (changed, stages) = BuildPlanner.update(recipe, live: live, snapshot: after, diff: diff, attached: true)
        #expect(changed == .sync && stages.filter(\.runs).map(\.stage) == [.snapshot, .train, .index, .promote])
        #expect(stages.first { $0.stage == .train }?.reason == "on from v3's blocks")
        let untrained = BuildPlanner.update(recipe.training(.off), live: Self.live(source: recipe.corpus.description, snapshot: before, trained: false), snapshot: after,
                                            diff: diff, attached: true).1
        #expect(untrained.first { $0.stage == .train }.map { !$0.runs && $0.reason == "training off; the pack's blocks are indexed" } == true)
    }

    @Test("an app's records are a source of their own, app:<aii>/<app>, distinct from Braid's corpus in the same lane")
    func appSource() throws {
        let spec = try CorpusSourceSpec(parsing: "app:home/braidplayground")
        #expect(spec == .app("home/braidplayground") && spec.description == "app:home/braidplayground")
        #expect(try ThreadRecipe("harbour", corpus: "app:home/braidplayground") == ThreadRecipe("harbour", corpus: .app("home/braidplayground")))

        let url = try Self.folder(Self.texts)
        defer { try? FileManager.default.removeItem(at: url) }
        let snapshot = try CorpusSources.snapshot(directory: url, slug: "tiny")
        let live = Self.live(source: "app:home/braidplayground", snapshot: snapshot)
        #expect(BuildPlanner.refusal(ThreadRecipe("tiny", corpus: .app("home/braidplayground")), live: live) == nil)
        #expect(BuildPlanner.refusal(ThreadRecipe("tiny", corpus: .lane("home/braidplayground")), live: live)?.contains("reads app:home/braidplayground") == true)

        // Malformed addresses fail before anything is read.
        #expect(throws: BraidFailure.self) { try CorpusSources.read(.app("a/b/c"), slug: "x", limit: nil, datasetsRoot: nil, demoRoot: url) }
        #expect(throws: BraidFailure.self) { try CorpusSources.read(.app("home/aii"), slug: "x", limit: nil, datasetsRoot: nil, demoRoot: url) }
    }
}

extension BraidMLXSuites {
    @Suite("The pipeline end to end", .enabled(if: mlxTests), .serialized)
    struct PipelineBuildTests {
        @Test("a recipe builds a Thread, plans it up to date, is re-keyed, and the Thread loads and opens")
        func buildAndLoad() throws {
            guard let source = WorkArea.resolve(), let config = try? BraidConfig.load(from: source.configFile), let record = config.pack else {
                print("PIPELINE: no work area with a pack")
                return
            }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("braid-pipeline-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let area = WorkArea(root: root)
            try area.prepare()
            try FileManager.default.createSymbolicLink(at: area.pack(sha256: record.sha256), withDestinationURL: source.pack(sha256: record.sha256))
            var local = config
            local.attach = []
            try local.save(to: area.configFile)
            let pack = try Pack.load(from: area.pack(sha256: record.sha256))
            let corpus = root.appendingPathComponent("corpus", isDirectory: true)
            try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
            for (i, text) in PipelineRecipeTests.texts.enumerated() {
                try text.write(to: corpus.appendingPathComponent("d\(i).txt"), atomically: true, encoding: .utf8)
            }

            var lines: [String] = []
            let engine = BraidEngine(area: area, config: local, pack: pack) { if let line = $0.line { lines.append(line) } }
            let recipe = ThreadRecipe("tiny", corpus: .folder(corpus.path)).training(.off)
            let braid = BraidRecipe { recipe }
            #expect(try engine.plan(braid).map(\.intent) == [.create])
            let built = try engine.build(braid)
            #expect(built.count == 1 && built[0]?.version.version == 1 && built[0]?.attached == true)
            let saved = try BraidConfig.load(from: area.configFile)
            #expect(engine.config.attach == ["tiny"] && saved.attach == ["tiny"])
            #expect(lines.contains { $0.hasPrefix("thread tiny: v1 live, index ") })

            let again = try engine.plan(braid)
            #expect(again.map(\.intent) == [.upToDate] && again[0].running == [.snapshot])
            #expect(try engine.build(braid).allSatisfy { $0 == nil })
            #expect(throws: BraidFailure.self) { try engine.plan(BraidRecipe { recipe.key(.pooledState(layer: 7)) }) }

            let rekeyed = try engine.rekey("tiny", key: nil, checkpoints: .atEveryPartition)
            #expect(rekeyed.version.version == 2)
            #expect(throws: BraidFailure.self) { try engine.plan(braid) }
            #expect(try engine.plan(BraidRecipe { recipe.checkpoints(.atEveryPartition) }).map(\.intent) == [.upToDate])

            let loaded = try ThreadStore.load("tiny", in: area, pack: pack, commons: try engine.commons())
            #expect(loaded.version.version == 2)
            let tokenizer = try BraidTokenizer(folder: pack.tokenizerFolder)
            let tokens = [tokenizer.eos] + tokenizer.encode("The keeper lit the lamp")
            let steps = try loaded.node.open(session: UUID().uuidString, tokens: tokens, k: 4)
            #expect(steps.count == tokens.count && steps.last?.hits.isEmpty == false)
        }
    }
}
