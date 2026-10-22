//
//  SegmentKeys.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The key's two halves at every position of one state-carrying segment, under any key
//        scheme. The index builder, the replay and the key sweep all key text through it.
//

import BraidCore
import Foundation
import MLX

/// The per-position halves of a key over one state-carrying segment, for every scheme. Residual
/// schemes come from one chunked forward; the pooled-state schemes need the recurrent state at
/// every position, which the chunked scan does not materialise, so they step the language module token by
/// token (the same recurrence the live node runs).
public enum SegmentKeys {
    public struct Output {
        /// [q, D]: the normed final state at each position.
        public var final: MLXArray
        /// [q, M]: the scheme's mid half at each position.
        public var mid: MLXArray
        /// The state after the segment.
        public var state: StateStack
    }

    public static func run(languageModule: LanguageModule, segment: [Int32], state: StateStack?, scheme: KeyScheme) -> Output {
        switch scheme {
        case .residual(let n):
            let out = languageModule.forward(tokens: MLXArray(segment, [1, segment.count]), state: state, resets: nil, taps: scheme.taps)
            return Output(final: out.final[0], mid: out.residual[n]![0], state: out.state)
        case .pooledState(let layer), .stateDelta(let layer):
            // The final half from one chunked forward that also taps the input to block `layer`; that
            // block alone is then stepped over the segment for its state at every position. The
            // stepped recurrence equals the chunked scan (SSDTests), so the two halves agree.
            let out = languageModule.forward(tokens: MLXArray(segment, [1, segment.count]), state: state, resets: nil, taps: TapRequest(residualAfterBlocks: [layer]))
            let input = out.residual[layer]![0]                                                        // [q, D]
            let block = languageModule.backbone.layers[layer]
            var current = state?.layers[layer] ?? LayerState.zeros(config: languageModule.config, batch: 1)
            var mids: [MLXArray] = []
            for t in 0 ..< segment.count {
                let previous = current.ssm
                let (_, next) = block.step(input[t ..< t + 1], state: current, reset: nil)
                current = next
                switch scheme {
                case .stateDelta: mids.append(ProvenanceKey.energy(next.ssm - previous))
                default: mids.append(ProvenanceKey.energy(next.ssm))
                }
                if t % 64 == 63 { eval(current.conv, current.ssm) }
            }
            let mid = concatenated(mids, axis: 0)
            eval(mid)
            return Output(final: out.final[0], mid: mid, state: out.state)
        }
    }

    /// The unit key at the segment's last position ([K]).
    public static func lastKey(languageModule: LanguageModule, segment: [Int32], state: StateStack?, scheme: KeyScheme, alpha: Float) -> MLXArray {
        let out: Output
        switch scheme {
        case .residual:
            out = run(languageModule: languageModule, segment: segment, state: state, scheme: scheme)
        case .pooledState, .stateDelta:
            // Only the last position's state (and the one before it) are needed: forward to it, step once.
            var current = state ?? StateStack.zeros(config: languageModule.config, batch: 1)
            if segment.count > 1 { current = languageModule.forward(tokens: MLXArray(Array(segment.dropLast()), [1, segment.count - 1]), state: current, resets: nil).state }
            let previous = current
            let step = languageModule.step(token: MLXArray([segment[segment.count - 1]]), state: current, reset: nil)
            out = Output(final: step.final, mid: ProvenanceKey.mid(scheme: scheme, output: step, previousState: previous), state: step.state)
        }
        let q = out.final.dim(0)
        let key = ProvenanceKey.make(mid: out.mid[(q - 1)...], final: out.final[(q - 1)...], alpha: alpha)
        eval(key)
        return key.reshaped([-1])
    }
}
