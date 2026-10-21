//
//  SessionReplay.swift
//  BraidCore
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: What a session log proves about itself with no model: the body hashes; shares that sum
//        to 1; w′ from memory and the open set; shares from p_lm, p_knn, λ and w′; p from the open
//        strands; H_knn from the hits; the memory recursion over prompt and context positions
//        (the gate replay that proves the clamp held); the shadow β4 from the memory and the
//        traces. The trace replay needs the index layout and lives beside it in the verifier.
//        A log imported from RaoLM (`source: raolm`) takes the checks that do not depend on
//        Braid's live gate: w′ comes from the gate it logs (RaoLM's), and the memory recursion and
//        the shadow are not replayed (`skipped(for:)` says so).
//

import Foundation

public struct ReplayIssue: Codable, Sendable, Equatable, CustomStringConvertible {
    public var generationID: String
    public var step: Int?
    public var strand: Int?
    public var check: String
    public var detail: String

    public init(generationID: String, step: Int?, strand: Int?, check: String, detail: String) {
        self.generationID = generationID
        self.step = step
        self.strand = strand
        self.check = check
        self.detail = detail
    }

    public var description: String {
        let at = [step.map { "step \($0)" }, strand.map { "strand \($0)" }].compactMap { $0 }.joined(separator: ", ")
        return "\(generationID) \(at.isEmpty ? "" : "(\(at)) ")\(check): \(detail)"
    }
}

public enum SessionReplay {
    public struct Tolerances: Sendable {
        public var shareSum: Double = 1e-5
        public var arithmetic: Double = 1e-6
        public var entropy: Double = 1e-5
        public var memory: Double = 1e-5
        public init() {}
    }

    /// The checks a log does not take, by its source: an imported RaoLM log's memory moved under
    /// RaoLM's gate, not Braid's live gate, and it ran no shadow.
    public static func skipped(for header: SessionHeader) -> [String] {
        header.source == RaoLMImport.source ? ["memory recursion", "shadow β4"] : []
    }

    /// The strands in effect for a generation: the header's order with earlier memberships applied.
    public static func strands(for generation: LoggedGeneration, session: LoggedSession) -> [SessionThread] {
        var strands = session.header.threads
        for line in session.membership where line.kind == "attach" || line.kind == "detach" {
            // Membership lines before this generation (by name list) are already folded into `gen.strands`.
            _ = line
        }
        // The generation line records its own strand order; map names back to the header or the attach lines.
        let known = session.header.threads + session.membership.filter { $0.kind == "attach" }.map(\.thread)
        strands = generation.gen.strands.compactMap { name in known.last { $0.name == name } }
        return strands
    }

    /// Per step of the generation (aligned with `generation.steps`), the strands its records are in:
    /// the generation's strand order with every attach and detach line before that step applied. A
    /// context line's one record is its owner's.
    public static func slots(for generation: LoggedGeneration, session: LoggedSession) -> [[StrandSlot]] {
        var current = strands(for: generation, session: session).map(StrandSlot.init)
        var membershipIndex = 0
        var result: [[StrandSlot]] = []
        for (k, step) in generation.steps.enumerated() {
            while membershipIndex < generation.membership.count, generation.membership[membershipIndex].before == k {
                let line = generation.membership[membershipIndex].line
                if line.kind == "attach" {
                    current.append(StrandSlot(line.thread))
                } else if current.indices.contains(line.strand) {
                    current.remove(at: line.strand)
                }
                membershipIndex += 1
            }
            if step.source == .ctx, let owner = step.owner, current.indices.contains(owner) {
                result.append([current[owner]])
            } else {
                result.append(current)
            }
        }
        return result
    }

    /// Every arithmetic check over one generation.
    public static func check(_ generation: LoggedGeneration, session: LoggedSession, tolerances: Tolerances = Tolerances()) -> [ReplayIssue] {
        var issues: [ReplayIssue] = []
        let id = generation.gen.generationID
        let settings = session.header.gate
        func issue(_ check: String, _ detail: String, step: Int? = nil, strand: Int? = nil) {
            issues.append(ReplayIssue(generationID: id, step: step, strand: strand, check: check, detail: detail))
        }
        if let end = generation.end, end.bodySHA256 != generation.bodySHA256 {
            issue("body", "the end line's sha256 \(end.bodySHA256.prefix(12)) is not the body's \(generation.bodySHA256.prefix(12))")
        }
        var strands = strands(for: generation, session: session)
        let commons = strands.firstIndex(where: \.commons)
        var state = GateState(strands: strands.count, commons: commons, prior: settings.commonsPrior)
        let liveGate = skipped(for: session.header).isEmpty
        var stateKnown = liveGate
        var membershipIndex = 0
        for (k, step) in generation.steps.enumerated() {
            // Apply memberships that precede this step.
            while membershipIndex < generation.membership.count, generation.membership[membershipIndex].before == k {
                let line = generation.membership[membershipIndex].line
                if line.kind == "attach" {
                    strands.append(line.thread)
                    Gate.attach(&state)
                } else if strands.indices.contains(line.strand) {
                    strands.remove(at: line.strand)
                    Gate.detach(&state, at: line.strand)
                }
                membershipIndex += 1
            }
            guard let threads = step.threads else { continue }
            if step.source == .ctx { continue }
            if threads.count != strands.count {
                issue("strands", "\(threads.count) records for \(strands.count) strands", step: k)
                stateKnown = false
                continue
            }
            let shareSum = threads.reduce(0.0) { $0 + Double($1.share) }
            if abs(shareSum - 1) > tolerances.shareSum { issue("shares", "sum \(shareSum)", step: k) }
            // w′ from the gate and open: the memory (Braid's live gate), or the gate a record logs as its own.
            let gates = threads.map { Double($0.gate ?? $0.memory) }
            let open = threads.map(\.open)
            let weights = Gate.renormalised(gates, open: open)
            for t in threads.indices where abs(weights[t] - Double(threads[t].weight)) > tolerances.arithmetic {
                issue("weights", "w′ \(threads[t].weight) recomputes as \(weights[t])", step: k, strand: t)
            }
            // p and shares from the logged per-strand probabilities.
            let lambdas = strands.map { Double($0.lambda) }
            let probabilities: [Double?] = threads.indices.map { t in
                guard let plm = threads[t].plm else { return nil }
                return lambdas[t] * Double(threads[t].pknn) + (1 - lambdas[t]) * Double(plm)
            }
            let p = threads.indices.reduce(0.0) { $0 + (open[$1] ? weights[$1] * (probabilities[$1] ?? 0) : 0) }
            if abs(p - Double(step.prob)) > tolerances.arithmetic * 10 { issue("p", "p \(step.prob) recomputes as \(p)", step: k) }
            if p > 0 {
                for t in threads.indices {
                    let expected = open[t] ? weights[t] * (probabilities[t] ?? 0) / p : 0
                    if abs(expected - Double(threads[t].share)) > tolerances.arithmetic * 10 {
                        issue("share", "share \(threads[t].share) recomputes as \(expected)", step: k, strand: t)
                    }
                }
            }
            // H_knn from the hits.
            if session.header.hitsLogged >= 16 {
                for t in threads.indices {
                    let w = Mixer.weights(threads[t].hits.map { Double($0.score) }, tau: Double(strands[t].tau))
                    var knn: [Int32: Double] = [:]
                    for (i, hit) in threads[t].hits.enumerated() { knn[hit.value, default: 0] += w[i] }
                    let h = Mixer.entropy(knn.values)
                    if abs(h - Double(threads[t].hknn)) > tolerances.entropy { issue("Hknn", "\(threads[t].hknn) recomputes as \(h)", step: k, strand: t) }
                }
            }
            // The shadow from the memory and the traces.
            if liveGate {
                let traces = threads.map { Double($0.trace?.trace ?? 0) }
                let shadow = Gate.shadowWeights(GateState(memoryOnly: threads.map { Double($0.memory) }, commons: commons), traces: traces, beta: settings.shadowBeta)
                for t in threads.indices where abs(shadow[t] - Double(threads[t].shadowGate)) > tolerances.arithmetic * 10 {
                    issue("shadow", "shadow gate \(threads[t].shadowGate) recomputes as \(shadow[t])", step: k, strand: t)
                }
            }
            // The memory recursion: this step's memory must be what the gate holds now; prompt
            // positions then move it by the logged evidence.
            if stateKnown {
                for t in threads.indices where abs(state.memory[t] - Double(threads[t].memory)) > tolerances.memory {
                    issue("memory", "memory \(threads[t].memory) recomputes as \(state.memory[t])", step: k, strand: t)
                    stateKnown = false
                }
                if step.source == .prompt, k > 0 || threads.count > 0 {
                    let likelihoods = threads.indices.map { t -> Double in
                        probabilities[t] ?? lambdas[t] * Double(threads[t].pknn)
                    }
                    let module: [Double]? = threads.allSatisfy { $0.module != nil } ? threads.map { Double($0.module!) } : nil
                    Gate.observe(&state, likelihoods: likelihoods, module: module, settings: settings)
                }
            }
        }
        return issues
    }
}
