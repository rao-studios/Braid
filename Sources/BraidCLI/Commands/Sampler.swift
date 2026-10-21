//
//  Sampler.swift
//  BraidCLI
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The commons alone: a greedy sample from a prompt and the mean NLL on a few public-domain
//        sentences, recorded in pack.json by `braid import --check` as the pack's reference numbers.
//

import BraidKit
import Foundation
import MLX

enum Sampler {
    static let heldOut = [
        "It is a truth universally acknowledged, that a single man in possession of a good fortune, must be in want of a wife.",
        "Call me Ishmael. Some years ago, never mind how long precisely, having little or no money in my purse, I thought I would sail about a little and see the watery part of the world.",
        "It was the best of times, it was the worst of times, it was the age of wisdom, it was the age of foolishness.",
        "Alice was beginning to get very tired of sitting by her sister on the bank, and of having nothing to do.",
    ]

    static func sampleAndNLL(trunk: Trunk, reed: MLXReed, tokenizer: BraidTokenizer, prompt: String = "The history of the city begins", tokens: Int = 32) throws -> (String, Float) {
        var ids: [Int32] = [tokenizer.eos] + tokenizer.encode(prompt)
        var out = trunk.forward(tokens: MLXArray(ids, [1, ids.count]), state: nil, resets: nil)
        var last = out.final[0, ids.count - 1]                                    // [D]
        var generated: [Int32] = []
        for _ in 0..<tokens {
            let logits = reed.logits(array: last.reshaped([1, trunk.config.hiddenSize]))
            let next = Int32(argMax(logits, axis: -1).item(Int32.self))
            if next == tokenizer.eos { break }
            generated.append(next)
            ids.append(next)
            out = trunk.step(token: MLXArray([next]), state: out.state, reset: nil)
            last = out.final[0]
        }
        var total: Float = 0
        var count = 0
        for text in heldOut {
            let seq: [Int32] = [tokenizer.eos] + tokenizer.encode(text)
            let run = trunk.forward(tokens: MLXArray(seq, [1, seq.count]), state: nil, resets: nil)
            let logits = reed.logits(array: run.final[0, 0 ..< seq.count - 1])
            let targets = MLXArray(Array(seq[1...]))
            let (loss, _) = MLXReed.tokenStats(logits: logits, targets: targets)
            eval(loss)
            total += loss.sum().item(Float.self)
            count += seq.count - 1
        }
        return (tokenizer.decode(generated), total / Float(max(count, 1)))
    }
}
