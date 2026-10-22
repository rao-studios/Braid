//
//  Mamba2Config.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The shape of a Mamba2 language module: Hugging Face's Mamba2Config keys as the imported
//        checkpoint declares them, plus Braid's two fields — the cut (the first block of the
//        commons' tail) and the key scheme the provenance index reads states with.
//  PIN:  Validated once at import: tied embeddings (the reed is the vocabulary), heads × head_dim
//        is the inner width, the groups divide the heads. The imported architecture is kept exactly:
//        Mamba2 has no MLP block, so Braid adds none.
//

import BraidCore
import Foundation

public struct Mamba2Config: Codable, Sendable, Equatable {
    public var modelType: String
    public var hiddenSize: Int
    public var numHiddenLayers: Int
    public var numHeads: Int
    public var headDim: Int
    public var stateSize: Int
    public var nGroups: Int
    public var convKernel: Int
    public var vocabSize: Int
    public var layerNormEpsilon: Float
    public var timeStepLimit: [Float]
    public var useBias: Bool
    public var useConvBias: Bool
    public var tieWordEmbeddings: Bool
    public var chunkSize: Int
    /// Braid: the first block of the commons' tail; blocks 0..<cut are a Thread's own.
    public var cut: Int
    /// Braid: the residual tap (after how many blocks) the default key reads.
    public var tapAfterBlocks: Int

    enum CodingKeys: String, CodingKey {
        case modelType = "model_type", hiddenSize = "hidden_size", numHiddenLayers = "num_hidden_layers", numHeads = "num_heads", headDim = "head_dim"
        case stateSize = "state_size", nGroups = "n_groups", convKernel = "conv_kernel", vocabSize = "vocab_size", layerNormEpsilon = "layer_norm_epsilon"
        case timeStepLimit = "time_step_limit", useBias = "use_bias", useConvBias = "use_conv_bias", tieWordEmbeddings = "tie_word_embeddings"
        case chunkSize = "chunk_size", cut = "braid_cut", tapAfterBlocks = "braid_tap_after_blocks"
    }

    public init(modelType: String = "mamba2", hiddenSize: Int, numHiddenLayers: Int, numHeads: Int, headDim: Int, stateSize: Int, nGroups: Int = 1, convKernel: Int = 4,
                vocabSize: Int, layerNormEpsilon: Float = 1e-5, timeStepLimit: [Float] = [0, .infinity], useBias: Bool = false, useConvBias: Bool = true,
                tieWordEmbeddings: Bool = true, chunkSize: Int = 256, cut: Int? = nil, tapAfterBlocks: Int? = nil) {
        self.modelType = modelType
        self.hiddenSize = hiddenSize
        self.numHiddenLayers = numHiddenLayers
        self.numHeads = numHeads
        self.headDim = headDim
        self.stateSize = stateSize
        self.nGroups = nGroups
        self.convKernel = convKernel
        self.vocabSize = vocabSize
        self.layerNormEpsilon = layerNormEpsilon
        self.timeStepLimit = timeStepLimit
        self.useBias = useBias
        self.useConvBias = useConvBias
        self.tieWordEmbeddings = tieWordEmbeddings
        self.chunkSize = chunkSize
        self.cut = cut ?? numHiddenLayers / 2
        self.tapAfterBlocks = tapAfterBlocks ?? numHiddenLayers / 2
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modelType = try c.decodeIfPresent(String.self, forKey: .modelType) ?? "mamba2"
        hiddenSize = try c.decode(Int.self, forKey: .hiddenSize)
        numHiddenLayers = try c.decode(Int.self, forKey: .numHiddenLayers)
        numHeads = try c.decode(Int.self, forKey: .numHeads)
        headDim = try c.decode(Int.self, forKey: .headDim)
        stateSize = try c.decode(Int.self, forKey: .stateSize)
        nGroups = try c.decodeIfPresent(Int.self, forKey: .nGroups) ?? 1
        convKernel = try c.decode(Int.self, forKey: .convKernel)
        vocabSize = try c.decode(Int.self, forKey: .vocabSize)
        layerNormEpsilon = try c.decodeIfPresent(Float.self, forKey: .layerNormEpsilon) ?? 1e-5
        let limit = try c.decodeIfPresent([Float].self, forKey: .timeStepLimit) ?? [0, .infinity]
        timeStepLimit = limit.count == 2 ? limit : [0, .infinity]
        useBias = try c.decodeIfPresent(Bool.self, forKey: .useBias) ?? false
        useConvBias = try c.decodeIfPresent(Bool.self, forKey: .useConvBias) ?? true
        tieWordEmbeddings = try c.decodeIfPresent(Bool.self, forKey: .tieWordEmbeddings) ?? false
        chunkSize = try c.decodeIfPresent(Int.self, forKey: .chunkSize) ?? 256
        cut = try c.decodeIfPresent(Int.self, forKey: .cut) ?? numHiddenLayers / 2
        tapAfterBlocks = try c.decodeIfPresent(Int.self, forKey: .tapAfterBlocks) ?? numHiddenLayers / 2
    }

    public var intermediate: Int { numHeads * headDim }
    public var convDim: Int { intermediate + 2 * nGroups * stateSize }
    public var hasTail: Bool { cut < numHiddenLayers }
    public var limits: (Float, Float) { (timeStepLimit[0], timeStepLimit[1]) }

    public func validate() throws {
        guard tieWordEmbeddings else { throw BraidFailure.data("the checkpoint's lm_head is not tied to its embedding; Braid's reed is the vocabulary") }
        guard numHeads > 0, headDim > 0, stateSize > 0, nGroups > 0, numHeads % nGroups == 0 else { throw BraidFailure.data("heads \(numHeads), head_dim \(headDim), groups \(nGroups) do not fit") }
        guard cut > 0, cut <= numHiddenLayers else { throw BraidFailure.configuration("cut \(cut) is outside 1...\(numHiddenLayers)") }
        guard tapAfterBlocks >= 1, tapAfterBlocks <= numHiddenLayers else { throw BraidFailure.configuration("tap \(tapAfterBlocks) is outside 1...\(numHiddenLayers)") }
    }
}

/// The storage and state arithmetic `braid init` prints, so the trade-offs are visible from day one.
public struct StorageMath: Sendable, Equatable {
    public var config: Mamba2Config

    public init(config: Mamba2Config) { self.config = config }

    public var parametersPerBlock: Int {
        let c = config
        let inProj = (c.intermediate + c.convDim + c.numHeads) * c.hiddenSize + (c.useBias ? c.intermediate + c.convDim + c.numHeads : 0)
        let outProj = c.hiddenSize * c.intermediate + (c.useBias ? c.hiddenSize : 0)
        let conv = c.convDim * c.convKernel + (c.useConvBias ? c.convDim : 0)
        return inProj + outProj + conv + c.hiddenSize + c.intermediate + 3 * c.numHeads
    }
    public var embeddingParameters: Int { config.vocabSize * config.hiddenSize }
    public var totalParameters: Int { parametersPerBlock * config.numHiddenLayers + embeddingParameters + config.hiddenSize }
    public var threadParameters: Int { parametersPerBlock * config.cut }
    /// The tail: blocks cut..<L, the embedding and the final norm, the commons', run by every Thread.
    public var tailParameters: Int { parametersPerBlock * (config.numHiddenLayers - config.cut) + embeddingParameters + config.hiddenSize }
    public var tailBytes: Int { tailParameters * 4 }
    /// The SSM state and the conv window of one layer, one stream, in floats.
    public var ssmStateFloats: Int { config.numHeads * config.headDim * config.stateSize }
    public var convWindowFloats: Int { (config.convKernel - 1) * config.convDim }
    /// The history artifact: every layer's state, f32.
    public var stateBytesPerStream: Int { config.numHiddenLayers * (ssmStateFloats + convWindowFloats) * 4 }
    public var keyFloats: Int { 2 * config.hiddenSize }
    public var pooledKeyFloats: Int { config.numHeads * config.headDim + config.hiddenSize }

    public func table() -> [(String, String)] {
        func mb(_ bytes: Int) -> String { String(format: "%.1f MB", Double(bytes) / 1_000_000) }
        func m(_ n: Int) -> String { String(format: "%.1fM", Double(n) / 1_000_000) }
        return [
            ("parameters", "\(m(totalParameters)) (\(config.numHiddenLayers) blocks × \(m(parametersPerBlock)), embedding \(m(embeddingParameters)))"),
            ("a Thread node (blocks 0..<\(config.cut))", "\(m(threadParameters)) = \(mb(threadParameters * 4)) f32 per version, plus the commons' tail by reference"),
            ("the commons' tail (\(config.cut)..<\(config.numHiddenLayers))", "\(m(tailParameters)) = \(mb(tailBytes)) f32: blocks \(config.cut)..<\(config.numHiddenLayers), the embedding and norm_f, run by every Thread"),
            ("state per stream", "\(config.numHiddenLayers) × (\(ssmStateFloats) + \(convWindowFloats)) floats = \(mb(stateBytesPerStream)) — the history artifact, independent of context length"),
            ("key (residual ⊕ final)", "\(keyFloats) floats = \(keyFloats * 4) B f32, \(keyFloats * 2) B f16 → \(mb(keyFloats * 2 * 100_000)) f16 per 100K positions"),
            ("key (pooled state ⊕ final)", "\(pooledKeyFloats) floats → \(mb(pooledKeyFloats * 2 * 100_000)) f16 per 100K positions"),
            ("raw state as a key half", "\(ssmStateFloats) floats → \(String(format: "%.1f GB", Double(ssmStateFloats * 4) * 100_000 / 1_073_741_824)) per 100K positions: infeasible, hence pooling"),
            ("checkpoint", "\(mb(stateBytesPerStream)) each; at a 1,024-token stride ≤ \(mb(stateBytesPerStream * 98)) per 100K positions"),
        ]
    }
}
