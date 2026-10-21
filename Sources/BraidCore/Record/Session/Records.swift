//
//  Records.swift
//  BraidCore
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: What one position of a braided generation records, per strand and for the token: the
//        hits a node retrieved, its trace state, its gate numbers, the two stored entropies, the
//        shadow β4 counterfactual, and the token's probability and candidates. This is the
//        session log's `tok` line and the in-memory step; nothing else is stored per position.
//  PIN:  Exactly two entropies per strand (H_lm, H_knn). Everything else (gate entropy, lift,
//        mixture-entropy bounds, credit, spans, royalties) is derived at read time. Keys are short
//        because a session writes one of these per token per strand.
//

import Foundation

/// What one strand did at one position.
public struct ThreadRecord: Codable, Sendable, Equatable {
    /// The gate's memory for this strand (the live gate is the memory).
    public var memory: Float
    /// Its weight in the mixture after renormalising over the open strands (0 when closed).
    public var weight: Float
    public var open: Bool
    /// p_lm,t(y): nil when the strand was not asked for its state.
    public var plm: Float?
    /// p_knn,t(y), the strand's own retrieval mass on the token.
    public var pknn: Float
    /// share_t(y) = w′_t·p_t(y)/p(y). Logged so verify can recompute and compare.
    public var share: Float
    /// The two stored entropies: H(p_lm,t) (nil when not asked) and H(p_knn,t).
    public var hlm: Float?
    public var hknn: Float
    /// At prompt and context positions: the bounded evidence ratio ρ̃_t the gate observed.
    public var evidence: Float?
    /// The trajectory module's e_t that entered the evidence (step 7); nil before.
    public var module: Float?
    /// The shadow β4 counterfactual: the gate and the share this strand would have had under
    /// m_t·exp(β·(trace_t − mean trace)), never applied.
    public var shadowGate: Float
    public var shadowShare: Float
    public var hits: [Hit]
    public var trace: TraceState?
    /// The gate the mixture renormalised into `weight`, when it is not the memory: an imported RaoLM
    /// log's (its memory lifted by agreement, and in its trajectory arms times its trace term). Nil in
    /// Braid's own logs, where the live gate is the memory.
    public var gate: Float?

    public init(memory: Float, weight: Float, open: Bool, plm: Float?, pknn: Float, share: Float, hlm: Float?, hknn: Float,
                evidence: Float? = nil, module: Float? = nil, shadowGate: Float, shadowShare: Float, hits: [Hit], trace: TraceState?, gate: Float? = nil) {
        self.memory = memory
        self.weight = weight
        self.open = open
        self.plm = plm
        self.pknn = pknn
        self.share = share
        self.hlm = hlm
        self.hknn = hknn
        self.evidence = evidence
        self.module = module
        self.shadowGate = shadowGate
        self.shadowShare = shadowShare
        self.hits = hits
        self.trace = trace
        self.gate = gate
    }

    enum CodingKeys: String, CodingKey {
        case memory = "mem", weight = "w", open, plm, pknn, share, hlm = "Hlm", hknn = "Hknn", evidence = "ev", module = "mod"
        case shadowGate = "sg", shadowShare = "ss", hits, trace = "tr", gate = "g"
    }
}

/// One of the mixture's likeliest tokens at a position, split by strand.
public struct Candidate: Codable, Sendable, Equatable {
    public var token: Int32
    public var text: String
    public var prob: Float
    public var parts: [Float]

    public init(token: Int32, text: String, prob: Float, parts: [Float]) {
        self.token = token
        self.text = text
        self.prob = prob
        self.parts = parts
    }

    enum CodingKeys: String, CodingKey { case token = "tok", text = "txt", prob = "p", parts }
}

public enum StepSource: String, Codable, Sendable { case prompt, gen, ctx }
public enum StopReason: String, Codable, Sendable { case eos, sentence, max }

/// One position of a generation: the token at it and what every strand did there. Step `i`'s
/// strands predicted token `i` from tokens `0..<i`; the first prompt token has no strands.
public struct Step: Codable, Sendable, Equatable {
    public var kind: String = "tok"
    public var index: Int
    public var token: Int32
    public var text: String
    public var source: StepSource
    /// For a `ctx` line: the strand whose own context this position belongs to.
    public var owner: Int?
    /// p(y) of the mixture.
    public var prob: Float
    /// Σ_t w′_t·λ_t, the λ the mixture used.
    public var lambda: Float
    public var threads: [ThreadRecord]?
    public var candidates: [Candidate]?
    public var stop: StopReason?

    public init(index: Int, token: Int32, text: String, source: StepSource, owner: Int? = nil, prob: Float, lambda: Float,
                threads: [ThreadRecord]?, candidates: [Candidate]? = nil, stop: StopReason? = nil) {
        self.index = index
        self.token = token
        self.text = text
        self.source = source
        self.owner = owner
        self.prob = prob
        self.lambda = lambda
        self.threads = threads
        self.candidates = candidates
        self.stop = stop
    }

    enum CodingKeys: String, CodingKey {
        case kind, index = "i", token = "tok", text = "txt", source = "src", owner = "t", prob = "p", lambda = "lam", threads = "thr"
        case candidates = "cand", stop
    }

    public var isPrompt: Bool { source != .gen }

    /// The strand that supplied most of this token, when it supplied at least `threshold` of it.
    public func dominant(threshold: Float = 0.6) -> Int? {
        guard let threads, let best = threads.indices.max(by: { threads[$0].share < threads[$1].share }), threads[best].share >= threshold else { return nil }
        return best
    }
}
