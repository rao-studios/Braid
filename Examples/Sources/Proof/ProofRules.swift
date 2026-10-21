//
//  ProofRules.swift
//  Proof
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The rules the proof is read by, and the report they read. The delta works in two places,
//        and the rules read both. A text's value is its mean from position 24 (TraceBench.from).
//          C0 the control is the commons. proof-<node>-frozen's live version is untrained, its
//             blocks are the pack's and it holds no blocks file of its own; proof-<node>-delta's is
//             trained and learned. Both read the same corpus, withhold the same documents (the set
//             these options draw) and index the same number of positions. On every text, at every
//             position, the frozen arm's H_lm equals the commons' within 1e-5. When C0 fails, the
//             other rules are not read.
//        Detection: whether a text holds the Thread's training. Read on the texts no index holds,
//        withheld against unseen, by the Thread's own entropy.
//          D1 the delta knows its training without its index. By mean lift over the commons,
//             withheld ranked high against unseen: the delta's AUROC at least 0.95.
//          D2 the commons' blocks do not. By mean H_lm, unseen ranked high against withheld: the
//             delta's AUROC at least 0.95, the frozen arm's below 0.95 and at most the delta's less
//             0.10 (the owner's bar and gap).
//        Citation: where a text's tokens come from. Read on the texts the index holds, by the
//        retrieval entropy.
//          R1 the index finds what it cites. By mean H_knn, unrelated ranked high against own:
//             AUROC at least 0.95 for both arms, whichever blocks keyed the index.
//          R2 the delta sharpens what it cites. Over the own texts, the delta's mean H_knn is below
//             the frozen arm's on at least 90% of them (ties count against), and Welch's z of
//             frozen against delta is at least 3.
//        Proved: C0, D1, D2, R1 and R2 pass. A statistic that cannot be computed fails its rule.
//        Reported with no threshold: own against its shuffled copy, by H_knn and by the trace;
//        withheld against unseen by H_knn; the drops in H_knn from the frozen arm to the delta.
//        The essay main.swift cites, by the passage each rule tests (quoted in full at the rule):
//          the marginal over all training sets is intractable   C0: the commons stands in, exactly
//          low-entropy outputs include training data            D2
//          regurgitation, a model outputting its training data  R1 and R2
//          information mixed in instead of directly copied      D1
//  PIN:  Written on 2026-10-19, after the proof's first run, which read other rules on ambient.
//        That run read P1 to P3 and was not proved: P2 failed because the index alone told own text
//        from unrelated text. Its report keeps those rules as written. What it
//        showed shaped these rules, so they are read first on braid-n3's craft node, which no proof
//        run had read; the owner chose the signals, the data and the claim.
//        Rules are fixed before numbers. `evaluate` is pure over the saved texts and records, so a
//        saved report and these rules can be checked against each other. Every AUROC is
//        BenchFormat.auroc(high, low), which ranks its first argument high. Cross-strand numbers
//        (memory, share, the shadow gate) are never read: they move with the other arm in the
//        braid, while H_knn, H_lm, hits, trace and lift are each strand's own.
//

import BraidKit
import Foundation

/// The two arms on a node: one Thread with a delta of its own, one with the commons' blocks. The
/// first run, on ambient, named them proof-delta and proof-frozen; those Threads are kept as built.
enum ProofArms {
    static func delta(_ node: String) -> String { "proof-\(node)-delta" }
    static func frozen(_ node: String) -> String { "proof-\(node)-frozen" }
}

/// One arm as its live version records it: what C0 reads before any text is scored.
struct ProofArm: Codable, Sendable, Equatable {
    var name: String
    var version: Int
    var trained: Bool
    var learned: Bool
    var steps: Int
    var epochs: Int
    var memorised: Float
    var blocksSHA256: String
    /// The version folder holds a blocks.safetensors of its own.
    var blocksFile: Bool
    var corpusHash: String
    var entries: Int
    /// The documents its index leaves out, sorted.
    var withheld: [String]

    init(_ thread: LoadedThread) {
        let version = thread.version
        name = thread.info.name
        self.version = version.version
        trained = version.trained
        learned = version.learned
        steps = version.steps
        epochs = version.epochs
        memorised = version.memorised
        blocksSHA256 = version.blocksSHA256
        blocksFile = FileManager.default.fileExists(atPath: thread.directory.appendingPathComponent(ThreadStore.blocksFile).path)
        corpusHash = version.corpusHash
        entries = version.entries
        withheld = (thread.node.index?.info.excluded ?? []).sorted()
    }
}

/// What C0 reads of the records: the pack, the withheld set the options draw, and both arms.
struct ProofRecords: Codable, Sendable, Equatable {
    var packSHA256: String
    var drawn: [String]
    var delta: ProofArm
    var frozen: ProofArm
}

/// One arm's reading of one text: means from position 24.
struct ProofReading: Codable, Sendable, Equatable {
    var thread: String
    var hknn: Float
    var hlm: Float?
    /// ln p_lm of the token that came, the arm's reed against the commons': what the arm's own blocks add.
    var lift: Float?
    var trace: Float
    /// The best hit's cosine.
    var topCosine: Float
}

struct ProofText: Codable, Sendable, Equatable {
    var set: ProofSet
    var label: String
    /// The dataset node the document belongs to; nil for the generic passages.
    var node: String?
    var document: String?
    var tokens: Int
    var readings: [ProofReading]
    /// Positions from 24, and how many of them the delta's H_knn is below the frozen arm's.
    var positions: Int
    var sharper: Int
    /// Every position, the frozen arm's H_lm against the commons': how many were compared, how many
    /// were off by more than 1e-5 or missing, and the largest gap.
    var hlmPositions: Int
    var hlmMismatches: Int
    var hlmLargest: Double

    func reading(_ thread: String) -> ProofReading? { readings.first { $0.thread == thread } }
}

/// One set's means for one arm; nil where the set is empty.
struct ProofMeans: Codable, Sendable, Equatable {
    var hknn: Float?
    var hlm: Float?
    var lift: Float?
    var trace: Float?
    var topCosine: Float?
}

struct ProofRow: Codable, Sendable, Equatable {
    var set: ProofSet
    var n: Int
    var delta: ProofMeans
    var frozen: ProofMeans
}

/// A number reported with no threshold: one value, or one per arm.
struct ProofMeasure: Codable, Sendable, Equatable {
    var name: String
    var value: Float?
    var delta: Float?
    var frozen: Float?
}

struct ProofVerdict: Codable, Sendable, Equatable {
    var rules: [BenchRule]
    /// Per rule code, its numbers in one line: what is printed beside the words it tested.
    var evidence: [String: String]
    var rows: [ProofRow]
    var reported: [ProofMeasure]
    var proved: Bool
    /// "proved", or each failing rule with its mechanism.
    var summary: String
}

struct ProofReport: Codable, Sendable {
    var proof = "the delta over entropy: detection and citation"
    var createdAt: Date
    var corpus: String
    var dataset: String
    var limit: Int
    var withhold: Double
    var seed: UInt64
    var steps: Int?
    /// Per arm, `v<version>/<index sha256>`.
    var threads: [String: String]
    var gate: GateSettings
    var tau: Double
    var k: Int
    var from: Int
    var sizes: StitchedSizes
    var records: ProofRecords
    var texts: [ProofText]
    var verdict: ProofVerdict
    var sessions: [String]
}

enum ProofRules {
    static let from = TraceBench.from
    static let tolerance = 1e-5
    static let sharperShare = 0.90
    static let welch = 3.0
    static let bar = 0.95
    static let gap = 0.10

    /// What C0's records say is wrong; empty when both arms are what they claim to be.
    static func recordFailures(_ records: ProofRecords) -> [String] {
        let delta = records.delta, frozen = records.frozen
        var failures: [String] = []
        if frozen.trained { failures.append("\(frozen.name) v\(frozen.version) is trained") }
        if frozen.blocksSHA256 != records.packSHA256 { failures.append("\(frozen.name) v\(frozen.version)'s blocks are not the pack's") }
        if frozen.blocksFile { failures.append("\(frozen.name) v\(frozen.version) holds a blocks file of its own") }
        if !delta.trained { failures.append("\(delta.name) v\(delta.version) is not trained") }
        if delta.trained, !delta.learned {
            failures.append("\(delta.name) v\(delta.version) stopped before it learned its corpus (memorised \(BenchFormat.pct(delta.memorised)))")
        }
        if delta.corpusHash != frozen.corpusHash {
            failures.append("the arms read different corpora (\(delta.corpusHash.prefix(12)) against \(frozen.corpusHash.prefix(12)))")
        }
        if delta.withheld != frozen.withheld {
            failures.append("the arms withhold different documents (\(delta.withheld.count) against \(frozen.withheld.count))")
        } else if delta.withheld != records.drawn {
            failures.append("the arms withhold another set than these options draw (\(delta.withheld.count) documents against \(records.drawn.count))")
        }
        if delta.entries != frozen.entries { failures.append("the arms index different numbers of positions (\(delta.entries) against \(frozen.entries))") }
        return failures
    }

    static func evaluate(texts: [ProofText], records: ProofRecords) -> ProofVerdict {
        let d = records.delta.name, f = records.frozen.name
        func of(_ set: ProofSet) -> [ProofText] { texts.filter { $0.set == set } }
        func values(_ set: ProofSet, _ arm: String, _ key: (ProofReading) -> Float?) -> [Double] {
            of(set).compactMap { text in text.reading(arm).flatMap(key).map(Double.init) }
        }
        func hknn(_ set: ProofSet, _ arm: String) -> [Double] { values(set, arm) { $0.hknn } }
        func hlm(_ set: ProofSet, _ arm: String) -> [Double] { values(set, arm) { $0.hlm } }
        func lift(_ set: ProofSet, _ arm: String) -> [Double] { values(set, arm) { $0.lift } }
        /// Per text, the frozen arm's mean H_knn less the delta's: how much surer the delta made retrieval.
        func drops(_ set: ProofSet) -> [Double] {
            of(set).compactMap { text in
                guard let delta = text.reading(d), let frozen = text.reading(f) else { return nil }
                return Double(frozen.hknn) - Double(delta.hknn)
            }
        }
        func num(_ value: Double?) -> String { BenchFormat.num(value) }
        func pct(_ value: Double) -> String { BenchFormat.pct(value) }
        func mean(_ values: [Double]) -> Double? { values.isEmpty ? nil : Stats.mean(values) }
        var rules: [BenchRule] = []

        // C0 tests: "In practice, it’s usually easy to estimate … the entropy of the outputs of a
        // trained generative model. However, estimating … the marginal entropy of model outputs
        // aggregated over all possible training datasets … will be intractable." Braid needs one
        // counterfactual, not the marginal: the same model without this corpus, which the frozen arm
        // is, bit for bit. One braid runs both arms with the same τ, k, cut and key, so a difference
        // in entropy is the delta's.
        // C0: the records, then the frozen arm's H_lm against the commons' at every position.
        let failures = recordFailures(records)
        let compared = texts.reduce(0) { $0 + $1.hlmPositions }
        let mismatched = texts.reduce(0) { $0 + $1.hlmMismatches }
        let largest = texts.map(\.hlmLargest).max() ?? 0
        let c0 = failures.isEmpty && compared > 0 && mismatched == 0
        var c0Detail = "H_lm equal to the commons' at \(grouped(compared - mismatched)) of \(grouped(compared)) positions, largest gap "
            + String(format: "%.1e", largest) + " (needs every one within 1e-5)"
        c0Detail += failures.isEmpty
            ? "; both arms read corpus \(records.delta.corpusHash.prefix(12)), withhold the same \(records.delta.withheld.count) documents and index "
              + "\(grouped(records.delta.entries)) positions; \(records.frozen.name) runs the pack's blocks, \(records.delta.name) trained \(records.delta.steps) steps and learned"
            : "; " + failures.joined(separator: "; ")
        rules.append(BenchRule(id: "C0 the control is the commons", passes: c0, detail: c0Detail))

        // Detection is read where no copy exists: withheld documents the delta trained on and no index
        // holds, against unseen ones it never read.

        // D1 tests: "But even nondeterministic samples can still use information from the training
        // data to some degree -- the information may just be mixed in throughout the sample instead of
        // directly copied." Lift over the commons is how much more the delta expects the tokens that
        // came than the commons does: the training information it uses, with nothing to copy from.
        let liftAUROC = BenchFormat.auroc(lift(.withheld, d), lift(.unseen, d))
        let d1 = (liftAUROC ?? 0) >= bar
        let d1Detail = "AUROC \(num(liftAUROC)) (needs 0.95), \(of(.withheld).count) withheld texts against \(of(.unseen).count) unseen; mean lift "
            + "\(num(mean(lift(.withheld, d)))) withheld and \(num(mean(lift(.unseen, d)))) unseen; the frozen arm's lift is 0 at every position, its reed being the commons'"

        // D2 tests: "The basic intuition behind this bound is that low-entropy model outputs are more
        // likely to be including information from the model’s training data." That entropy is the
        // trained model's own, H_lm, and the commons' blocks are the control. It is the line the run
        // opens with.
        let hlmDelta = BenchFormat.auroc(hlm(.unseen, d), hlm(.withheld, d))
        let hlmFrozen = BenchFormat.auroc(hlm(.unseen, f), hlm(.withheld, f))
        var d2 = false
        if let delta = hlmDelta, let frozen = hlmFrozen { d2 = delta >= bar && frozen < bar && frozen <= delta - gap }
        let d2Detail = "AUROC \(num(hlmDelta)) delta (needs 0.95), \(num(hlmFrozen)) frozen (needs below 0.95 and at most the delta's less 0.10); "
            + "mean H_lm withheld \(num(mean(hlm(.withheld, d)))) delta and \(num(mean(hlm(.withheld, f)))) frozen, unseen \(num(mean(hlm(.unseen, d)))) and \(num(mean(hlm(.unseen, f))))"

        // Citation is read where the index holds a copy: own texts, against unrelated ones.

        // R1 and R2 test: "In the extreme case, this is the problem of regurgitation, where a model
        // deterministically outputs parts of its training data." On a text it holds, an index finds
        // the copy itself, at cosine ≈ 1, whichever blocks keyed it: that is the citation (R1). The
        // delta makes that retrieval surer (R2). The first run's P2 asked the delta to do the
        // finding, and the index had already done it.
        // R1: own against unrelated by H_knn, both arms.
        let findDelta = BenchFormat.auroc(hknn(.unrelated, d), hknn(.own, d))
        let findFrozen = BenchFormat.auroc(hknn(.unrelated, f), hknn(.own, f))
        let r1 = (findDelta ?? 0) >= bar && (findFrozen ?? 0) >= bar
        let r1Detail = "AUROC \(num(findDelta)) delta and \(num(findFrozen)) frozen (each needs 0.95), \(of(.unrelated).count) unrelated texts against "
            + "\(of(.own).count) own; top cosine on own text \(num(mean(values(.own, d) { $0.topCosine }))) delta and \(num(mean(values(.own, f) { $0.topCosine }))) frozen"

        // R2: paired over the own texts.
        let own = of(.own).compactMap { text -> (delta: Double, frozen: Double)? in
            guard let delta = text.reading(d), let frozen = text.reading(f) else { return nil }
            return (Double(delta.hknn), Double(frozen.hknn))
        }
        let lower = BenchFormat.share(own.map { $0.delta < $0.frozen })
        let z = Stats.welchZ(own.map(\.frozen), own.map(\.delta))
        let r2 = !own.isEmpty && lower >= sharperShare && (z ?? -.infinity) >= welch
        let r2Detail = "the delta lower on \(pct(lower)) of \(own.count) own texts (needs 90%), Welch's z \(num(z)) (needs 3); "
            + "mean H_knn \(num(mean(own.map(\.delta)))) delta against \(num(mean(own.map(\.frozen)))) frozen"

        let read = c0
        var evidence = ["C0": "H_lm equal at \(grouped(compared - mismatched)) of \(grouped(compared)) positions"]
        if read {
            evidence["D1"] = "AUROC \(num(liftAUROC)), \(of(.withheld).count) withheld against \(of(.unseen).count) unseen"
            evidence["D2"] = "AUROC \(num(hlmDelta)) delta, \(num(hlmFrozen)) frozen"
            evidence["R1"] = "AUROC \(num(findDelta)) delta, \(num(findFrozen)) frozen"
            evidence["R2"] = "lower on \(pct(lower)) of \(own.count) own texts, Welch's z \(num(z))"
        }
        let notRead = "not read: C0 fails"
        for (id, passes, detail) in [("D1 the delta knows its training without its index", d1, d1Detail), ("D2 the commons' blocks do not", d2, d2Detail),
                                     ("R1 the index finds what it cites", r1, r1Detail), ("R2 the delta sharpens what it cites", r2, r2Detail)] {
            rules.append(BenchRule(id: id, passes: read && passes, detail: read ? detail : notRead, skipped: !read))
        }

        // The readings per set and arm.
        let rows = ProofSet.allCases.map { set -> ProofRow in
            func means(_ arm: String) -> ProofMeans {
                let readings = of(set).compactMap { $0.reading(arm) }
                func m(_ values: [Float]) -> Float? { values.isEmpty ? nil : Float(Stats.mean(values.map(Double.init))) }
                return ProofMeans(hknn: m(readings.map(\.hknn)), hlm: m(readings.compactMap(\.hlm)), lift: m(readings.compactMap(\.lift)),
                                  trace: m(readings.map(\.trace)), topCosine: m(readings.map(\.topCosine)))
            }
            return ProofRow(set: set, n: of(set).count, delta: means(d), frozen: means(f))
        }

        // Reported with no threshold.
        func float(_ value: Double?) -> Float? { value.map(Float.init) }
        let ownTexts = of(.own)
        let positions = ownTexts.reduce(0) { $0 + $1.positions }
        let sharper = ownTexts.reduce(0) { $0 + $1.sharper }
        let reported = [
            ProofMeasure(name: "own against its shuffled copy, AUROC by H_knn",
                         delta: float(BenchFormat.auroc(hknn(.ownShuffled, d), hknn(.own, d))), frozen: float(BenchFormat.auroc(hknn(.ownShuffled, f), hknn(.own, f)))),
            ProofMeasure(name: "own against its shuffled copy, AUROC by the trace",
                         delta: float(BenchFormat.auroc(values(.own, d) { $0.trace }, values(.ownShuffled, d) { $0.trace })),
                         frozen: float(BenchFormat.auroc(values(.own, f) { $0.trace }, values(.ownShuffled, f) { $0.trace }))),
            ProofMeasure(name: "withheld against unseen, AUROC by H_knn",
                         delta: float(BenchFormat.auroc(hknn(.unseen, d), hknn(.withheld, d))), frozen: float(BenchFormat.auroc(hknn(.unseen, f), hknn(.withheld, f)))),
            ProofMeasure(name: "own positions where the delta's H_knn is lower", value: positions > 0 ? Float(sharper) / Float(positions) : nil),
            ProofMeasure(name: "own: the mean drop in H_knn, frozen less delta", value: float(mean(drops(.own)))),
            ProofMeasure(name: "withheld: the mean drop in H_knn, frozen less delta", value: float(mean(drops(.withheld)))),
        ]

        var mechanisms: [String] = []
        if !c0 {
            mechanisms.append("C0 fails: " + (failures.first ?? "the frozen arm's H_lm differs from the commons' at \(grouped(mismatched)) positions, so its head is not the commons' blocks"))
        } else {
            if !d1 { mechanisms.append("D1 fails: lift over the commons does not tell withheld from unseen (AUROC \(num(liftAUROC)))") }
            if !d2 {
                if hlmDelta == nil || hlmFrozen == nil {
                    mechanisms.append("D2 fails: an AUROC could not be computed, a set is empty")
                } else if hlmDelta! < bar {
                    mechanisms.append("D2 fails: the delta's H_lm does not tell withheld from unseen (AUROC \(num(hlmDelta)))")
                } else if hlmFrozen! >= bar {
                    mechanisms.append("D2 fails: the commons' blocks tell withheld from unseen too (AUROC \(num(hlmFrozen))), so it is not the delta")
                } else {
                    mechanisms.append("D2 fails: the frozen arm comes within 0.10 of the delta (\(num(hlmFrozen)) against \(num(hlmDelta)))")
                }
            }
            if !r1 {
                mechanisms.append("R1 fails: an index does not find its own text against unrelated text (AUROC \(num(findDelta)) delta, \(num(findFrozen)) frozen)")
            }
            if !r2 {
                mechanisms.append(lower < sharperShare ? "R2 fails: the delta's retrieval is surer on only \(pct(lower)) of its own texts"
                                                       : "R2 fails: the delta's gain on its own texts is within noise (Welch's z \(num(z)))")
            }
        }
        let proved = c0 && d1 && d2 && r1 && r2
        return ProofVerdict(rules: rules, evidence: evidence, rows: rows, reported: reported, proved: proved,
                            summary: proved ? "proved: C0, D1, D2, R1 and R2 pass" : mechanisms.joined(separator: "; "))
    }

    /// 18,402.
    static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
