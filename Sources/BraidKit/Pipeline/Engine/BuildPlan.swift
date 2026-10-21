//
//  BuildPlan.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: What building a recipe would do, before anything is built: whether the Thread is created,
//        synced from a changed source, or already up to date, and which stages run and why. A
//        plan reads the work area and the source; it never touches MLX, so it is cheap to ask for
//        and safe to show.
//  PIN:  For a Thread that exists, a recipe may only restate what its live version already is
//        (source, limit, label, key, checkpoints, a withheld set), so a build never changes a
//        Thread in a way the CLI's own commands would not. Anything else is refused with the
//        reason, before the first MLX workload.
//

import BraidCore
import Foundation

public enum BuildIntent: String, Sendable {
    case create
    case sync
    case upToDate = "up to date"
}

public struct StageDecision: Sendable, Equatable {
    public var stage: StageName
    public var runs: Bool
    public var reason: String

    public init(_ stage: StageName, runs: Bool, _ reason: String) {
        self.stage = stage
        self.runs = runs
        self.reason = reason
    }
}

public struct BuildPlan {
    public var name: String
    public var intent: BuildIntent
    public var stages: [StageDecision]
    /// For a Thread that exists: what changed in its source since the live snapshot.
    public var diff: SnapshotDiff?
    /// The source as the plan read it; the build uses it rather than reading again.
    let read: SourceRead
    let existing: ExistingThread?

    /// The stages that run.
    public var running: [StageName] { stages.filter(\.runs).map(\.stage) }

    /// One line for the Thread, then one per stage.
    public var summary: String {
        ([name + ": " + intent.rawValue] + stages.map { decision in
            "  " + decision.stage.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0) + (decision.runs ? "runs   " : "skips  ") + decision.reason
        }).joined(separator: "\n")
    }
}

/// A Thread that exists, as the build reads it: its layout, its record, its live version and the
/// snapshot that version indexed.
struct ExistingThread {
    var layout: ThreadLayout
    var info: ThreadInfo
    var live: ThreadVersionInfo
    var current: CorpusSnapshot
}

/// What the planner reads of a Thread's live version beyond its record: the documents it withholds
/// and the checkpoint policy its index was built with.
struct LiveThread: Equatable {
    var info: ThreadInfo
    var version: ThreadVersionInfo
    var withheld: Set<String>
    var checkpoints: CheckpointPolicy
}

/// The decisions, as pure functions of what is on disk and what the source holds.
enum BuildPlanner {
    /// Why a recipe cannot be built over the Thread that exists, or nil. Checked before the source is read.
    static func refusal(_ recipe: ThreadRecipe, live: LiveThread) -> String? {
        let name = recipe.name
        let settings = recipe.settings
        let version = live.version
        if recipe.corpus.description != live.info.source {
            return "thread \(name) reads \(live.info.source), not \(recipe.corpus.description)"
        }
        if let limit = settings.limit, limit != live.info.limit {
            return "thread \(name) takes \(live.info.limit.map { "the first \($0) documents" } ?? "every document"), not the first \(limit)"
        }
        if let label = settings.label, label != live.info.label {
            return "thread \(name) is labelled \(live.info.label), not \(label)"
        }
        if let key = settings.key, key != version.keyScheme {
            return "thread \(name) v\(version.version) is keyed \(version.keyScheme), not \(key); braid thread index re-keys it"
        }
        if settings.checkpoints != live.checkpoints {
            return "thread \(name) v\(version.version) has \(describe(live.checkpoints)), not \(describe(settings.checkpoints)); braid thread index re-keys it"
        }
        if settings.withhold != nil, live.withheld.isEmpty {
            return "thread \(name) withholds no documents; a withheld set is drawn only when a Thread is created"
        }
        return nil
    }

    /// The stages for a new Thread.
    static func create(_ recipe: ThreadRecipe, snapshot: CorpusSnapshot, key: KeyScheme, attached: Bool) -> [StageDecision] {
        let settings = recipe.settings
        return [
            StageDecision(.snapshot, runs: true, "\(snapshot.documentCount) documents, \(snapshot.partitionCount) partitions from \(recipe.corpus.description)"),
            settings.training.trains ? StageDecision(.train, runs: true, "from the pack's blocks") : StageDecision(.train, runs: false, "training off; the pack's blocks are indexed"),
            StageDecision(.index, runs: true, "keyed \(key), \(describe(settings.checkpoints))"),
            StageDecision(.promote, runs: true, "v1 made live"),
            attach(settings, attached: attached),
        ]
    }

    /// The stages for a Thread that exists, once its source has been read again.
    static func update(_ recipe: ThreadRecipe, live: LiveThread, snapshot: CorpusSnapshot, diff: SnapshotDiff, attached: Bool) -> (BuildIntent, [StageDecision]) {
        let settings = recipe.settings
        let version = live.version
        guard snapshot.corpusHash != version.corpusHash else {
            return (.upToDate, [
                StageDecision(.snapshot, runs: true, "\(live.info.source) unchanged (corpus \(version.corpusHash.prefix(12)))"),
                StageDecision(.train, runs: false, "the corpus is unchanged"),
                StageDecision(.index, runs: false, "the corpus is unchanged"),
                StageDecision(.promote, runs: false, "v\(version.version) stays live"),
                attach(settings, attached: attached),
            ])
        }
        let blocks = version.trained ? "v\(version.version)'s blocks" : "the pack's blocks"
        return (.sync, [
            StageDecision(.snapshot, runs: true, "\(live.info.source) changed: \(diff.summary)"),
            settings.training.trains ? StageDecision(.train, runs: true, "on from \(blocks)") : StageDecision(.train, runs: false, "training off; \(blocks) are indexed"),
            StageDecision(.index, runs: true, "keyed \(version.keyScheme), \(describe(settings.checkpoints))"),
            StageDecision(.promote, runs: true, "a new version made live"),
            attach(settings, attached: attached),
        ])
    }

    static func attach(_ settings: ThreadRecipe.Settings, attached: Bool) -> StageDecision {
        guard settings.attach else { return StageDecision(.attach, runs: false, "not asked") }
        return attached ? StageDecision(.attach, runs: false, "already in [cluster] attach") : StageDecision(.attach, runs: true, "added to [cluster] attach")
    }

    static func describe(_ policy: CheckpointPolicy) -> String {
        policy.everyPartition ? "a checkpoint at every partition" : "a checkpoint every \(policy.strideTokens) tokens"
    }
}
