//
//  StitchedBench.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: `braid bench stitched`: whether the trajectory module's stitched signature catches what a
//        Thread absorbed parametrically that its index does not support. The Thread trains on every
//        document but leaves P, a seeded fifth of them (`braid thread create … --withhold 0.2`), out
//        of its index. Reading P its reed is sure (H_lm far below the commons') while its retrieval
//        stays spread and its lift over the commons stays high. D = the share of positions from 24
//        inside a stitched run: H_lm,t ≤ 0.5·H_lm,c ∧ H_knn,t ≥ 0.5·ln 16 ∧ lift ≥ ln 2 for ≥ 8
//        positions. Nulls: its unfed documents in its own voice (N1), other Threads' documents and
//        generic prose (N2). Control: its indexed held documents (C). P with its sentences shuffled
//        is reported.
//  PIN:  Rules fixed before any numbers (the plan's bench table, S1–S3). D is read on the withheld
//        Thread; every Thread's D is kept. Texts are scored prompt-only with every strand asked and
//        the session log kept. `evaluate` is pure over the saved readings.
//

import BraidCore
import Foundation

public enum StitchedSet: String, Codable, Sendable, CaseIterable {
    /// P: documents the Thread trained on but did not index.
    case withheld
    /// P with its sentences reordered so none keeps its successor (reported).
    case withheldShuffled
    /// C: the Thread's indexed held documents.
    case control
    /// N1: the Thread's unfed documents, in its own voice.
    case unseen
    /// N2: other Threads' held documents, and generic prose.
    case unrelated
}

/// One Thread's reading of one text, from position `from` on.
public struct StitchedReading: Codable, Sendable, Equatable {
    public var thread: String
    /// D: the share of positions inside a stitched run.
    public var detector: Float
    /// The share of positions by the module's label (retrieval, stitched, unknown, commons, silent).
    public var labels: [String: Float]
    /// Means: the Thread's trace, its H_lm and H_knn, and its lift over the commons (ln p_t − ln p_c).
    public var trace: Float
    public var hlm: Float?
    public var hknn: Float
    public var lift: Float?

    public init(thread: String, detector: Float, labels: [String: Float], trace: Float, hlm: Float?, hknn: Float, lift: Float?) {
        self.thread = thread
        self.detector = detector
        self.labels = labels
        self.trace = trace
        self.hlm = hlm
        self.hknn = hknn
        self.lift = lift
    }
}

public struct StitchedText: Codable, Sendable, Equatable {
    public var set: StitchedSet
    public var label: String
    /// Whose document it is (nil for generic prose).
    public var owner: String?
    public var document: String?
    public var tokens: Int
    public var readings: [StitchedReading]

    public init(set: StitchedSet, label: String, owner: String?, document: String?, tokens: Int, readings: [StitchedReading]) {
        self.set = set
        self.label = label
        self.owner = owner
        self.document = document
        self.tokens = tokens
        self.readings = readings
    }

    public func reading(_ thread: String) -> StitchedReading? { readings.first { $0.thread == thread } }
}

public struct StitchedSizes: Codable, Sendable, Equatable {
    /// C and N1 texts.
    public var perNode = 20
    /// N2 texts per other Thread (beside the four generic passages).
    public var unrelatedPerThread = 10
    /// A document is read whole up to `maxTokens`, and only when it has at least `minTokens`.
    public var minTokens = 64
    public var maxTokens = 256
    public var seed: UInt64 = 42

    public init() {}
}

public struct StitchedReport: Codable, Sendable {
    public var bench = "stitched"
    public var createdAt: Date
    public var dataset: String
    public var threads: [String: String]
    public var gate: GateSettings
    public var module: ModuleSettings
    /// The Thread that trained on P but did not index it, and P.
    public var withheldThread: String
    public var withheld: [String]
    public var from: Int
    public var sizes: StitchedSizes
    public var texts: [StitchedText]
    public var rules: [BenchRule]
    public var reported: [String: Float]
    public var summary: String
    public var sessions: [String]? = nil
}

public enum StitchedBench {
    public static let from = TraceBench.from
    public static let fires: Float = 0.40
    public static let silent: Float = 0.10

    /// The Thread of `braid` whose index withholds documents (the named one, when several do).
    public static func withheldThread(in braid: BenchBraid, named: String? = nil) throws -> LoadedThread {
        let withholding = braid.threads.filter { !($0.node.index?.info.excluded ?? []).isEmpty }
        if let named {
            guard let thread = withholding.first(where: { $0.info.name == named }) else {
                throw BraidFailure.usage("thread \(named) withholds nothing from its index", hint: "create one: braid thread create <name> --corpus … --withhold 0.2")
            }
            return thread
        }
        guard let thread = withholding.first else {
            throw BraidFailure.usage("no Thread in the braid withholds documents from its index",
                                     hint: "create one with braid thread create <name> --corpus dataset:<name>#<node> --limit 40 --withhold 0.2, and pass it in --threads")
        }
        return thread
    }

    public static func run(braid: BenchBraid, world: BenchWorld, sizes: StitchedSizes = StitchedSizes(), thread named: String? = nil,
                           progress: ((String) -> Void)? = nil) throws -> StitchedReport {
        let holder = try withheldThread(in: braid, named: named)
        let name = holder.info.name
        let withheld = Set(holder.node.index?.info.excluded ?? [])
        let threads = try braid.benchThreads(world: world) { progress?("warning: \($0)") }
        guard let own = threads.first(where: { $0.name == name }) else { throw BraidFailure.data("thread \(name) is not in the braid") }
        let texts = buildTexts(world: world, withheldThread: own, withheld: withheld, others: threads.filter { $0.name != name },
                               tokenizer: braid.tokenizer, paragraphBreak: braid.tokenizer.paragraphBreak, sizes: sizes)
        progress?("\(name) withholds \(withheld.count) documents; texts: " + StitchedSet.allCases.map { set in "\(set.rawValue) \(texts.filter { $0.set == set }.count)" }.joined(separator: " · "))
        try braid.keepSession()
        defer { braid.finishSession() }
        let module = braid.settings.module ?? ModuleSettings()
        var results: [StitchedText] = []
        for (i, text) in texts.enumerated() {
            if i % 20 == 0 { progress?("scoring \(i)/\(texts.count)") }
            let generation = try braid.score(text.tokens)
            results.append(StitchedText(set: text.set, label: text.label, owner: text.owner, document: text.document, tokens: text.tokens.count,
                                        readings: readings(generation, names: braid.names, commons: braid.commonsIndex, settings: module)))
            if i % 8 == 7 { braid.relax() }
        }
        let verdict = evaluate(texts: results, withheldThread: name)
        return StitchedReport(createdAt: BenchFormat.wholeSecond(), dataset: world.name, threads: braid.threadRecords, gate: braid.settings.gate, module: module,
                              withheldThread: name, withheld: withheld.sorted(), from: from, sizes: sizes, texts: results, rules: verdict.rules,
                              reported: verdict.reported, summary: verdict.summary, sessions: braid.sessions.map(\.path))
    }

    struct Text {
        var set: StitchedSet
        var label: String
        var owner: String?
        var document: String?
        var tokens: [Int32]
    }

    /// P, P shuffled, C, N1 and N2, each document read as its Thread's index reads it (partitions
    /// joined by the break), whole up to `maxTokens`, when it has at least `minTokens`.
    static func buildTexts(world: BenchWorld, withheldThread own: BenchThread, withheld: Set<String>, others: [BenchThread], tokenizer: any Tokenizing,
                           paragraphBreak: [Int32], sizes: StitchedSizes) -> [Text] {
        var rng = SplitMix64(seed: sizes.seed)
        func fits(_ tokens: [Int32]) -> [Int32]? { tokens.count >= sizes.minTokens ? Array(tokens.prefix(sizes.maxTokens)) : nil }
        let documents = world.corpora[own.node]?.documents ?? []
        var texts: [Text] = []
        for document in documents where withheld.contains(document.id) && own.present.contains(document.id) {
            let (tokens, units) = BenchTexts.split(document, tokenizer: tokenizer, paragraphBreak: paragraphBreak)
            guard let read = fits(tokens) else { continue }
            texts.append(Text(set: .withheld, label: "\(own.name) · \(document.name) (withheld)", owner: own.name, document: document.id, tokens: read))
            if let units, let order = BenchTexts.shuffled(units, rng: &rng), let shuffled = fits(order.flatMap { $0 }) {
                texts.append(Text(set: .withheldShuffled, label: "\(own.name) · \(document.name) (withheld, shuffled)", owner: own.name, document: document.id, tokens: shuffled))
            }
        }
        var control = 0
        for document in documents where control < sizes.perNode && own.present.contains(document.id) && !withheld.contains(document.id) {
            guard let read = fits(BenchTexts.split(document, tokenizer: tokenizer, paragraphBreak: paragraphBreak).tokens) else { continue }
            texts.append(Text(set: .control, label: "\(own.name) · \(document.name) (indexed)", owner: own.name, document: document.id, tokens: read))
            control += 1
        }
        var unseen = 0
        for document in BenchTexts.exclusive(documents, crosslinks: world.crosslinks) where unseen < sizes.perNode && !own.present.contains(document.id) {
            guard let read = fits(BenchTexts.split(document, tokenizer: tokenizer, paragraphBreak: paragraphBreak).tokens) else { continue }
            texts.append(Text(set: .unseen, label: "\(own.name) · \(document.name) (unfed)", owner: own.name, document: document.id, tokens: read))
            unseen += 1
        }
        for other in others where other.node != own.node {
            var count = 0
            for document in BenchTexts.exclusive(world.corpora[other.node]?.documents ?? [], crosslinks: world.crosslinks)
            where count < sizes.unrelatedPerThread && other.present.contains(document.id) {
                guard let read = fits(BenchTexts.split(document, tokenizer: tokenizer, paragraphBreak: paragraphBreak).tokens) else { continue }
                texts.append(Text(set: .unrelated, label: "\(other.name) · \(document.name)", owner: other.name, document: document.id, tokens: read))
                count += 1
            }
        }
        for (i, passage) in BenchTexts.generic.enumerated() {
            texts.append(Text(set: .unrelated, label: "generic \(i + 1)", owner: nil, document: nil, tokens: Array(tokenizer.encode(passage).prefix(sizes.maxTokens))))
        }
        return texts
    }

    /// Every Thread's reading of one scoring: the module over its series, from position `from`.
    public static func readings(_ generation: Generation, names: [String], commons: Int?, settings: ModuleSettings) -> [StitchedReading] {
        let series = TrajectoryModule.series(generation.steps, commons: commons)
        return names.indices.compactMap { t -> StitchedReading? in
            guard t != commons, t < series.count else { return nil }
            let s = series[t]
            let all = TrajectoryModule.readAll(s, settings: settings)
            let tail = Array(all.indices.dropFirst(from))
            var labels: [String: Float] = [:]
            for i in tail { labels[all[i].label.rawValue, default: 0] += 1 }
            if !tail.isEmpty { for key in labels.keys { labels[key]! /= Float(tail.count) } }
            let hlm = tail.compactMap { s.hlm[$0] }
            let lift = tail.compactMap { s.lift[$0] }
            return StitchedReading(thread: names[t], detector: Float(TrajectoryModule.detectorScore(all, from: from)), labels: labels,
                                   trace: Float(Stats.mean(tail.map { Double(s.trace[$0]) })), hlm: hlm.isEmpty ? nil : Float(Stats.mean(hlm)),
                                   hknn: Float(Stats.mean(tail.map { s.hknn[$0] })), lift: lift.isEmpty ? nil : Float(Stats.mean(lift)))
        }
    }

    public static func rescore(_ report: StitchedReport) -> StitchedReport {
        var rescored = report
        let verdict = evaluate(texts: report.texts, withheldThread: report.withheldThread)
        rescored.rules = verdict.rules
        rescored.reported = verdict.reported
        rescored.summary = verdict.summary
        return rescored
    }

    // MARK: - The rule (pure)

    /// Read on the withheld Thread's D. S1: D ≥ 0.40 on ≥ 90% of P; D ≤ 0.10 on ≥ 90% of the nulls
    /// (N1 ∪ N2); AUROC (P against the nulls) ≥ 0.95. S2: the control is labelled retrieval, D ≤ 0.10
    /// on ≥ 95% of C. S3: P against C, Welch's z ≥ 3 and AUROC ≥ 0.95 (z against the nulls reported).
    public static func evaluate(texts: [StitchedText], withheldThread name: String) -> BenchVerdict {
        func of(_ sets: [StitchedSet]) -> [StitchedText] { texts.filter { sets.contains($0.set) } }
        func detector(_ sets: [StitchedSet]) -> [Double] { of(sets).compactMap { $0.reading(name).map { Double($0.detector) } } }
        let share = BenchFormat.share
        func pct(_ value: Double) -> String { BenchFormat.pct(value) }
        func num(_ value: Double?) -> String { BenchFormat.num(value) }
        let p = detector([.withheld])
        let nulls = detector([.unseen, .unrelated])
        let c = detector([.control])
        var rules: [BenchRule] = []
        var reported: [String: Float] = [:]

        let fires = share(p.map { $0 >= Double(Self.fires) })
        let quiet = share(nulls.map { $0 <= Double(silent) })
        let separation = BenchFormat.auroc(p, nulls)
        rules.append(BenchRule(
            id: "S1 stitched, not unseen", passes: !p.isEmpty && !nulls.isEmpty && fires >= 0.9 && quiet >= 0.9 && (separation ?? 0) >= 0.95,
            detail: "D ≥ 0.40 on \(pct(fires)) of \(p.count) withheld (needs 90%); ≤ 0.10 on \(pct(quiet)) of \(nulls.count) nulls (needs 90%); AUROC \(num(separation)) (needs 0.95)"))
        let controlQuiet = share(c.map { $0 <= Double(silent) })
        let retrieval = Stats.mean(of([.control]).compactMap { $0.reading(name).map { Double($0.labels["retrieval"] ?? 0) } })
        rules.append(BenchRule(
            id: "S2 the control is retrieval", passes: !c.isEmpty && controlQuiet >= 0.95,
            detail: "D ≤ 0.10 on \(pct(controlQuiet)) of \(c.count) indexed held documents (needs 95%); positions labelled retrieval \(pct(retrieval))"))
        let z = Stats.welchZ(p, c)
        let pc = BenchFormat.auroc(p, c)
        rules.append(BenchRule(
            id: "S3 withheld against indexed", passes: (z ?? 0) >= 3 && (pc ?? 0) >= 0.95,
            detail: "Welch's z \(num(z)) (needs 3), AUROC \(num(pc)) (needs 0.95), withheld mean D \(num(Stats.mean(p))) against indexed \(num(Stats.mean(c)))"))

        if let zNulls = Stats.welchZ(p, nulls) { reported["S3 Welch z, withheld against the nulls"] = Float(zNulls) }
        let shuffled = detector([.withheldShuffled])
        reported["withheld, shuffled: D ≥ 0.40"] = Float(share(shuffled.map { $0 >= Double(Self.fires) }))
        for set in StitchedSet.allCases {
            let mine = of([set]).compactMap { $0.reading(name) }
            guard !mine.isEmpty else { continue }
            reported["\(set.rawValue): mean D"] = Float(Stats.mean(mine.map { Double($0.detector) }))
            reported["\(set.rawValue): mean trace"] = Float(Stats.mean(mine.map { Double($0.trace) }))
            reported["\(set.rawValue): mean H_knn"] = Float(Stats.mean(mine.map { Double($0.hknn) }))
            let hlm = mine.compactMap(\.hlm)
            if !hlm.isEmpty { reported["\(set.rawValue): mean H_lm"] = Float(Stats.mean(hlm.map(Double.init))) }
            let lift = mine.compactMap(\.lift)
            if !lift.isEmpty { reported["\(set.rawValue): mean lift over the commons"] = Float(Stats.mean(lift.map(Double.init))) }
            for label in ["retrieval", "stitched", "unknown", "commons"] {
                reported["\(set.rawValue): positions labelled \(label)"] = Float(Stats.mean(mine.map { Double($0.labels[label] ?? 0) }))
            }
        }
        // Any Thread's signature on the nulls, not only the withheld Thread's.
        let anyThread = of([.unseen, .unrelated]).map { text in Double(text.readings.map(\.detector).max() ?? 0) }
        reported["nulls: every Thread's D ≤ 0.10"] = Float(share(anyThread.map { $0 <= Double(silent) }))

        let failed = rules.filter { !$0.passes }.map(\.id)
        let summary = failed.isEmpty ? "S1 to S3 pass on \(name)"
            : "failed: \(failed.joined(separator: ", ")); until S1 to S3 pass, the memorisation measure is a coverage lower bound"
        return BenchVerdict(rules: rules, reported: reported, summary: summary)
    }
}
