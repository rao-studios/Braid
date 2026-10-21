//
//  TrainingPlan.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Whether a Thread's own blocks are trained, and any budget the recipe sets. A new Thread
//        trains from the pack's blocks on the scratch budget; an existing one trains on from its
//        live blocks on the continuing budget. Unset numbers keep DeltaHyper's.
//  PIN:  No case is named `none`: `.training(.none)` would read as Optional.none.
//

import Foundation

public enum TrainingPlan: Sendable, Equatable {
    /// Index on the blocks the Thread has (the pack's, or the live version's), without training.
    case off
    /// Train: `steps` planned (the scratch budget for a new Thread, the continuing one after),
    /// with the batch size and window length given.
    case on(steps: Int? = nil, batchSize: Int? = nil, seqLen: Int? = nil)

    /// DeltaHyper's budget.
    public static let standard = TrainingPlan.on()

    public var trains: Bool {
        if case .on = self { return true }
        return false
    }

    /// The hyperparameters for one run: DeltaHyper's, with the plan's numbers and the seed applied.
    func hyper(continuing: Bool, seed: UInt64) -> DeltaHyper {
        var hyper = DeltaHyper()
        hyper.seed = seed
        guard case .on(let steps, let batchSize, let seqLen) = self else { return hyper }
        if let steps {
            if continuing { hyper.continueSteps = steps } else { hyper.scratchSteps = steps }
        }
        if let batchSize { hyper.batchSize = batchSize }
        if let seqLen { hyper.seqLen = seqLen }
        return hyper
    }
}
