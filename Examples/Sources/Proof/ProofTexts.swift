//
//  ProofTexts.swift
//  Proof
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The texts the proof scores, in five sets from one dataset. Each document is read as its
//        Thread's index read it, partition by partition joined by the pack's paragraph break, whole
//        up to 256 tokens when it has at least 64.
//          own            the arms' first 20 indexed documents, in feeding order
//          own, shuffled  each of those with its sentences reordered so none keeps its successor
//          withheld       documents both arms read and neither indexed; only the delta trained on them
//          unseen         the node's own-voice documents no arm read, crossed by no other node
//          unrelated      10 exclusive documents from what a Thread of each other node would have
//                         read (its first `limit`), and the four generic passages
//        StitchedBench's sizes and seed. Detection is read on withheld against unseen, the texts no
//        index holds; citation on own against unrelated, the texts the index holds. `read` turns
//        one scoring into both arms' readings.
//  PIN:  Pure: a dataset and the arms' present documents in, texts out; a generation in, readings
//        out. Nothing here touches a node. Every strand is read at the same steps, so the arms and
//        the commons line up position by position.
//
//  From the essay main.swift cites: "But even nondeterministic samples can still use information
//  from the training data to some degree -- the information may just be mixed in throughout the
//  sample instead of directly copied." The sets take that sentence apart. Own text is the copy. Shuffled text is the same sentences, mixed.
//  Withheld text is mixed in deeper: the delta trained on it, but no index holds it. Unseen and
//  unrelated texts are the nulls, information neither arm was given.
//

import BraidKit
import Foundation

enum ProofSet: String, Codable, Sendable, CaseIterable {
    case own, ownShuffled, withheld, unseen, unrelated

    var title: String {
        switch self {
        case .own: return "own"
        case .ownShuffled: return "own, shuffled"
        case .withheld: return "withheld"
        case .unseen: return "unseen"
        case .unrelated: return "unrelated"
        }
    }
}

/// A text to score: its set, a label, whose document it is, and its tokens.
struct ProofSource {
    var set: ProofSet
    var label: String
    var node: String?
    var document: String?
    var tokens: [Int32]
}

enum ProofTexts {
    /// The five sets. `present` is the arms' snapshot and `withheld` what their indexes leave out;
    /// another node's documents count as read when they are among its first `limit`.
    static func build(world: BenchWorld, node: String, present: Set<String>, withheld: Set<String>, limit: Int, tokenizer: any Tokenizing,
                      paragraphBreak: [Int32], sizes: StitchedSizes = StitchedSizes()) -> [ProofSource] {
        var rng = SplitMix64(seed: sizes.seed)
        func fits(_ tokens: [Int32]) -> [Int32]? { tokens.count >= sizes.minTokens ? Array(tokens.prefix(sizes.maxTokens)) : nil }
        let documents = world.corpora[node]?.documents ?? []
        var texts: [ProofSource] = []

        // The copy, and its sentences mixed.
        var own = 0
        for document in documents where own < sizes.perNode && present.contains(document.id) && !withheld.contains(document.id) {
            let (tokens, units) = BenchTexts.split(document, tokenizer: tokenizer, paragraphBreak: paragraphBreak)
            guard let read = fits(tokens) else { continue }
            texts.append(ProofSource(set: .own, label: "\(node) · \(document.name)", node: node, document: document.id, tokens: read))
            own += 1
            if let units, let order = BenchTexts.shuffled(units, rng: &rng), let shuffled = fits(order.flatMap { $0 }) {
                texts.append(ProofSource(set: .ownShuffled, label: "\(node) · \(document.name) (shuffled)", node: node, document: document.id, tokens: shuffled))
            }
        }
        // Mixed in deeper: trained on by the delta, held by no index.
        for document in documents where withheld.contains(document.id) && present.contains(document.id) {
            guard let read = fits(BenchTexts.split(document, tokenizer: tokenizer, paragraphBreak: paragraphBreak).tokens) else { continue }
            texts.append(ProofSource(set: .withheld, label: "\(node) · \(document.name) (withheld)", node: node, document: document.id, tokens: read))
        }
        // The nulls: the same voice never read, then other nodes and plain prose.
        var unseen = 0
        for document in BenchTexts.exclusive(documents, crosslinks: world.crosslinks) where unseen < sizes.perNode && !present.contains(document.id) {
            guard let read = fits(BenchTexts.split(document, tokenizer: tokenizer, paragraphBreak: paragraphBreak).tokens) else { continue }
            texts.append(ProofSource(set: .unseen, label: "\(node) · \(document.name) (unread)", node: node, document: document.id, tokens: read))
            unseen += 1
        }
        for other in world.corpora.keys.sorted() where other != node {
            let theirs = world.corpora[other]?.documents ?? []
            let fed = Set(theirs.prefix(limit).map(\.id))
            var count = 0
            for document in BenchTexts.exclusive(theirs, crosslinks: world.crosslinks) where count < sizes.unrelatedPerThread && fed.contains(document.id) {
                guard let read = fits(BenchTexts.split(document, tokenizer: tokenizer, paragraphBreak: paragraphBreak).tokens) else { continue }
                texts.append(ProofSource(set: .unrelated, label: "\(other) · \(document.name)", node: other, document: document.id, tokens: read))
                count += 1
            }
        }
        for (i, passage) in BenchTexts.generic.enumerated() {
            texts.append(ProofSource(set: .unrelated, label: "generic \(i + 1)", node: nil, document: nil, tokens: Array(tokenizer.encode(passage).prefix(sizes.maxTokens))))
        }
        return texts
    }

    /// Both arms' readings of one scoring, means from position `from`, and the two per-position
    /// comparisons: the delta's H_knn against the frozen arm's, and the frozen arm's H_lm against the commons'.
    static func read(_ text: ProofSource, generation: Generation, names: [String], delta d: Int, frozen f: Int, commons c: Int,
                     module: ModuleSettings, from: Int = ProofRules.from) -> ProofText {
        let means = StitchedBench.readings(generation, names: names, commons: c, settings: module)
        let series = TrajectoryModule.series(generation.steps, commons: c)

        // The best hit at each position from `from`, aligned as the trace bench aligns it (the
        // emission before a step predicts the step's token).
        func topCosine(_ t: Int) -> Float {
            var best: [Double] = []
            for step in generation.steps where step.source != .ctx && step.index - 1 >= from {
                guard let records = step.threads, t < records.count else { continue }
                best.append(Double(records[t].hits.first?.score ?? 0))
            }
            return Float(Stats.mean(best))
        }
        let readings = [d, f].compactMap { t -> ProofReading? in
            guard let mean = means.first(where: { $0.thread == names[t] }) else { return nil }
            return ProofReading(thread: names[t], hknn: mean.hknn, hlm: mean.hlm, lift: mean.lift, trace: mean.trace, topCosine: topCosine(t))
        }

        var positions = 0, sharper = 0
        var hlmPositions = 0, hlmMismatches = 0
        var hlmLargest = 0.0
        if d < series.count, f < series.count {
            let delta = series[d], frozen = series[f]
            for i in stride(from: from, to: min(delta.count, frozen.count), by: 1) {
                positions += 1
                if delta.hknn[i] < frozen.hknn[i] { sharper += 1 }
            }
            for i in 0..<frozen.count {
                hlmPositions += 1
                guard let own = frozen.hlm[i], let commons = frozen.commonsHLM[i] else {
                    hlmMismatches += 1
                    continue
                }
                let gap = abs(own - commons)
                hlmLargest = max(hlmLargest, gap)
                if gap > ProofRules.tolerance { hlmMismatches += 1 }
            }
        }
        return ProofText(set: text.set, label: text.label, node: text.node, document: text.document, tokens: text.tokens.count, readings: readings,
                         positions: positions, sharper: sharper, hlmPositions: hlmPositions, hlmMismatches: hlmMismatches, hlmLargest: hlmLargest)
    }
}
