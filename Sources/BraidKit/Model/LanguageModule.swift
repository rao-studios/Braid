//
//  LanguageModule.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The language module, laid out as the checkpoint names it: `backbone.embeddings`,
//        `backbone.layers.N`, `backbone.norm_f`. The commons runs the pack whole, every block frozen;
//        its blocks cut..<L, its embedding and its final norm are its tail, which every Thread runs
//        behind its own head as the same module instances, never copied. A Thread's language module
//        is its head, blocks 0..<cut, in front of the commons' tail. The node runs it end to end and
//        emits the normed last state; the reed is the embedding, applied by the cluster.
//  PIN:  One final RMSNorm, applied here. The reed never re-norms. Taps capture the residual stream
//        after a given number of blocks (the key's first half); no attention, no cache. A Thread's
//        tail is the commons' own modules: never call a recursive unfreeze() or train(_:) on a
//        LanguageModule, and never update its parameters past its head. A head holds blocks 0..<cut
//        and nothing else; a file that carries a block of the tail is refused.
//

import BraidCore
import Foundation
import MLX
import MLXNN

public struct TapRequest: Sendable, Equatable {
    public var residualAfterBlocks: Set<Int>
    public init(residualAfterBlocks: Set<Int> = []) { self.residualAfterBlocks = residualAfterBlocks }
    public static let none = TapRequest()
}

public struct LanguageModuleOutput {
    /// [B,L,D] (or [B,D] for a step): the normed last-layer state. The node's public output.
    public var final: MLXArray
    /// The residual stream after n blocks, for each n requested.
    public var residual: [Int: MLXArray]
    public var state: StateStack
}

final class Backbone: Module {
    @ModuleInfo(key: "embeddings") var embeddings: Embedding
    @ModuleInfo(key: "layers") var layers: [Mamba2Block]
    @ModuleInfo(key: "norm_f") var normF: RMSNorm

    /// The whole model, fresh: the commons' shape, and the tests'.
    init(_ config: Mamba2Config) {
        _embeddings.wrappedValue = Embedding(embeddingCount: config.vocabSize, dimensions: config.hiddenSize)
        _layers.wrappedValue = (0..<config.numHiddenLayers).map { _ in Mamba2Block(config) }
        _normF.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.layerNormEpsilon)
        super.init()
    }

    /// A head in front of a tail: the tail's modules themselves, not copies. The head is the dense
    /// prefix of `layers`, which the optimizer's gradient tree relies on.
    init(head: [Mamba2Block], tail: LanguageModule.Tail) {
        _embeddings.wrappedValue = tail.embeddings
        _layers.wrappedValue = head + tail.blocks
        _normF.wrappedValue = tail.normF
        super.init()
    }
}

public final class LanguageModule: Module {
    public var config: Mamba2Config
    /// SEAM: SHA-256 over the tail's arrays, the name a Thread's version must carry (RaoLM v2's definition).
    public private(set) var seamSHA256: String
    @ModuleInfo(key: "backbone") var backbone: Backbone

    /// What the commons lends every Thread: its blocks cut..<L, its embedding and its final norm,
    /// named by the seam. A view over the commons' modules, not an owner.
    public struct Tail {
        let embeddings: Embedding
        let blocks: [Mamba2Block]
        let normF: RMSNorm
        public let config: Mamba2Config
        public let seamSHA256: String
        public var cut: Int { config.cut }
        /// How many blocks the tail holds.
        public var count: Int { blocks.count }
    }

    private init(config: Mamba2Config, backbone: Backbone, seamSHA256: String) {
        self.config = config
        self.seamSHA256 = seamSHA256
        _backbone.wrappedValue = backbone
        super.init()
    }

    /// The whole model with fresh weights (the tests' tiny ones). Its seam is the hash of what it holds.
    public convenience init(_ config: Mamba2Config) {
        let backbone = Backbone(config)
        self.init(config: config, backbone: backbone, seamSHA256: Self.seam(of: backbone, cut: config.cut))
    }

    /// The commons: the pack run whole, every block frozen, and the seam re-derived from the loaded
    /// modules and held against the pack's record. Built first; every Thread runs behind its tail.
    public convenience init(pack: Pack) throws {
        self.init(config: pack.config, backbone: Backbone(pack.config), seamSHA256: pack.info.seamSHA256)
        var weights = pack.blocks
        weights[Pack.embeddingKey] = pack.embedding
        weights[Pack.normKey] = pack.norm
        try update(parameters: ModuleParameters.unflattened(weights), verify: [.all])
        freeze()                                                                     // whole, once, here: the one recursive freeze
        eval(self)
        let derived = Self.seam(of: backbone, cut: config.cut)
        guard derived == pack.info.seamSHA256 else {
            throw BraidFailure.data("the commons built from pack \(pack.sha256.prefix(12)) hashes to seam \(derived.prefix(12)), not its record \(pack.info.seamSHA256.prefix(12))")
        }
    }

    /// A Thread's running model: `head`, its own blocks 0..<cut, in front of the commons' tail.
    public convenience init(head: [Mamba2Block], tail: Tail) {
        precondition(head.count == tail.cut, "a head holds \(tail.cut) blocks, not \(head.count)")
        self.init(config: tail.config, backbone: Backbone(head: head, tail: tail), seamSHA256: tail.seamSHA256)
    }

    public var embedding: MLXArray { backbone.embeddings.weight }
    public var finalNorm: MLXArray { backbone.normF.weight }
    public var blocks: [Mamba2Block] { backbone.layers }
    /// Its own blocks 0..<cut.
    public var head: [Mamba2Block] { Array(backbone.layers[..<config.cut]) }
    /// Its blocks cut..<L, its embedding and its final norm, as a Thread borrows them. By rule the
    /// tail every Thread runs is the commons'.
    public var tail: Tail {
        Tail(embeddings: backbone.embeddings, blocks: Array(backbone.layers[config.cut...]), normF: backbone.normF, config: config, seamSHA256: seamSHA256)
    }

    /// A head from its arrays: blocks 0..<cut, each key as the checkpoint names it. A key of any other
    /// block is refused, so a head file can never carry a piece of the tail; a missing block is refused
    /// too. The blocks come back trainable; the arrays are assigned, never copied.
    public static func makeHead(arrays: [String: MLXArray], config: Mamba2Config) throws -> [Mamba2Block] {
        var perBlock: [Int: [String: MLXArray]] = [:]
        for (key, value) in arrays {
            guard let index = blockIndex(ofKey: key) else { throw BraidFailure.data("blocks.safetensors holds \(key), which is no block's array; a head holds blocks 0..<\(config.cut)") }
            guard index < config.cut else { throw BraidFailure.data("blocks.safetensors holds \(key), a block of the tail; a head holds blocks 0..<\(config.cut)") }
            perBlock[index, default: [:]][key.split(separator: ".").dropFirst(3).joined(separator: ".")] = value
        }
        let missing = (0..<config.cut).filter { perBlock[$0] == nil }
        guard missing.isEmpty else {
            throw BraidFailure.data("blocks.safetensors lacks block\(missing.count == 1 ? "" : "s") \(missing.map(String.init).joined(separator: ", ")); a head holds blocks 0..<\(config.cut)")
        }
        return try (0..<config.cut).map { index in
            let block = Mamba2Block(config)
            try block.update(parameters: ModuleParameters.unflattened(perBlock[index]!), verify: [.all])
            return block
        }
    }

    /// The pack's own head: blocks 0..<cut as imported, trainable. The commons' head, where a Thread's
    /// training starts, and what an untrained Thread runs.
    public static func packHead(_ pack: Pack) throws -> [Mamba2Block] {
        try makeHead(arrays: pack.headArrays, config: pack.config)
    }

    /// A sequence. tokens [B,L] int32. `training` leaves the graph lazy for a gradient; otherwise
    /// every layer is evaluated as it goes, so the graph never grows with the document.
    public func forward(tokens: MLXArray, state: StateStack?, resets: MLXArray?, taps: TapRequest = .none, training: Bool = false) -> LanguageModuleOutput {
        var h = backbone.embeddings(tokens)
        var layers: [LayerState] = []
        var residual: [Int: MLXArray] = [:]
        if taps.residualAfterBlocks.contains(0) { residual[0] = h }
        for (i, block) in backbone.layers.enumerated() {
            let (out, next) = block(h, state: state?.layers[i], resets: resets, chunk: config.chunkSize)
            h = out
            layers.append(next)
            if taps.residualAfterBlocks.contains(i + 1) { residual[i + 1] = h }
            if !training { eval(h, next.conv, next.ssm) }
        }
        let final = backbone.normF(h)
        if !training { eval(final) }
        let position = (state?.position ?? -1) + tokens.dim(1)
        return LanguageModuleOutput(final: final, residual: residual, state: StateStack(layers: layers, position: position, prefixSHA256: nil))
    }

    /// One token. token [B] int32.
    public func step(token: MLXArray, state: StateStack, reset: MLXArray?, taps: TapRequest = .none) -> LanguageModuleOutput {
        var h = backbone.embeddings(token)
        var layers: [LayerState] = []
        var residual: [Int: MLXArray] = [:]
        if taps.residualAfterBlocks.contains(0) { residual[0] = h }
        for (i, block) in backbone.layers.enumerated() {
            let (out, next) = block.step(h, state: state.layers[i], reset: reset)
            h = out
            layers.append(next)
            if taps.residualAfterBlocks.contains(i + 1) { residual[i + 1] = h }
        }
        let final = backbone.normF(h)
        eval(final)
        eval(layers.flatMap { [$0.conv, $0.ssm] })
        return LanguageModuleOutput(final: final, residual: residual, state: StateStack(layers: layers, position: state.position + 1, prefixSHA256: nil))
    }

    /// "backbone.layers.N.…" → N.
    public static func blockIndex(ofKey key: String) -> Int? {
        let parts = key.split(separator: ".")
        guard parts.count > 3, parts[0] == "backbone", parts[1] == "layers" else { return nil }
        return Int(parts[2])
    }

    /// Every parameter key with its array, flattened to the checkpoint's names.
    public func flattenedParameters() -> [(String, MLXArray)] {
        parameters().flattened().sorted { $0.0 < $1.0 }
    }

    /// The seam of a backbone: SHA-256(norm ‖ embedding ‖ ∀ arrays of blocks ≥ cut sorted by key: key ‖ bytes), from the modules themselves.
    static func seam(of backbone: Backbone, cut: Int) -> String {
        var arrays: [(String, MLXArray)] = []
        for (i, block) in backbone.layers.enumerated() where i >= cut {
            for (key, array) in block.parameters().flattened() { arrays.append(("backbone.layers.\(i).\(key)", array)) }
        }
        return PackHash.seam(embedding: backbone.embeddings.weight, norm: backbone.normF.weight, tail: arrays)
    }
}
