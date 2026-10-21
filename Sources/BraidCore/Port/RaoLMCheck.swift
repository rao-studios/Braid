//
//  RaoLMCheck.swift
//  BraidCore
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The port validation's two record-level checks. (a) Shares: Braid's arithmetic over what
//        RaoLM logged — w′ the gate renormalised over the open strands, share_t = w′_t·p_t(y)/p(y)
//        with p_t RaoLM's `alone` — must equal RaoLM's logged share within 1e-5; the plan's form
//        from the gate, open, p_lm and RaoLM's `knn` (which is w′_t·p_knn,t, not p_knn) is checked
//        beside it. (b) Trace: Braid's TraceTracker, fed RaoLM's tokens and each strand's own hits
//        over the node's index layout, must reproduce RaoLM's trajectory length and next token at
//        every position. Plus the mapping itself: every pooled hit lands on its node's index at the
//        value and key position RaoLM logged.
//  PIN:  A Thread strand's hits are missing from a record where RaoLM gave its retrieval no weight;
//        the tracker cannot seed chains there, so a mismatch after such a position is counted
//        apart (and called explained only when the chain's window holds one); a mismatch with every
//        earlier hit present is a failure. The final position (after the text's last token) is
//        replayed with no hits: hits there seed only chains for a token that never comes.
//

import Foundation

public enum RaoLMCheck {
    /// The plan's tolerance on recomputed shares.
    public static let shareTolerance = 1e-5

    // MARK: - (a) Shares

    public struct ShareWorst: Codable, Sendable, Equatable {
        public var file: String
        public var index: Int
        public var strand: String
        public var recomputed: Double
        public var logged: Float
    }

    public struct Shares: Codable, Sendable, Equatable {
        public var records = 0
        public var positions = 0
        /// Strand shares compared: every strand at every position.
        public var values = 0
        /// share_t = w′_t·alone_t / Σ_s w′_s·alone_s against the logged share.
        public var maxErrorAlone = 0.0
        /// The same from the gate, open, p_lm and RaoLM's knn: (λ_t·knn_t + (1−λ_t)·w′_t·p_lm,t) / Σ.
        public var maxErrorLogged = 0.0
        public var worst: ShareWorst?
        /// |Σ_t w′_t·alone_t − mixedProb| / mixedProb.
        public var maxRelativeP = 0.0
        /// |Σ_t w′_t·λ_t − the trace's λ|.
        public var maxLambdaError = 0.0
        /// |Σ_t share_t − 1| as logged.
        public var maxShareSumError = 0.0
        /// Where a strand was asked and its hits are in the record: |λ_t·p_knn,t(y) + (1−λ_t)·p_lm,t(y) − alone|,
        /// p_knn from its hits at τ: the hits, τ and λ_t the import uses reproduce RaoLM's own p_t.
        public var aloneFromHits = 0
        public var maxAloneFromHitsError = 0.0

        public init() {}

        public var maxError: Double { max(maxErrorAlone, maxErrorLogged) }
        public var passes: Bool { values > 0 && maxError <= RaoLMCheck.shareTolerance }

        public mutating func add(_ other: Shares) {
            records += other.records
            positions += other.positions
            values += other.values
            if other.maxErrorAlone > maxErrorAlone { worst = other.worst }
            maxErrorAlone = max(maxErrorAlone, other.maxErrorAlone)
            maxErrorLogged = max(maxErrorLogged, other.maxErrorLogged)
            maxRelativeP = max(maxRelativeP, other.maxRelativeP)
            maxLambdaError = max(maxLambdaError, other.maxLambdaError)
            maxShareSumError = max(maxShareSumError, other.maxShareSumError)
            aloneFromHits += other.aloneFromHits
            maxAloneFromHitsError = max(maxAloneFromHitsError, other.maxAloneFromHitsError)
        }
    }

    public static func shares(_ g: RaoLMGeneration, file: String, ranges: [Range<Int>]) -> Shares {
        var result = Shares()
        guard let braid = g.braid else { return result }
        result.records = 1
        let lambdas = RaoLMImport.lambdas(g, braid: braid)
        let tau = Double(g.params.tau)
        for trace in g.traces {
            guard let strands = trace.strands, strands.count == braid.strands.count else { continue }
            result.positions += 1
            let open = strands.map(\.open)
            let weights = Gate.renormalised(strands.map { Double($0.gate) }, open: open)
            let parts = strands.indices.map { t -> Double in open[t] ? weights[t] * Double(strands[t].alone ?? 0) : 0 }
            let logged = strands.indices.map { t -> Double in
                open[t] ? lambdas[t] * Double(strands[t].knn) + (1 - lambdas[t]) * weights[t] * Double(strands[t].lmProb ?? 0) : 0
            }
            let p = parts.reduce(0, +)
            let pLogged = logged.reduce(0, +)
            for t in strands.indices {
                let fromAlone = p > 0 ? parts[t] / p : weights[t]
                let fromLogged = pLogged > 0 ? logged[t] / pLogged : weights[t]
                let error = abs(fromAlone - Double(strands[t].share))
                if result.worst == nil || error > result.maxErrorAlone {
                    result.worst = ShareWorst(file: file, index: trace.index, strand: strands[t].strand, recomputed: fromAlone, logged: strands[t].share)
                    result.maxErrorAlone = error
                }
                result.maxErrorLogged = max(result.maxErrorLogged, abs(fromLogged - Double(strands[t].share)))
                result.values += 1
            }
            if trace.mixedProb > 0 { result.maxRelativeP = max(result.maxRelativeP, abs(p - Double(trace.mixedProb)) / Double(trace.mixedProb)) }
            let lambda = strands.indices.reduce(0.0) { $0 + weights[$1] * lambdas[$1] }
            result.maxLambdaError = max(result.maxLambdaError, abs(lambda - Double(trace.lambda)))
            result.maxShareSumError = max(result.maxShareSumError, abs(strands.reduce(0.0) { $0 + Double($1.share) } - 1))
            let hits = RaoLMImport.hits(trace, braid: braid, ranges: ranges)
            for t in strands.indices where !braid.strands[t].isCommons {
                guard let own = hits[t], let alone = strands[t].alone, let plm = strands[t].lmProb else { continue }
                let w = Mixer.weights(own.map { Double($0.score) }, tau: tau)
                let pknn = own.indices.reduce(0.0) { $0 + (own[$1].value == Int32(trace.token) ? w[$1] : 0) }
                let p = lambdas[t] * pknn + (1 - lambdas[t]) * Double(plm)
                result.aloneFromHits += 1
                result.maxAloneFromHitsError = max(result.maxAloneFromHitsError, abs(p - Double(alone)))
            }
        }
        return result
    }

    // MARK: - The mapping onto each node's index

    public struct Mapping: Codable, Sendable, Equatable {
        /// Pooled hits mapped back to a node.
        public var hits = 0
        /// Hits in no Thread strand's range, or past its node's index.
        public var outside = 0
        /// The node's value at the hit's entry differs from the hit's value.
        public var valueMismatches = 0
        /// The node's key row and offset at the entry differ from the hit's key, less the strand's row offset.
        public var keyMismatches = 0
        /// Logged chains checked against the node: the entry's value is `next`, its key position is `at`.
        public var chains = 0
        public var chainMismatches = 0
        /// Logged node traces that differ from the rule's trace of the logged length.
        public var traces = 0
        public var traceMismatches = 0

        public init() {}

        public var passes: Bool { outside == 0 && valueMismatches == 0 && keyMismatches == 0 && chainMismatches == 0 && traceMismatches == 0 }

        public mutating func add(_ other: Mapping) {
            hits += other.hits
            outside += other.outside
            valueMismatches += other.valueMismatches
            keyMismatches += other.keyMismatches
            chains += other.chains
            chainMismatches += other.chainMismatches
            traces += other.traces
            traceMismatches += other.traceMismatches
        }
    }

    public static func mapping(_ g: RaoLMGeneration, layouts: [String: IndexLayout], ranges: [Range<Int>], rule: TraceRule) -> Mapping {
        var result = Mapping()
        guard let braid = g.braid else { return result }
        for trace in g.traces {
            for neighbour in trace.neighbours {
                result.hits += 1
                guard let t = ranges.firstIndex(where: { $0.contains(neighbour.entry) }), !braid.strands[t].isCommons,
                      let layout = layouts[braid.strands[t].name] else { result.outside += 1; continue }
                let strand = braid.strands[t]
                let entry = neighbour.entry - strand.entryOffset
                guard entry >= 0, entry < layout.values.count else { result.outside += 1; continue }
                if Int(layout.values[entry]) != neighbour.value { result.valueMismatches += 1 }
                if Int(layout.keyRow[entry]) != neighbour.key.row - strand.rowOffset || Int(layout.keyOffset[entry]) != neighbour.key.offset { result.keyMismatches += 1 }
            }
            for (t, share) in (trace.strands ?? []).enumerated() where t < braid.strands.count {
                guard let trajectory = share.trajectory else { continue }
                result.traces += 1
                if trajectory.trace != rule.trace(length: trajectory.length) { result.traceMismatches += 1 }
                guard let entry = trajectory.entry, let layout = layouts[braid.strands[t].name] else { continue }
                result.chains += 1
                let fits = entry >= 0 && entry < layout.values.count && trajectory.next == Int(layout.values[entry])
                    && trajectory.at == RaoLMPosition(row: Int(layout.keyRow[entry]), offset: Int(layout.keyOffset[entry]))
                if !fits { result.chainMismatches += 1 }
            }
        }
        return result
    }

    // MARK: - (b) Trace replay

    /// One record replayed: per strand (nil for the commons or a strand without a layout) the
    /// tracker's state at every trace, and after the text's last token; and where the record lacks
    /// the strand's hits.
    public struct Replay: Sendable {
        public var states: [[TraceState]?]
        public var final: [TraceState?]
        public var missing: [[Bool]]
        /// Per strand, per trace: its hits (empty where missing), for the readings.
        public var hits: [[[Hit]]]
    }

    public static func replay(_ g: RaoLMGeneration, corpora: [String: TraceCorpus], ranges: [Range<Int>], rule: TraceRule) -> Replay {
        guard let braid = g.braid else { return Replay(states: [], final: [], missing: [], hits: []) }
        let tokens = (g.prompt.tokens + g.tokens).map { Int32($0) }
        let n = braid.strands.count
        var trackers: [TraceTracker?] = braid.strands.map { $0.isCommons ? nil : corpora[$0.name].map { TraceTracker(corpus: $0, rule: rule) } }
        var states: [[TraceState]?] = trackers.map { $0 == nil ? nil : [] }
        var missing = [[Bool]](repeating: [], count: n)
        var hitsByStrand = [[[Hit]]](repeating: [], count: n)
        for trace in g.traces {
            let hits = RaoLMImport.hits(trace, braid: braid, ranges: ranges)
            let token = trace.index >= 1 && trace.index - 1 < tokens.count ? tokens[trace.index - 1] : -1
            for t in 0..<n {
                missing[t].append(hits[t] == nil && !braid.strands[t].isCommons)
                hitsByStrand[t].append(hits[t] ?? [])
                guard var tracker = trackers[t] else { continue }
                states[t]?.append(tracker.step(token: token, hits: hits[t] ?? []))
                trackers[t] = tracker
            }
        }
        var final: [TraceState?] = []
        for t in 0..<n {
            guard var tracker = trackers[t], let last = tokens.last else { final.append(nil); continue }
            final.append(tracker.step(token: last, hits: []))
            trackers[t] = tracker
        }
        return Replay(states: states, final: final, missing: missing, hits: hitsByStrand)
    }

    public struct StrandReplay: Codable, Sendable, Equatable {
        public var positions = 0
        public var matched = 0
        /// Positions where the record lacks the strand's hits.
        public var missingHits = 0
        /// Positions compared after the first one whose hits the record lacks.
        public var afterMissing = 0
        /// Mismatches with every earlier hit in the record: failures.
        public var mismatches = 0
        /// Mismatches after a position whose hits the record lacks.
        public var mismatchesAfterMissing = 0
        /// Of those, the ones whose chain window (back by the longer chain and two bridges) holds such a position.
        public var explained = 0

        public init() {}

        public mutating func add(_ other: StrandReplay) {
            positions += other.positions
            matched += other.matched
            missingHits += other.missingHits
            afterMissing += other.afterMissing
            mismatches += other.mismatches
            mismatchesAfterMissing += other.mismatchesAfterMissing
            explained += other.explained
        }
    }

    public struct TraceMismatch: Codable, Sendable, Equatable {
        public var set: String
        public var file: String
        public var strand: String
        public var index: Int
        public var loggedLength: Int
        public var loggedNext: Int?
        public var replayedLength: Int
        public var replayedNext: Int?
        public var afterMissingHits: Bool
        public var explained: Bool
        /// Trace indices in the chain's window where the record lacks the strand's hits.
        public var missingNear: [Int]
    }

    public struct Traces: Codable, Sendable, Equatable {
        public var records = 0
        public var strands: [String: StrandReplay] = [:]
        public var mismatches: [TraceMismatch] = []

        public init() {}

        public var positions: Int { strands.values.reduce(0) { $0 + $1.positions } }
        public var passes: Bool {
            positions > 0 && strands.values.allSatisfy { $0.mismatches == 0 && $0.explained == $0.mismatchesAfterMissing }
        }

        public mutating func add(_ other: Traces) {
            records += other.records
            for (name, tally) in other.strands { strands[name, default: StrandReplay()].add(tally) }
            mismatches += other.mismatches.prefix(max(0, 200 - mismatches.count))
        }
    }

    /// Compares a record's logged trajectories with its replay.
    public static func traces(_ g: RaoLMGeneration, replay: Replay, set: String, file: String, rule: TraceRule) -> Traces {
        var result = Traces()
        guard let braid = g.braid else { return result }
        result.records = 1
        for (t, strand) in braid.strands.enumerated() {
            guard let states = replay.states[t] else { continue }
            var tally = StrandReplay()
            var missingSeen = false
            for (i, trace) in g.traces.enumerated() where i < states.count {
                // Hits seed chains for later tokens: a lack at i leaves the states after i unknown.
                defer { if replay.missing[t][i] { tally.missingHits += 1; missingSeen = true } }
                guard let shares = trace.strands, t < shares.count else { continue }
                let logged = shares[t].trajectory
                let loggedLength = logged?.length ?? 0
                let loggedNext = logged?.next
                let state = states[i]
                tally.positions += 1
                if missingSeen { tally.afterMissing += 1 }
                if loggedLength == state.length && loggedNext == state.next.map(Int.init) {
                    tally.matched += 1
                    continue
                }
                let reach = max(loggedLength, state.length) + 2 * rule.bridge + 1
                let near = (max(0, i - reach)..<i).filter { replay.missing[t][$0] }.map { g.traces[$0].index }
                if missingSeen {
                    tally.mismatchesAfterMissing += 1
                    if !near.isEmpty { tally.explained += 1 }
                } else {
                    tally.mismatches += 1
                }
                if result.mismatches.count < 200 {
                    result.mismatches.append(TraceMismatch(set: set, file: file, strand: strand.name, index: trace.index, loggedLength: loggedLength,
                                                           loggedNext: loggedNext, replayedLength: state.length, replayedNext: state.next.map(Int.init),
                                                           afterMissingHits: missingSeen, explained: missingSeen && !near.isEmpty, missingNear: near))
                }
            }
            result.strands[strand.name] = tally
        }
        return result
    }

    // MARK: - What phase A reads of a record

    /// A scored text as phase A reads it, kept from the check's single pass so no record is decoded twice.
    public struct ScoredText: Sendable {
        public var file: String
        public var strands: [String]
        public var commons: Int?
        public var tokens: [Int32]
        /// Per trace: its index (the text position whose token it predicts).
        public var traceIndex: [Int]
        /// Per strand (nil for the commons): the chain length after each of the text's tokens, step j
        /// after token j for j in 0..<n: the record's trajectories, the last from Braid's tracker.
        public var lengths: [[Int]?]
        /// Per strand: the replay's longest partition-bounded run.
        public var partitionRuns: [Int]
        /// Per strand: the longest chain the record's hits alone show (TraceAudit, RaoLM's convention).
        public var wireLongest: [Int]
        /// Per strand, per trace: p_knn,t of the token (from the hits; from `alone` where they are missing).
        public var pknn: [[Float]]
        /// Per strand, per trace: the best score among its hits (nil where they are missing).
        public var best: [[Float?]]
        /// Per trace, per strand: what RaoLM logged.
        public var alone: [[Float?]]
        public var memory: [[Float]]
        public var share: [[Float]]
        public var open: [[Bool]]
    }

    public static func scoredText(_ g: RaoLMGeneration, file: String, replay: Replay, imported: ImportedSession,
                                  documentOfRow: [String: [Int32: String]]) -> ScoredText {
        let braid = g.braid
        let names = braid?.strands.map(\.name) ?? []
        let tokens = (g.prompt.tokens + g.tokens).map { Int32($0) }
        var lengths: [[Int]?] = []
        var wire: [Int] = []
        var runs: [Int] = []
        for (t, name) in names.enumerated() {
            guard braid?.strands[t].isCommons == false, let final = replay.final[t] else {
                lengths.append(nil); wire.append(0); runs.append(0); continue
            }
            var steps = [Int](repeating: 0, count: tokens.count)
            for trace in g.traces where trace.index >= 1 && trace.index - 1 < steps.count {
                steps[trace.index - 1] = trace.strands?[t].trajectory?.length ?? 0
            }
            if !steps.isEmpty { steps[steps.count - 1] = final.length }
            lengths.append(steps)
            var hits = [[Hit]](repeating: [], count: tokens.count)
            for (i, trace) in g.traces.enumerated() where trace.index >= 1 && trace.index - 1 < hits.count { hits[trace.index - 1] = replay.hits[t][i] }
            wire.append(TraceAudit.wireLengths(tokens: tokens, hits: hits, documentOfRow: documentOfRow[name] ?? [:]).max() ?? 0)
            runs.append(max((replay.states[t] ?? []).map(\.partitionRun).max() ?? 0, final.partitionRun))
        }
        let records = imported.steps.compactMap(\.threads)
        return ScoredText(
            file: file, strands: names, commons: braid?.strands.firstIndex(where: \.isCommons), tokens: tokens, traceIndex: g.traces.map(\.index),
            lengths: lengths, partitionRuns: runs, wireLongest: wire,
            pknn: names.indices.map { t in records.map { $0[t].pknn } },
            best: names.indices.map { t in g.traces.indices.map { i in replay.missing[t][i] ? nil : replay.hits[t][i].first?.score } },
            alone: g.traces.map { $0.strands?.map(\.alone) ?? [] },
            memory: g.traces.map { $0.strands?.map { $0.memory ?? $0.gate } ?? [] },
            share: g.traces.map { $0.strands?.map(\.share) ?? [] },
            open: g.traces.map { $0.strands?.map(\.open) ?? [] })
    }
}
