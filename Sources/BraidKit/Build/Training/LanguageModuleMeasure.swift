//
//  LanguageModuleMeasure.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: `braid init --measure`: what the language module costs on this machine before anything is
//        trained — forward tokens per second, one training step (forward and backward through every
//        block, gradients for the Thread's blocks only, clipped, AdamW) in seconds, and the peak
//        memory — at each batch × length the plan names, for each scan chunk size.
//

import BraidCore
import Foundation
import MLX
import MLXNN
import MLXOptimizers

public struct MeasureRow: Codable, Sendable, Equatable {
    public var batch: Int
    public var length: Int
    public var chunk: Int
    public var forwardTokensPerSecond: Double
    public var stepSeconds: Double
    public var peakGB: Double
}

public struct MeasureReport: Codable, Sendable, Equatable {
    public var bench = "measure"
    public var createdAt: Date
    public var pack: String
    public var device: String
    public var rows: [MeasureRow]
}

public enum LanguageModuleMeasure {
    public static let shapes: [(batch: Int, length: Int)] = [(4, 512), (8, 512), (4, 1024), (8, 1024)]
    public static let chunks = [256, 128]

    public static func run(pack: Pack, vocabTokens: Int, shapes: [(batch: Int, length: Int)] = shapes, chunks: [Int] = chunks, repeats: Int = 3,
                           progress: (String) -> Void = { _ in }) throws -> MeasureReport {
        var rows: [MeasureRow] = []
        let reed = pack.reed(tokens: vocabTokens)
        let commons = try LanguageModule(pack: pack)                                                 // the tail every shape's head runs behind
        for chunk in chunks {
            for shape in shapes {
                let languageModule = LanguageModule(head: try LanguageModule.packHead(pack), tail: commons.tail)
                languageModule.config.chunkSize = chunk
                eval(languageModule)
                var rng = SplitMix64(seed: 42)
                let ids = (0 ..< shape.batch * shape.length).map { _ in Int32(1 + rng.next() % UInt64(max(2, vocabTokens - 1))) }
                let tokens = MLXArray(ids, [shape.batch, shape.length])
                let targets = MLXArray(Array(ids.dropFirst()) + [0], [shape.batch, shape.length])
                let mask = MLXArray.ones([shape.batch, shape.length], dtype: .float32)
                let resets = MLXArray.zeros([shape.batch, shape.length], dtype: .bool)
                Memory.clearCache()
                Memory.peakMemory = 0

                // Forward only, as the index builder and the node run it.
                var out = languageModule.forward(tokens: tokens, state: nil, resets: nil)
                eval(out.final)
                var started = Date()
                for _ in 0 ..< repeats {
                    out = languageModule.forward(tokens: tokens, state: nil, resets: nil)
                    eval(out.final)
                }
                let forwardSeconds = Date().timeIntervalSince(started) / Double(repeats)

                // One training step, as DeltaTrainer runs it.
                let hidden = languageModule.config.hiddenSize
                func loss(_ model: LanguageModule, _ arrays: [MLXArray]) -> [MLXArray] {
                    let out = model.forward(tokens: arrays[0], state: nil, resets: arrays[3], training: true)
                    let logits = reed.logits(array: out.final.reshaped([-1, hidden]))
                    let (perToken, _) = MLXReed.tokenStats(logits: logits, targets: arrays[1].reshaped([-1]))
                    let m = arrays[2].reshaped([-1])
                    return [(perToken * m).sum() / maximum(m.sum(), MLXArray(Float(1)))]
                }
                let lossAndGrad = valueAndGrad(model: languageModule, loss)
                let optimizer = AdamW(learningRate: 1e-5, betas: (0.9, 0.95), eps: 1e-8, weightDecay: 0.01, biasCorrection: true)
                func step() {
                    let (values, gradients) = lossAndGrad(languageModule, [tokens, targets, mask, resets])
                    let (clipped, norm) = clipGradNorm(gradients: gradients, maxNorm: 1)
                    optimizer.update(model: languageModule, gradients: clipped)
                    eval(languageModule, optimizer, values[0], norm)
                }
                step()
                started = Date()
                for _ in 0 ..< repeats { step() }
                let stepSeconds = Date().timeIntervalSince(started) / Double(repeats)
                let row = MeasureRow(batch: shape.batch, length: shape.length, chunk: chunk,
                                     forwardTokensPerSecond: Double(shape.batch * shape.length) / forwardSeconds, stepSeconds: stepSeconds,
                                     peakGB: Double(Memory.peakMemory) / 1_073_741_824)
                rows.append(row)
                progress(String(format: "B %d · L %d · chunk %d: forward %.0f tokens/s · step %.2f s · peak %.1f GB", row.batch, row.length, row.chunk,
                                row.forwardTokensPerSecond, row.stepSeconds, row.peakGB))
                Memory.clearCache()
            }
        }
        return MeasureReport(createdAt: Date(), pack: pack.sha256, device: ProcessInfo.processInfo.hostName, rows: rows)
    }
}
