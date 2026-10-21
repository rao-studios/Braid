//
//  Stages.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The stages after a Thread's snapshot, each one step of the build reading and writing one
//        shared context: train the Thread's own blocks, key and write the index, write the
//        version's record and make it live, attach the Thread to the braid. The engine composes
//        them per intent; each wraps the Build/ code that does the work.
//  PIN:  The progress lines are the ones `braid thread` has always printed, byte for byte: a new
//        Thread's training lines and a sync's differ, and only a created Thread announces
//        "vN live". Training rows are written for a Thread trained from scratch only.
//

import BraidCore
import Foundation
import MLX

/// What one build carries from stage to stage.
final class BuildContext {
    let name: String
    let layout: ThreadLayout
    let threadID: String
    let snapshot: CorpusSnapshot
    let facts: [Fact]
    let key: KeyScheme
    let checkpoints: CheckpointPolicy
    /// The documents left out of the index, read when the index stage needs them.
    let exclude: () throws -> Set<String>
    let trunk: Trunk
    /// The live version a sync or a re-key starts from; nil for a new Thread.
    let live: ThreadVersionInfo?
    let started: Date

    var blocks: [String: MLXArray]?
    var totals: TrainingTotals?
    var corpus: TokenizedCorpus?
    var written: WrittenIndex?
    var version: ThreadVersionInfo?
    var seconds: Double?

    init(name: String, layout: ThreadLayout, threadID: String, snapshot: CorpusSnapshot, facts: [Fact], key: KeyScheme, checkpoints: CheckpointPolicy,
         exclude: @escaping () throws -> Set<String>, trunk: Trunk, live: ThreadVersionInfo?, started: Date) {
        self.name = name
        self.layout = layout
        self.threadID = threadID
        self.snapshot = snapshot
        self.facts = facts
        self.key = key
        self.checkpoints = checkpoints
        self.exclude = exclude
        self.trunk = trunk
        self.live = live
        self.started = started
    }

    /// The snapshot tokenized once, for training and the index alike.
    func tokenizedCorpus(_ tokenizer: BraidTokenizer) -> TokenizedCorpus {
        if let corpus { return corpus }
        let made = TokenizedCorpus(snapshot: snapshot, tokenizer: tokenizer, paragraphBreak: tokenizer.paragraphBreak, threadID: threadID)
        corpus = made
        return made
    }
}

protocol BuildStage {
    var name: StageName { get }
    func run(_ context: BuildContext, in engine: BraidEngine) throws
}

/// Trains blocks 0..<cut in place on the context's trunk: from the pack's blocks for a new Thread,
/// on from the live version's when continuing.
struct TrainStage: BuildStage {
    let plan: TrainingPlan
    let seed: UInt64
    let continuing: Bool
    var name: StageName { .train }

    func run(_ c: BuildContext, in engine: BraidEngine) throws {
        let name = c.name
        let tokenizer = try engine.tokenizer()
        let corpus = c.tokenizedCorpus(tokenizer)
        let located = FactLocator.locate(c.facts, corpus: corpus, byteOffsets: tokenizer.byteOffsets).located
        let hyper = plan.hyper(continuing: continuing, seed: seed)
        let reed = try engine.reed()
        if continuing {
            let from = c.blocks == nil ? "the pack's blocks" : "v\(c.live?.version ?? 0)'s blocks"
            engine.note("thread \(name): training on from \(from), \(hyper.continueSteps) steps planned, \(corpus.tokenCount) tokens")
        } else {
            engine.note("thread \(name): training blocks 0..<\(engine.pack.config.cut) on \(corpus.tokenCount) tokens, \(located.count) facts located")
        }
        let continuing = self.continuing
        let result = try DeltaTrainer.train(trunk: c.trunk, reed: reed, corpus: corpus, facts: located, hyper: hyper, continuing: continuing) { event in
            switch event {
            case .note(let text): engine.note("thread \(name): \(text)")
            case .step(let row):
                guard row.step % 10 == 0 || row.step <= 3 else { return }
                if continuing {
                    engine.note(String(format: "thread \(name): step %d  loss %.3f  lr %.2e  %.1f s", row.step, row.loss, row.lr, row.seconds))
                } else {
                    engine.note(String(format: "thread \(name): step %d  loss %.3f  lr %.2e  |g| %.2f  %.1f s", row.step, row.loss, row.lr, row.gradNorm, row.seconds))
                }
            case .eval(let row):
                if continuing {
                    engine.note(String(format: "thread \(name): eval step %d  loss %.3f  memorised %.1f%%%@", row.step, row.meanLoss, row.memorised * 100, row.learned ? "  → learned" : ""))
                } else {
                    engine.note(String(format: "thread \(name): eval epoch %d step %d  loss %.3f  memorised %.1f%%  facts %@%@", row.epoch + 1, row.step, row.meanLoss, row.memorised * 100,
                                       row.factsMemorised.map { String(format: "%.0f%%", $0 * 100) } ?? "—", row.learned ? "  → learned" : ""))
                }
            }
        }
        c.blocks = result.blocks
        if continuing, let live = c.live {
            c.totals = TrainingTotals(steps: live.steps + result.steps, epochs: live.epochs + result.epochs, learned: result.learned, heldOutLoss: result.heldOutLoss)
        } else {
            c.totals = TrainingTotals(steps: result.steps, epochs: result.epochs, learned: result.learned, heldOutLoss: result.heldOutLoss)
            try JSONLWriter(url: c.layout.root.appendingPathComponent("training-steps.jsonl"), truncate: true).appendAll(result.stepRows)
            try JSONLWriter(url: c.layout.root.appendingPathComponent("training-evals.jsonl"), truncate: true).appendAll(result.evalRows)
        }
    }
}

/// Keys the snapshot on the context's trunk into a new version's directory, with its blocks when
/// they are the Thread's own.
struct IndexStage: BuildStage {
    var name: StageName { .index }

    func run(_ c: BuildContext, in engine: BraidEngine) throws {
        let exclude = try c.exclude()
        let corpus = c.tokenizedCorpus(try engine.tokenizer())
        c.written = try ThreadStore.writeIndex(c.layout, pack: engine.pack, trunk: c.trunk, reed: try engine.reed(), corpus: corpus, threadID: c.threadID, scheme: c.key,
                                               blocks: c.blocks, checkpoints: c.checkpoints, exclude: exclude) { engine.note("thread \(c.name): \($0)") }
    }
}

/// Writes the version's record and makes it live; a created Thread announces it.
struct PromoteStage: BuildStage {
    let announce: Bool
    var name: StageName { .promote }

    func run(_ c: BuildContext, in engine: BraidEngine) throws {
        guard let written = c.written else { throw BraidFailure.data("thread \(c.name): nothing was indexed to promote") }
        let version = try ThreadStore.writeVersion(written, pack: engine.pack, snapshot: c.snapshot, scheme: c.key, training: c.totals)
        try ThreadStore.promote(c.layout, version: version.version)
        c.version = version
        let seconds = Date().timeIntervalSince(c.started)
        c.seconds = seconds
        guard announce else { return }
        engine.note(String(format: "thread \(c.name): v%d live, index %@ (%d entries), memorised %.1f%%, mean loss %.3f, %.1f s", version.version,
                           String(version.indexSHA256.prefix(12)), version.entries, version.memorised * 100, version.meanLoss, seconds))
    }
}

/// Adds the Thread to `[cluster] attach` in braid.toml, saving it only when the list changes.
struct AttachStage: BuildStage {
    var name: StageName { .attach }

    func run(_ c: BuildContext, in engine: BraidEngine) throws {
        try engine.attach(c.name)
    }
}
