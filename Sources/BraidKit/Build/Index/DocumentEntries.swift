//
//  DocumentEntries.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: What one document adds to a provenance index, segment by segment: its entries (the key,
//        the value that follows, both addresses, the eval loss and the predictive entropy), the
//        loss and entropy at every position it scores, and the checkpoints saved along it. The
//        index's arrays are the documents' entries joined in corpus order; its eval is the mean
//        over every scored position.
//  PIN:  Positions whose input is eos are not keys; transitions whose value is eos are not entries.
//        Entries are in corpus order, contiguous per document, so the tracker's successor is e+1.
//

import BraidCore
import Foundation
import MLX

struct DocumentEntries {
    /// The kept rows of each segment's keys ([kept, K] each).
    var keys: [MLXArray] = []
    var values: [Int32] = [], keyRow: [Int32] = [], keyOffset: [Int32] = [], valueRow: [Int32] = [], valueOffset: [Int32] = []
    /// The loss and entropy at each entry.
    var losses: [Float] = [], entropies: [Float] = []
    /// The loss and entropy at every position whose input is not eos, entry or not: the eval.
    var scoredLoss: [Float] = [], scoredEntropy: [Float] = []
    var checkpoints: [CheckpointRef] = []

    /// One segment's positions, keyed and scored. Every position whose input is not eos is scored;
    /// those whose value is not eos either become entries, unless the document is withheld.
    mutating func record(_ segment: ClosedRange<Int>, of document: TokenizedDocument, keys: MLXArray, loss: [Float], entropy: [Float], eos: Int32, indexed: Bool) {
        let tokens = document.tokens
        var keep: [Int32] = []
        for (i, t) in segment.enumerated() {
            let input = tokens[t]
            guard t + 1 < tokens.count else { continue }
            let value = tokens[t + 1]
            if input != eos { score(loss: loss[i], entropy: entropy[i]) }
            guard input != eos, value != eos, indexed else { continue }
            keep.append(Int32(i))
            addEntry(value, at: t, of: document, loss: loss[i], entropy: entropy[i])
        }
        if !keep.isEmpty { self.keys.append(keys[MLXArray(keep)]) }
    }

    /// A scored position: it counts toward the eval whether or not it becomes an entry.
    private mutating func score(loss: Float, entropy: Float) {
        scoredLoss.append(loss)
        scoredEntropy.append(entropy)
    }

    /// An entry: the value after position `t`, where `t` and `t + 1` sit in the corpus, and the
    /// loss and entropy there.
    private mutating func addEntry(_ value: Int32, at t: Int, of document: TokenizedDocument, loss: Float, entropy: Float) {
        values.append(value)
        keyRow.append(Int32(document.addresses[t].row))
        keyOffset.append(Int32(document.addresses[t].offset))
        valueRow.append(Int32(document.addresses[t + 1].row))
        valueOffset.append(Int32(document.addresses[t + 1].offset))
        losses.append(loss)
        entropies.append(entropy)
    }
}

extension DocumentEntries {
    /// The index's eval over every scored position, in corpus order: the mean loss, the mean
    /// entropy, and the fraction memorised (under 0.1 nat).
    struct Eval {
        var loss: Float = 0
        var entropy: Float = 0
        var memorised: Float = 0

        init(_ documents: [DocumentEntries]) {
            let losses = documents.flatMap(\.scoredLoss)
            guard !losses.isEmpty else { return }
            loss = Self.mean(losses)
            entropy = Self.mean(documents.flatMap(\.scoredEntropy))
            memorised = Float(losses.filter { $0 < 0.1 }.count) / Float(losses.count)
        }

        /// Summed in f64 in stream order, one position at a time.
        private static func mean(_ values: [Float]) -> Float {
            Float(values.reduce(0.0) { $0 + Double($1) } / Double(values.count))
        }
    }
}

extension IndexFiles.Arrays {
    /// The documents' entries joined in corpus order: the arrays index.safetensors holds.
    init(joining documents: [DocumentEntries], keyDims: Int) {
        let pieces = documents.flatMap(\.keys)
        let keys = pieces.isEmpty ? MLXArray.zeros([0, keyDims]) : concatenated(pieces, axis: 0)
        eval(keys)
        self.init(keys: keys, values: documents.flatMap(\.values), keyRow: documents.flatMap(\.keyRow), keyOffset: documents.flatMap(\.keyOffset),
                  valueRow: documents.flatMap(\.valueRow), valueOffset: documents.flatMap(\.valueOffset), loss: documents.flatMap(\.losses), entropy: documents.flatMap(\.entropies))
    }
}
