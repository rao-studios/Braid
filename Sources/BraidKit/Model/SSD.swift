//
//  SSD.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The selective state-space scan in its structured-state-space-duality form (Mamba2): per
//        chunk a lower-triangular surrogate attention over the chunk, a carry-in from the state the
//        chunk entered with and a carry-out to the state it leaves; one token at a time, the
//        recurrence itself. Plus the depthwise causal convolution that feeds it, as shifted
//        multiplies. All plain MLX ops: differentiable, no eval anywhere, so a training step traces
//        through it.
//  PIN:  `resets` zero the state (and the conv window) before the position they mark, so packed
//        documents are processed exactly as each would be alone — the same condition the index is
//        built under. The math is Frigate's `ssmAttn` (a port of mlx-lm's ssm.py) without its
//        asyncEval calls, which MLX forbids inside a gradient trace. Decays are exp of sums of
//        non-positive numbers, so nothing overflows.
//

import Foundation
import MLX
import MLXNN

public enum SSD {
    /// softplus(dt + bias) clipped to the config's limits, in float32.
    public static func discretize(_ dt: MLXArray, bias: MLXArray, limits: (Float, Float)) -> MLXArray {
        var out = softplus(dt.asType(.float32) + bias)
        if limits.0 > 0 || limits.1.isFinite { out = clip(out, min: limits.0, max: limits.1) }
        return out
    }

    /// For x […, q]: out[…, t, s] = Σ_{r=s+1}^{t} x_r for t ≥ s (0 on the diagonal), −inf above it.
    public static func segsum(_ x: MLXArray) -> MLXArray {
        let q = x.dim(-1)
        var y = repeated(x[.ellipsis, .newAxis], count: q, axis: -1)     // […, q, q]: y[…, r, s] = x_r
        y = tril(y, k: -1)                                               // keep r > s
        var out = cumsum(y, axis: -2)                                    // out[…, t, s] = Σ_{r ≤ t, r > s} x_r
        let mask = tril(MLXArray.ones([q, q], dtype: .bool), k: 0)
        out = MLX.where(mask, out, MLXArray(-Float.infinity))
        return out
    }

    /// The chunked scan. x [B,L,H,P], dt [B,L,H] (raw), aLog [H], B/C [B,L,G,N], D [H], dtBias [H],
    /// state [B,H,P,N] or nil (zeros), resets [B,L] bool or nil. Returns y [B,L,H,P] (the D skip
    /// included) and the state after the last position.
    public static func scan(x: MLXArray, dt: MLXArray, aLog: MLXArray, B: MLXArray, C: MLXArray, D: MLXArray, dtBias: MLXArray, limits: (Float, Float),
                            state: MLXArray?, resets: MLXArray?, chunk: Int = 256) -> (y: MLXArray, state: MLXArray) {
        let (b, l, h, p) = (x.dim(0), x.dim(1), x.dim(2), x.dim(3))
        let g = B.dim(2)
        let n = B.dim(3)
        let repeats = h / g
        let dtv = discretize(dt, bias: dtBias, limits: limits)                       // [B,L,H]
        let a = -exp(aLog.asType(.float32))                                         // [H]
        let dtA = dtv * a.reshaped([1, 1, h])                                        // [B,L,H]
        let dtx = dtv[.ellipsis, .newAxis] * x.asType(.float32)                      // [B,L,H,P]
        let segments: MLXArray? = resets.map { cumsum($0.asType(.int32), axis: 1) }  // [B,L] inclusive
        var s = state?.asType(.float32) ?? MLXArray.zeros([b, h, p, n], dtype: .float32)
        var ys: [MLXArray] = []
        var start = 0
        while start < l {
            let q = min(chunk, l - start)
            let range = start ..< start + q
            let dtAc = dtA[0..., range].swappedAxes(1, 2)                            // [B,H,q]
            let cs = cumsum(dtAc, axis: -1)                                          // [B,H,q]
            var decay = exp(segsum(dtAc))                                             // [B,H,q,q]
            var keepIn: MLXArray? = nil                                               // [B,1,q,1]
            var keepOut: MLXArray? = nil                                              // [B,1,q,1]
            var carryKeep: MLXArray? = nil                                            // [B,1,1,1]
            if let segments, let resets {
                let seg = segments[0..., range]                                       // [B,q]
                let same = seg[0..., 0..., .newAxis] .== seg[0..., .newAxis, 0...]   // [B,q,q]
                decay = MLX.where(same[0..., .newAxis, 0..., 0...], decay, MLXArray(Float(0)))
                let entering = seg[0..., 0] - resets[0..., start].asType(.int32)     // [B]: the segment the chunk's state belongs to
                keepIn = (seg .== entering[0..., .newAxis]).asType(.float32)[0..., .newAxis, 0..., .newAxis]
                keepOut = (seg .== seg[0..., (q - 1)...]).asType(.float32)[0..., .newAxis, 0..., .newAxis]
                carryKeep = (entering .== seg[0..., q - 1]).asType(.float32)[0..., .newAxis, .newAxis, .newAxis]
            }
            let bc = repeated(B[0..., range], count: repeats, axis: 2).swappedAxes(1, 2).asType(.float32)   // [B,H,q,N]
            let cc = repeated(C[0..., range], count: repeats, axis: 2).swappedAxes(1, 2).asType(.float32)   // [B,H,q,N]
            let cb = matmul(cc, bc.swappedAxes(2, 3))                                                      // [B,H,q,q]: C_t·B_s
            let m = tril(cb * decay, k: 0)
            let dtxc = dtx[0..., range].swappedAxes(1, 2)                                                   // [B,H,q,P]
            var y = matmul(m, dtxc)                                                                        // [B,H,q,P]
            // Carry-in: the state the chunk entered with, decayed through each position.
            var decayIn = exp(cs)[.ellipsis, .newAxis]                                                     // [B,H,q,1]
            if let keepIn { decayIn = decayIn * keepIn }
            let fromState = matmul(s, cc.swappedAxes(2, 3)).swappedAxes(2, 3)                               // [B,H,q,P]
            y = y + decayIn * fromState
            // Carry-out: every position's input decayed to the chunk's end, plus the old state decayed through the chunk.
            var toEnd = exp(cs[.ellipsis, (q - 1)...] - cs)[.ellipsis, .newAxis]                             // [B,H,q,1]
            if let keepOut { toEnd = toEnd * keepOut }
            let weighted = dtxc * toEnd                                                                     // [B,H,q,P]
            var next = matmul(weighted.swappedAxes(2, 3), bc)                                               // [B,H,P,N]
            var through = exp(cs[.ellipsis, q - 1])[.ellipsis, .newAxis, .newAxis]                           // [B,H,1,1]
            if let carryKeep { through = through * carryKeep }
            next = next + through * s
            s = next
            ys.append(y.swappedAxes(1, 2))                                                                  // [B,q,H,P]
            start += q
        }
        let y = concatenated(ys, axis: 1) + x.asType(.float32) * D.asType(.float32).reshaped([1, 1, h, 1])
        return (y, s)
    }

    /// One token. x [B,H,P], dt [B,H], B/C [B,G,N], state [B,H,P,N], reset [B] bool or nil.
    public static func step(x: MLXArray, dt: MLXArray, aLog: MLXArray, B: MLXArray, C: MLXArray, D: MLXArray, dtBias: MLXArray, limits: (Float, Float),
                            state: MLXArray, reset: MLXArray?) -> (y: MLXArray, state: MLXArray) {
        let h = x.dim(1)
        let g = B.dim(1)
        var s = state
        if let reset { s = MLX.where(reset[0..., .newAxis, .newAxis, .newAxis], MLXArray(Float(0)), s) }
        let dtv = discretize(dt, bias: dtBias, limits: limits)                        // [B,H]
        let a = -exp(aLog.asType(.float32))
        let dA = exp(dtv * a.reshaped([1, h]))                                        // [B,H]
        let bh = repeated(B, count: h / g, axis: 1).asType(.float32)                  // [B,H,N]
        let ch = repeated(C, count: h / g, axis: 1).asType(.float32)                  // [B,H,N]
        let dtx = dtv[.ellipsis, .newAxis] * x.asType(.float32)                       // [B,H,P]
        let next = dA[.ellipsis, .newAxis, .newAxis] * s + dtx[.ellipsis, .newAxis] * bh[0..., 0..., .newAxis, 0...]   // [B,H,P,N]
        let y = (next * ch[0..., 0..., .newAxis, 0...]).sum(axis: -1) + x.asType(.float32) * D.asType(.float32).reshaped([1, h, 1])
        return (y, next)
    }

    /// Depthwise causal convolution as shifted multiplies. x [B,L,C], weight [C,K,1] (MLX layout),
    /// window [B,K−1,C] (the inputs before x) or nil (zeros), resets [B,L] or nil. Returns the
    /// convolved sequence (before the activation) and the new window: the last K−1 inputs, zeroed
    /// where they belong to a segment the last position does not.
    public static func causalConv(x: MLXArray, weight: MLXArray, bias: MLXArray?, window: MLXArray?, resets: MLXArray?) -> (y: MLXArray, window: MLXArray) {
        let (b, l, c) = (x.dim(0), x.dim(1), x.dim(2))
        let k = weight.dim(1)
        let keep = k - 1
        let before = window ?? MLXArray.zeros([b, keep, c], dtype: x.dtype)
        let padded = concatenated([before, x], axis: 1)                               // [B, L+K−1, C]
        var segmentsExt: MLXArray? = nil
        var seg: MLXArray? = nil
        if let resets {
            let s = cumsum(resets.asType(.int32), axis: 1)                            // [B,L]
            let entering = s[0..., 0] - resets[0..., 0].asType(.int32)                 // [B]
            segmentsExt = concatenated([repeated(entering[0..., .newAxis], count: keep, axis: 1), s], axis: 1)   // [B, L+K−1]
            seg = s
        }
        var y = MLXArray.zeros([b, l, c], dtype: .float32)
        for tap in 0..<k {
            var shifted = padded[0..., tap ..< tap + l].asType(.float32)              // input at offset −(K−1−tap)
            if let segmentsExt, let seg {
                let mask = (segmentsExt[0..., tap ..< tap + l] .== seg).asType(.float32)
                shifted = shifted * mask[.ellipsis, .newAxis]
            }
            y = y + shifted * weight[0..., tap, 0].reshaped([1, 1, c]).asType(.float32)
        }
        if let bias { y = y + bias.asType(.float32).reshaped([1, 1, c]) }
        var newWindow = padded[0..., l ..< l + keep]
        if let seg, keep > 0 {
            let last = seg[0..., (l - 1)...]                                            // [B,1]
            let tail = concatenated([segmentsExt![0..., l ..< l + keep]], axis: 1)      // the last K−1 positions' segments (shifted view)
            _ = tail
            let windowSegments = segmentsExt![0..., l ..< l + keep]
            newWindow = newWindow * (windowSegments .== last).asType(newWindow.dtype)[.ellipsis, .newAxis]
        }
        return (y, newWindow)
    }

    /// The convolution for one token. x [B,C], window [B,K−1,C], reset [B] or nil.
    public static func convStep(x: MLXArray, weight: MLXArray, bias: MLXArray?, window: MLXArray, reset: MLXArray?) -> (y: MLXArray, window: MLXArray) {
        var before = window
        if let reset { before = MLX.where(reset[0..., .newAxis, .newAxis], MLXArray(Float(0)).asType(before.dtype), before) }
        let padded = concatenated([before, x[0..., .newAxis, 0...]], axis: 1)         // [B,K,C]
        let k = weight.dim(1)
        var y = MLXArray.zeros(like: x).asType(.float32)
        for tap in 0..<k { y = y + padded[0..., tap].asType(.float32) * weight[0..., tap, 0].asType(.float32) }
        if let bias { y = y + bias.asType(.float32) }
        return (y, padded[0..., 1...])
    }
}
