//
//  KeyScheme.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Which attribute fills the provenance key's mid half: the residual stream after n blocks
//        (`residual:n`, the default), the per-channel energy of a layer's recurrent state
//        (`pooled-state:l`), or that state's per-channel change (`state-delta:l`). Recorded in
//        index.json and version.json as its text form.
//

import Foundation

public enum KeyScheme: Codable, Sendable, Equatable, CustomStringConvertible {
    /// The residual stream after `afterBlocks` blocks (RaoLM's tap: block afterBlocks−1's output).
    case residual(afterBlocks: Int)
    /// Per-channel L2 energy of layer `layer`'s SSM state: ‖S[h,p,:]‖₂ → H·P floats.
    case pooledState(layer: Int)
    /// Per-channel ‖S_t − S_{t−1}‖ of layer `layer`'s SSM state → H·P floats.
    case stateDelta(layer: Int)

    public var description: String {
        switch self {
        case .residual(let n): return "residual:\(n)"
        case .pooledState(let l): return "pooled-state:\(l)"
        case .stateDelta(let l): return "state-delta:\(l)"
        }
    }

    public init?(parsing text: String) {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let n = Int(parts[1]) else { return nil }
        switch parts[0] {
        case "residual": self = .residual(afterBlocks: n)
        case "pooled-state": self = .pooledState(layer: n)
        case "state-delta": self = .stateDelta(layer: n)
        default: return nil
        }
    }

    public func midDims(config: Mamba2Config) -> Int {
        switch self {
        case .residual: return config.hiddenSize
        case .pooledState, .stateDelta: return config.numHeads * config.headDim
        }
    }

    public func keyDims(config: Mamba2Config) -> Int { midDims(config: config) + config.hiddenSize }

    public var taps: TapRequest {
        switch self {
        case .residual(let n): return TapRequest(residualAfterBlocks: [n])
        case .pooledState, .stateDelta: return .none
        }
    }

    /// The layer whose state the pooled schemes read, if any.
    public var stateLayer: Int? {
        switch self {
        case .residual: return nil
        case .pooledState(let l), .stateDelta(let l): return l
        }
    }

    enum CodingKeys: String, CodingKey { case scheme }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let scheme = KeyScheme(parsing: text) else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown key scheme \(text)")) }
        self = scheme
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}
