//
//  MLXReed.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The reed on MLX: logits = state · Eᵀ over the pack's embedding, padding rows (the
//        embedding rows past the tokenizer's vocabulary) set to −∞ so they never carry probability.
//        The cluster calls it once per node per position; it never re-norms.
//

import BraidCore
import Foundation
import MLX

public final class MLXReed: Reed, @unchecked Sendable {
    public let vocabularySHA256: String
    public let hiddenSize: Int
    public let vocabulary: Int
    public let tokens: Int
    private let embeddingT: MLXArray
    private let padding: MLXArray?

    /// `tokens` is the tokenizer's vocabulary size; rows at or past it are padding.
    public init(embedding: MLXArray, vocabularySHA256: String, tokens: Int) {
        self.vocabularySHA256 = vocabularySHA256
        hiddenSize = embedding.dim(1)
        vocabulary = embedding.dim(0)
        self.tokens = tokens
        embeddingT = embedding.asType(.float32).T
        if tokens < vocabulary {
            var mask = [Float](repeating: 0, count: vocabulary)
            for i in tokens..<vocabulary { mask[i] = -.infinity }
            padding = MLXArray(mask)
        } else {
            padding = nil
        }
        eval(embeddingT)
    }

    public func logits(_ states: [[Float]]) throws -> [[Float]] {
        guard !states.isEmpty else { return [] }
        let x = MLXArray(states.flatMap { $0 }, [states.count, hiddenSize])
        var logits = matmul(x, embeddingT)
        if let padding { logits = logits + padding }
        eval(logits)
        let flat = logits.asArray(Float.self)
        return (0..<states.count).map { Array(flat[$0 * vocabulary ..< ($0 + 1) * vocabulary]) }
    }

    /// Logits for a batch of states already on the GPU: [n,D] → [n,V].
    public func logits(array states: MLXArray) -> MLXArray {
        var logits = matmul(states.asType(.float32), embeddingT)
        if let padding { logits = logits + padding }
        return logits
    }

    /// Per-token cross-entropy and predictive entropy from logits [n,V] and targets [n] (int32), f32.
    /// The entropy sums p·logit only where p > 0: a padding row's p is 0 and its logit −∞, and
    /// 0·−∞ would make every entropy NaN.
    public static func tokenStats(logits: MLXArray, targets: MLXArray) -> (loss: MLXArray, entropy: MLXArray) {
        let lse = logSumExp(logits, axis: -1)
        let picked = takeAlong(logits, targets[.ellipsis, .newAxis], axis: -1).squeezed(axis: -1)
        let probabilities = softmax(logits, axis: -1)
        let entropy = lse - which(probabilities .> Float(0), probabilities * logits, Float(0)).sum(axis: -1)
        return (lse - picked, entropy)
    }
}
