//
//  LayerState.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The recurrent state: per layer the conv window [B,K−1,convDim] and the SSM state
//        [B,H,P,N]; the stack of all layers is a node's history artifact — fixed size whatever the
//        context length, checkpointable, transferable. Every place RaoLM held a KV cache, Braid
//        holds one of these.
//

import BraidCore
import Foundation
import MLX

public struct LayerState {
    public var conv: MLXArray
    public var ssm: MLXArray

    public init(conv: MLXArray, ssm: MLXArray) {
        self.conv = conv
        self.ssm = ssm
    }

    public static func zeros(config: Mamba2Config, batch: Int) -> LayerState {
        LayerState(conv: MLXArray.zeros([batch, config.convKernel - 1, config.convDim], dtype: .float32),
                   ssm: MLXArray.zeros([batch, config.numHeads, config.headDim, config.stateSize], dtype: .float32))
    }
}

public struct StateStack {
    public var layers: [LayerState]
    /// Tokens consumed so far (−1 before any).
    public var position: Int
    /// sha256 of the consumed token ids as little-endian int32, when known.
    public var prefixSHA256: String?

    public init(layers: [LayerState], position: Int = -1, prefixSHA256: String? = nil) {
        self.layers = layers
        self.position = position
        self.prefixSHA256 = prefixSHA256
    }

    public static func zeros(config: Mamba2Config, batch: Int) -> StateStack {
        StateStack(layers: (0..<config.numHiddenLayers).map { _ in LayerState.zeros(config: config, batch: batch) })
    }

    public static func byteCount(config: Mamba2Config) -> Int { StorageMath(config: config).stateBytesPerStream }

    public var batch: Int { layers.first?.ssm.dim(0) ?? 0 }

    /// A deep copy (MLX arrays are values once evaluated; this forces one).
    public func copy() -> StateStack {
        let copied = layers.map { LayerState(conv: $0.conv + 0, ssm: $0.ssm + 0) }
        eval(copied.flatMap { [$0.conv, $0.ssm] })
        return StateStack(layers: copied, position: position, prefixSHA256: prefixSHA256)
    }

    /// One stream of a batched stack.
    public func select(batch index: Int) -> StateStack {
        StateStack(layers: layers.map { LayerState(conv: $0.conv[index ..< index + 1], ssm: $0.ssm[index ..< index + 1]) }, position: position, prefixSHA256: prefixSHA256)
    }

    public var arrays: [String: MLXArray] {
        var out: [String: MLXArray] = [:]
        for (i, layer) in layers.enumerated() {
            out["layer.\(i).conv"] = layer.conv
            out["layer.\(i).ssm"] = layer.ssm
        }
        return out
    }

    public static let format = "braid-state-stack-v1"

    public func metadata(packSHA256: String?) -> [String: String] {
        var m = ["format": Self.format, "position": String(position), "layers": String(layers.count)]
        if let prefixSHA256 { m["prefixSHA256"] = prefixSHA256 }
        if let packSHA256 { m["packSHA256"] = packSHA256 }
        return m
    }

    public func save(to url: URL, packSHA256: String?) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try MLX.save(arrays: arrays, metadata: metadata(packSHA256: packSHA256), url: url)
    }

    public static func load(from url: URL, expecting config: Mamba2Config) throws -> StateStack {
        let (arrays, metadata) = try loadArraysAndMetadata(url: url)
        guard metadata["format"] == format else { throw BraidFailure.data("\(url.lastPathComponent) is not a state stack") }
        return try from(arrays: arrays, metadata: metadata, expecting: config)
    }

    public static func from(arrays: [String: MLXArray], metadata: [String: String], expecting config: Mamba2Config) throws -> StateStack {
        var layers: [LayerState] = []
        for i in 0..<config.numHiddenLayers {
            guard let conv = arrays["layer.\(i).conv"], let ssm = arrays["layer.\(i).ssm"] else { throw BraidFailure.data("state stack lacks layer \(i)") }
            guard ssm.dim(1) == config.numHeads, ssm.dim(2) == config.headDim, ssm.dim(3) == config.stateSize, conv.dim(2) == config.convDim else {
                throw BraidFailure.data("state stack layer \(i) has the wrong shape for this pack")
            }
            layers.append(LayerState(conv: conv, ssm: ssm))
        }
        return StateStack(layers: layers, position: Int(metadata["position"] ?? "-1") ?? -1, prefixSHA256: metadata["prefixSHA256"])
    }

    /// The safetensors bytes (for a checkpoint that travels).
    public func data(packSHA256: String?) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("braid-state-\(UUID().uuidString).safetensors")
        defer { try? FileManager.default.removeItem(at: url) }
        try save(to: url, packSHA256: packSHA256)
        return try Data(contentsOf: url)
    }

    public static func from(data: Data, expecting config: Mamba2Config) throws -> StateStack {
        let (arrays, metadata) = try loadArraysAndMetadata(data: data)
        return try from(arrays: arrays, metadata: metadata, expecting: config)
    }

    /// SHA-256 over every layer's f32 little-endian bytes, conv then ssm, layers in order.
    public var sha256: String {
        var parts: [Data] = []
        for layer in layers {
            for array in [layer.conv, layer.ssm] {
                let floats = array.asType(.float32).asArray(Float.self)
                parts.append(floats.withUnsafeBufferPointer { Data(buffer: $0) })
            }
        }
        return ContentHash.sha256Hex(parts: parts)
    }
}
