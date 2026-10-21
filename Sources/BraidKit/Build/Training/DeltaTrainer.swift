//
//  DeltaTrainer.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Trains a Thread's own blocks (0..<cut) in front of the frozen trunk on its snapshot:
//        the stream eos ‖ d0 ‖ eos ‖ d1 ‖ … packed into windows on a seeded grid, resets at every
//        eos so each document starts from a zero state (the condition the index is built under),
//        AdamW with warmup then cosine, the loss masked where the input is eos. Every `evalSteps`
//        steps the whole corpus is scored document by document; the Thread has learned when 97% of
//        positions are memorised (loss < 0.1 nat) and 90% of its facts are, and training stops.
//  PIN:  RaoLM's recipe with its attention artefacts removed: no eos-first windows, no document
//        mask; the recurrent state's reset does both jobs. Backprop runs through all blocks, but
//        only blocks before the cut carry gradients.
//

import BraidCore
import Foundation
import MLX
import MLXNN
import MLXOptimizers

public struct TrainingResult {
    public var blocks: [String: MLXArray]
    public var steps: Int
    public var epochs: Int
    public var learned: Bool
    public var memorised: Float
    public var factsMemorised: Float?
    public var heldOutLoss: Float?
    public var stepRows: [StepRow]
    public var evalRows: [EvalRow]
}

/// The training stream and its seeded window grid.
public struct BatchSampler: Sendable {
    public var stream: [Int32]
    public var eos: Int32
    public var seqLen: Int
    public var batchSize: Int
    public var seed: UInt64

    /// eos ‖ d0 ‖ eos ‖ d1 ‖ … ‖ eos: one eos between documents.
    public init(corpus: TokenizedCorpus, seqLen: Int, batchSize: Int, seed: UInt64) {
        var stream: [Int32] = [corpus.eos]
        for document in corpus.documents { stream.append(contentsOf: document.tokens.dropFirst()) }
        self.stream = stream
        eos = corpus.eos
        self.seqLen = seqLen
        self.batchSize = batchSize
        self.seed = seed
    }

    public var windows: Int { max(1, (stream.count - 1) / seqLen) }
    public var stepsPerEpoch: Int { max(1, Int((Double(windows) / Double(batchSize)).rounded(.up))) }

    /// The window starts of one epoch: a seeded offset into the first window, then every seqLen, shuffled and batched.
    public func plan(epoch: Int) -> [[Int]] {
        var rng = SplitMix64(seed: seed &+ UInt64(epoch) &* 0x9E37_79B9)
        let room = max(1, min(seqLen, stream.count - seqLen - 1))
        let offset = Int(rng.next() % UInt64(room))
        var starts = Array(stride(from: offset, to: stream.count - seqLen - 1, by: seqLen))
        if starts.isEmpty { starts = [0] }
        starts.shuffle(using: &rng)
        var batches: [[Int]] = []
        var i = 0
        while i < starts.count {
            var batch = Array(starts[i ..< min(i + batchSize, starts.count)])
            var fill = 0
            while batch.count < batchSize { batch.append(starts[fill % starts.count]); fill += 1 }
            batches.append(batch)
            i += batchSize
        }
        return batches
    }

    /// inputs, targets [B,T] int32; mask [B,T] f32 (0 where the input is eos); resets [B,T] bool (the input is eos).
    public func batch(_ starts: [Int]) -> (inputs: MLXArray, targets: MLXArray, mask: MLXArray, resets: MLXArray) {
        var inputs: [Int32] = []
        var targets: [Int32] = []
        var mask: [Float] = []
        var resets: [Bool] = []
        for start in starts {
            let s = min(start, stream.count - seqLen - 1)
            for t in 0..<seqLen {
                let x = stream[s + t]
                inputs.append(x)
                targets.append(stream[s + t + 1])
                mask.append(x == eos ? 0 : 1)
                resets.append(x == eos)
            }
        }
        let shape = [starts.count, seqLen]
        return (MLXArray(inputs, shape), MLXArray(targets, shape), MLXArray(mask, shape), MLXArray(resets, shape))
    }
}

public enum DeltaTrainer {
    /// Warmup from 1% of the peak over `warmupFraction` of the plan, then cosine to the floor.
    public static func learningRate(step: Int, planned: Int, hyper: DeltaHyper) -> Float {
        let warm = max(1, Int(Float(planned) * hyper.warmupFraction))
        if step < warm { return hyper.peakLR * (0.01 + 0.99 * Float(step) / Float(warm)) }
        let progress = min(1, Float(step - warm) / Float(max(1, planned - warm)))
        return hyper.finalLR + 0.5 * (hyper.peakLR - hyper.finalLR) * (1 + cos(Float.pi * progress))
    }

    /// The eval pass: every document from a zero state; per position whether the next token is
    /// memorised (loss < memorisedNats); facts memorised when every answer token is.
    public static func evaluate(trunk: Trunk, reed: MLXReed, corpus: TokenizedCorpus, facts: [LocatedFact], hyper: DeltaHyper) -> (meanLoss: Float, memorised: Float, factsMemorised: Float?) {
        var total: Double = 0
        var count = 0
        var memorised = 0
        var lossByRow: [Int: [Float]] = [:]
        for document in corpus.documents {
            let tokens = document.tokens
            guard tokens.count >= 2 else { continue }
            let out = trunk.forward(tokens: MLXArray(tokens, [1, tokens.count]), state: nil, resets: nil)
            let logits = reed.logits(array: out.final[0, 0 ..< tokens.count - 1])
            let (loss, _) = MLXReed.tokenStats(logits: logits, targets: MLXArray(Array(tokens[1...])))
            eval(loss)
            let values = loss.asArray(Float.self)
            for t in 0 ..< tokens.count - 1 where tokens[t] != corpus.eos {
                total += Double(values[t])
                count += 1
                if values[t] < hyper.memorisedNats { memorised += 1 }
                let address = document.addresses[t + 1]
                if address.row >= 0 {
                    var row = lossByRow[address.row] ?? [Float](repeating: .infinity, count: corpus.partitions[address.row].tokens.count + corpus.breakLength)
                    if address.offset < row.count { row[address.offset] = values[t] }
                    lossByRow[address.row] = row
                }
            }
        }
        var factsMemorised: Float? = nil
        if !facts.isEmpty {
            let learned = facts.filter { fact in
                guard let row = lossByRow[fact.row] else { return false }
                return (fact.answerToken ..< fact.answerEndToken).allSatisfy { $0 < row.count && row[$0] < hyper.memorisedNats }
            }.count
            factsMemorised = Float(learned) / Float(facts.count)
        }
        Memory.clearCache()
        return (count > 0 ? Float(total / Double(count)) : 0, count > 0 ? Float(memorised) / Float(count) : 0, factsMemorised)
    }

    /// Trains the trunk's own blocks in place; returns them with the run's record.
    public static func train(trunk: Trunk, reed: MLXReed, corpus: TokenizedCorpus, facts: [LocatedFact], hyper: DeltaHyper, continuing: Bool,
                             shouldStop: () -> Bool = { false }, onEvent: (TrainingEvent) -> Void = { _ in }) throws -> TrainingResult {
        Memory.cacheLimit = hyper.cacheLimitMB * 1_048_576
        let sampler = BatchSampler(corpus: corpus, seqLen: hyper.seqLen, batchSize: hyper.batchSize, seed: hyper.seed)
        let planned = continuing ? hyper.continueSteps : hyper.scratchSteps
        let epochs = min(hyper.maxEpochs, max(8, Int((Double(planned) / Double(sampler.stepsPerEpoch)).rounded(.up))))
        let evalEvery = max(1, hyper.evalSteps / sampler.stepsPerEpoch)
        onEvent(.note("stream \(sampler.stream.count) tokens, \(sampler.windows) windows of \(hyper.seqLen), \(sampler.stepsPerEpoch) steps/epoch, \(epochs) epochs planned, eval every \(evalEvery) epochs"))
        let optimizer = AdamW(learningRate: hyper.peakLR, betas: (hyper.beta1, hyper.beta2), eps: hyper.eps, weightDecay: hyper.weightDecay, biasCorrection: true)
        let hiddenSize = trunk.config.hiddenSize
        func loss(_ model: Trunk, _ arrays: [MLXArray]) -> [MLXArray] {
            let out = model.forward(tokens: arrays[0], state: nil, resets: arrays[3], training: true)
            let logits = reed.logits(array: out.final.reshaped([-1, hiddenSize]))
            let (perToken, _) = MLXReed.tokenStats(logits: logits, targets: arrays[1].reshaped([-1]))
            let mask = arrays[2].reshaped([-1])
            return [(perToken * mask).sum() / maximum(mask.sum(), MLXArray(Float(1)))]
        }
        let lossAndGrad = valueAndGrad(model: trunk, loss)
        var stepRows: [StepRow] = []
        var evalRows: [EvalRow] = []
        var step = 0
        var learned = false
        var lastEval: (Float, Float, Float?) = (0, 0, nil)
        let started = Date()
        epochLoop: for epoch in 0..<epochs {
            for starts in sampler.plan(epoch: epoch) {
                if shouldStop() { break epochLoop }
                let lr = learningRate(step: step, planned: planned, hyper: hyper)
                optimizer.learningRate = lr
                let batch = sampler.batch(starts)
                let (values, gradients) = lossAndGrad(trunk, [batch.inputs, batch.targets, batch.mask, batch.resets])
                let (clipped, norm) = clipGradNorm(gradients: gradients, maxNorm: hyper.gradClip)
                optimizer.update(model: trunk, gradients: clipped)
                eval(trunk, optimizer, values[0], norm)
                step += 1
                let row = StepRow(epoch: epoch, step: step, lr: lr, loss: values[0].item(Float.self), gradNorm: norm.item(Float.self),
                                  tokens: starts.count * hyper.seqLen, seconds: Date().timeIntervalSince(started))
                stepRows.append(row)
                onEvent(.step(row))
            }
            if (epoch + 1) % evalEvery == 0 || epoch == epochs - 1 {
                lastEval = evaluate(trunk: trunk, reed: reed, corpus: corpus, facts: facts, hyper: hyper)
                learned = lastEval.1 >= hyper.learnedThreshold && (lastEval.2 ?? 1) >= hyper.factsThreshold
                let row = EvalRow(epoch: epoch, step: step, meanLoss: lastEval.0, memorised: lastEval.1, factsMemorised: lastEval.2, learned: learned)
                evalRows.append(row)
                onEvent(.eval(row))
                if learned { break }
            }
        }
        let flat = trunk.flattenedParameters()
        let blocks = Dictionary(uniqueKeysWithValues: flat.filter { Trunk.blockIndex(ofKey: $0.0).map { $0 < trunk.config.cut } ?? false })
        return TrainingResult(blocks: blocks, steps: step, epochs: evalRows.last.map { $0.epoch + 1 } ?? 0, learned: learned, memorised: lastEval.1,
                              factsMemorised: lastEval.2, heldOutLoss: nil, stepRows: stepRows, evalRows: evalRows)
    }
}
