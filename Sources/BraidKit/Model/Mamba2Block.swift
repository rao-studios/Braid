//
//  Mamba2Block.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: One Mamba2 block, parameter for parameter as the checkpoint names them: `norm`, then the
//        mixer's `in_proj`, `conv1d`, `dt_bias`, `A_log`, `D`, `norm` (gated) and `out_proj`.
//        The block is x + mixer(norm(x)); Mamba2 has no MLP, so Braid adds none.
//

import Foundation
import MLX
import MLXNN

/// silu(gate) · x, then an RMS norm with a learned weight.
final class GatedRMSNorm: Module {
    @ParameterInfo(key: "weight") var weight: MLXArray
    let eps: Float

    init(dimensions: Int, eps: Float) {
        self.eps = eps
        _weight.wrappedValue = MLXArray.ones([dimensions])
        super.init()
    }

    func callAsFunction(_ x: MLXArray, gate: MLXArray) -> MLXArray {
        MLXFast.rmsNorm(x * silu(gate), weight: weight, eps: eps)
    }
}

public final class Mamba2Mixer: Module {
    let config: Mamba2Config

    @ModuleInfo(key: "in_proj") var inProj: Linear
    @ModuleInfo(key: "conv1d") var conv1d: Conv1d
    @ParameterInfo(key: "dt_bias") var dtBias: MLXArray
    @ParameterInfo(key: "A_log") var aLog: MLXArray
    @ParameterInfo(key: "D") var dSkip: MLXArray
    @ModuleInfo(key: "norm") var norm: GatedRMSNorm
    @ModuleInfo(key: "out_proj") var outProj: Linear

    public init(_ config: Mamba2Config) {
        self.config = config
        let projection = config.intermediate + config.convDim + config.numHeads
        _inProj.wrappedValue = Linear(config.hiddenSize, projection, bias: config.useBias)
        _conv1d.wrappedValue = Conv1d(inputChannels: config.convDim, outputChannels: config.convDim, kernelSize: config.convKernel, groups: config.convDim, bias: config.useConvBias)
        _dtBias.wrappedValue = MLXArray.ones([config.numHeads])
        _aLog.wrappedValue = log(MLXArray(1 ... config.numHeads).asType(.float32))
        _dSkip.wrappedValue = MLXArray.ones([config.numHeads])
        _norm.wrappedValue = GatedRMSNorm(dimensions: config.intermediate, eps: config.layerNormEpsilon)
        _outProj.wrappedValue = Linear(config.intermediate, config.hiddenSize, bias: config.useBias)
        super.init()
    }

    private func split(_ projected: MLXArray) -> (gate: MLXArray, xbc: MLXArray, dt: MLXArray) {
        let parts = MLX.split(projected, indices: [config.intermediate, config.intermediate + config.convDim], axis: -1)
        return (parts[0], parts[1], parts[2])
    }

    private func splitConv(_ xbc: MLXArray) -> (x: MLXArray, b: MLXArray, c: MLXArray) {
        let parts = MLX.split(xbc, indices: [config.intermediate, config.intermediate + config.nGroups * config.stateSize], axis: -1)
        return (parts[0], parts[1], parts[2])
    }

    /// A sequence. h [B,L,D]; `state` the layer's state before it (nil = zeros); `resets` [B,L].
    public func callAsFunction(_ h: MLXArray, state: LayerState?, resets: MLXArray?, chunk: Int) -> (MLXArray, LayerState) {
        let (b, l, _) = (h.dim(0), h.dim(1), h.dim(2))
        let (gate, xbcRaw, dt) = split(inProj(h))
        let (convOut, window) = SSD.causalConv(x: xbcRaw, weight: conv1d.weight, bias: conv1d.bias, window: state?.conv, resets: resets)
        let (xs, bs, cs) = splitConv(silu(convOut))
        let x = xs.reshaped([b, l, config.numHeads, config.headDim])
        let bm = bs.reshaped([b, l, config.nGroups, config.stateSize])
        let cm = cs.reshaped([b, l, config.nGroups, config.stateSize])
        let (y, ssm) = SSD.scan(x: x, dt: dt, aLog: aLog, B: bm, C: cm, D: dSkip, dtBias: dtBias, limits: config.limits, state: state?.ssm, resets: resets, chunk: chunk)
        let out = outProj(norm(y.reshaped([b, l, config.intermediate]), gate: gate))
        return (out, LayerState(conv: window, ssm: ssm))
    }

    /// One token. h [B,D].
    public func step(_ h: MLXArray, state: LayerState, reset: MLXArray?) -> (MLXArray, LayerState) {
        let b = h.dim(0)
        let (gate, xbcRaw, dt) = split(inProj(h))
        let (convOut, window) = SSD.convStep(x: xbcRaw, weight: conv1d.weight, bias: conv1d.bias, window: state.conv, reset: reset)
        let (xs, bs, cs) = splitConv(silu(convOut))
        let x = xs.reshaped([b, config.numHeads, config.headDim])
        let bm = bs.reshaped([b, config.nGroups, config.stateSize])
        let cm = cs.reshaped([b, config.nGroups, config.stateSize])
        let (y, ssm) = SSD.step(x: x, dt: dt, aLog: aLog, B: bm, C: cm, D: dSkip, dtBias: dtBias, limits: config.limits, state: state.ssm, reset: reset)
        let out = outProj(norm(y.reshaped([b, config.intermediate]), gate: gate))
        return (out, LayerState(conv: window, ssm: ssm))
    }
}

public final class Mamba2Block: Module {
    @ModuleInfo(key: "norm") var norm: RMSNorm
    @ModuleInfo(key: "mixer") var mixer: Mamba2Mixer

    public init(_ config: Mamba2Config) {
        _norm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.layerNormEpsilon)
        _mixer.wrappedValue = Mamba2Mixer(config)
        super.init()
    }

    public func callAsFunction(_ x: MLXArray, state: LayerState?, resets: MLXArray?, chunk: Int) -> (MLXArray, LayerState) {
        let (out, next) = mixer(norm(x), state: state, resets: resets, chunk: chunk)
        return (x + out, next)
    }

    public func step(_ x: MLXArray, state: LayerState, reset: MLXArray?) -> (MLXArray, LayerState) {
        let (out, next) = mixer.step(norm(x), state: state, reset: reset)
        return (x + out, next)
    }
}
