//
//  ProvenanceKey.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The two-point provenance key on a recurrent language module: K = [√α·mid/‖mid‖,
//        √(1−α)·final/‖final‖], final the normed last-layer state (the node's public output), mid
//        one of the sweep's attributes — the residual stream after n blocks (the default, the
//        closest analog of RaoLM's tap), the per-channel energy of a layer's recurrent state, or
//        that state's per-channel change. The scheme a version was keyed with is recorded in
//        index.json.
//

import BraidCore
import Foundation
import MLX

public enum ProvenanceKey {
    public static let alpha: Float = 0.5
    public static let eps: Float = 1e-6

    /// Unit-normalises the last axis.
    public static func normalized(_ x: MLXArray) -> MLXArray {
        let norms = sqrt((x * x).sum(axis: -1, keepDims: true)) + eps
        return x / norms
    }

    /// [√α·mid/‖mid‖, √(1−α)·final/‖final‖] along the last axis, f32.
    public static func make(mid: MLXArray, final: MLXArray, alpha: Float = alpha) -> MLXArray {
        concatenated([normalized(mid.asType(.float32)) * sqrt(alpha), normalized(final.asType(.float32)) * sqrt(1 - alpha)], axis: -1)
    }

    /// The mid half for a scheme from a language module's output over a sequence ([…,L,·]).
    public static func mid(scheme: KeyScheme, output: LanguageModuleOutput, previousState: StateStack?) -> MLXArray {
        switch scheme {
        case .residual(let n):
            guard let residual = output.residual[n] else { fatalError("the language module did not tap block \(n)") }
            return residual
        case .pooledState(let layer):
            // Only the final state is available per call; a sequence of pooled states needs the
            // per-position scan (the sweep's harness provides it). Here: the state after the sequence.
            return energy(output.state.layers[layer].ssm)
        case .stateDelta(let layer):
            let now = output.state.layers[layer].ssm
            let before = previousState?.layers[layer].ssm ?? MLXArray.zeros(like: now)
            return energy(now - before)
        }
    }

    /// ‖S[h,p,:]‖₂ per channel: [B,H,P,N] → [B,H·P].
    public static func energy(_ state: MLXArray) -> MLXArray {
        let e = sqrt((state * state).sum(axis: -1))
        return e.reshaped([e.dim(0), e.dim(1) * e.dim(2)])
    }
}
