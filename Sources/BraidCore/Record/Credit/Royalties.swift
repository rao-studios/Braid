//
//  Royalties.swift
//  BraidCore
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The royalties view over a generation's steps: per Thread the tokens it led, its summed
//        share, its bits-weighted credit; per cited document the share of the tokens whose heaviest
//        matching hit resolves to it. A read-time view; the log stores shares only.
//  PIN:  Keyed by the Thread's name: a strand detached and re-attached mid-answer is one line.
//

import Foundation

public struct RoyaltyLine: Sendable, Equatable {
    public var name: String
    public var commons: Bool
    public var led: Int
    public var share: Double
    public var credit: Double
    public var bits: Double
}

public struct DocumentRoyalty: Sendable, Equatable {
    public var name: String
    public var documentID: String
    public var tokens: Int
    public var share: Double
}

public struct RoyaltiesView: Sendable, Equatable {
    /// In the order the Threads first appear among the generated steps.
    public var strands: [RoyaltyLine]
    public var documents: [DocumentRoyalty]
    public var generated: Int
}

public enum Royalties {
    /// Over the generated steps only (the prompt earns nothing). `slots[i]` names step i's strands.
    public static func view(steps: [Step], credits: [CreditRow?], slots: [[StrandSlot]], partitions: [Int: PartitionRef]) -> RoyaltiesView {
        var lines: [String: RoyaltyLine] = [:]
        var order: [String] = []
        var documents: [String: DocumentRoyalty] = [:]
        var generated = 0
        for (i, step) in steps.enumerated() where !step.isPrompt {
            guard i < slots.count, let threads = step.threads else { continue }
            let here = slots[i]
            generated += 1
            let dominant = step.dominant()
            for (t, record) in threads.enumerated() where t < here.count {
                let name = here[t].name
                if lines[name] == nil { order.append(name) }
                var line = lines[name] ?? RoyaltyLine(name: name, commons: here[t].commons, led: 0, share: 0, credit: 0, bits: 0)
                if dominant == t { line.led += 1 }
                line.share += Double(record.share)
                if i < credits.count, let row = credits[i], t < row.credit.count {
                    let bits = Double(row.bits ?? 1)
                    line.credit += Double(row.credit[t]) * bits
                    line.bits += bits * Double(record.share)
                }
                lines[name] = line
            }
            // The cited document: the heaviest matching hit of the strand that supplied the most.
            if let t = threads.indices.max(by: { threads[$0].share < threads[$1].share }), t < here.count, !here[t].commons {
                let record = threads[t]
                let weights = Mixer.weights(record.hits.map { Double($0.score) }, tau: here[t].tau)
                var best: (weight: Double, row: Int)?
                for (k, hit) in record.hits.enumerated() where hit.value == step.token {
                    if best == nil || weights[k] > best!.weight { best = (weights[k], here[t].rowOffset + Int(hit.row)) }
                }
                if let best, let partition = partitions[best.row] {
                    let key = "\(here[t].name)|\(partition.documentID)"
                    var royalty = documents[key] ?? DocumentRoyalty(name: here[t].name, documentID: partition.documentID, tokens: 0, share: 0)
                    royalty.tokens += 1
                    royalty.share += Double(record.share)
                    documents[key] = royalty
                }
            }
        }
        return RoyaltiesView(strands: order.compactMap { lines[$0] },
                             documents: documents.values.sorted { $0.share != $1.share ? $0.share > $1.share : ($0.documentID != $1.documentID ? $0.documentID < $1.documentID : $0.name < $1.name) },
                             generated: generated)
    }
}
