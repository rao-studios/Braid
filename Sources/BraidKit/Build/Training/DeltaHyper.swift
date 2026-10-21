//
//  DeltaHyper.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: What a training run is told and what it reports, as plain values: the hyperparameters
//        (DeltaHyper), one optimizer step's row, one evaluation's row, and the events the trainer
//        hands its caller. The rows are what training-steps.jsonl and training-evals.jsonl hold.
//

import Foundation

public struct DeltaHyper: Codable, Sendable, Equatable {
    public var seqLen = 512
    public var batchSize = 8
    public var peakLR: Float = 5e-4
    public var finalLR: Float = 1e-4
    public var warmupFraction: Float = 0.05
    public var beta1: Float = 0.9
    public var beta2: Float = 0.95
    public var eps: Float = 1e-8
    public var weightDecay: Float = 0.01
    public var gradClip: Float = 1.0
    /// Optimizer steps planned from fresh blocks, and when continuing from a trained version.
    public var scratchSteps = 1000
    public var continueSteps = 500
    public var evalSteps = 40
    public var learnedThreshold: Float = 0.97
    public var factsThreshold: Float = 0.90
    public var memorisedNats: Float = 0.1
    public var maxEpochs = 600
    public var cacheLimitMB = 8192
    public var seed: UInt64 = 42

    public init() {}
}

public struct StepRow: Codable, Sendable {
    public var epoch: Int
    public var step: Int
    public var lr: Float
    public var loss: Float
    public var gradNorm: Float
    public var tokens: Int
    public var seconds: Double
}

public struct EvalRow: Codable, Sendable {
    public var epoch: Int
    public var step: Int
    public var meanLoss: Float
    public var memorised: Float
    public var factsMemorised: Float?
    public var learned: Bool
}

public enum TrainingEvent: Sendable {
    case step(StepRow)
    case eval(EvalRow)
    case note(String)
}
