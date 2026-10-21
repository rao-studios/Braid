//
//  Gate.swift
//  BraidCore
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The live gate: a memory over strands moved by bounded evidence at prompt positions,
//        read as the gate weights; the open set; the renormalisation over open strands; attach
//        and detach; and the shadow β4 counterfactual the owner asked to log beside it.
//  PIN:  RaoLM's `observe`/`observeLift` arithmetic, exactly, in Double. One clamp: the module's
//        evidence (step 7) enters the log-evidence before it, so nothing moves a token past
//        ceiling/floor. Trace never enters the live gate; the shadow is computed from the same
//        memory and the traces and is recorded, never applied.
//

import Foundation

/// What the gate remembers of a text: which strand has been predicting it, and how much.
public struct GateState: Codable, Sendable, Equatable {
    /// Sums to 1.
    public var memory: [Double]
    /// Per strand, how much of the recent text it predicted (0 none, 1 all).
    public var credibility: [Double]
    public var seen: Int
    public var predicted: [Int]
    /// The commons strand's index, when the braid has one: the memory starts on it and every other
    /// strand's evidence is its lift over it.
    public var commons: Int?

    public init(strands: Int, commons: Int? = nil, prior: Double = 0.9) {
        let n = max(0, strands)
        memory = [Double](repeating: n > 0 ? 1 / Double(n) : 0, count: n)
        credibility = [Double](repeating: 0, count: n)
        seen = 0
        predicted = [Int](repeating: 0, count: n)
        if let commons, (0..<n).contains(commons) {
            self.commons = commons
            let p = n > 1 ? min(max(prior, 0), 1) : 1
            memory = (0..<n).map { $0 == commons ? p : (1 - p) / Double(n - 1) }
        }
    }

    public var count: Int { memory.count }

    /// The strand with the most memory; the first of equals.
    public var leader: Int {
        var best = 0
        for t in memory.indices where memory[t] > memory[best] { best = t }
        return best
    }
}

public enum Gate {
    /// The floor a strand's gate must reach to be mixed in: `openFloor` is what two strands use,
    /// and it shrinks as strands are added so an even gate stays above it.
    public static func floor(_ openFloor: Double, strands: Int) -> Double { openFloor * 2 / Double(max(2, strands)) }

    /// One prompt (or context) token was fixed; `likelihoods[t]` is what strand t alone gave it
    /// (its retrieval lower bound when it was not asked). `module[t]` is the trajectory module's
    /// e_t ∈ [−1, 1] for the strand, nil before step 7. Returns the bounded evidence ρ̃_t that
    /// entered, for the record.
    @discardableResult
    public static func observe(_ state: inout GateState, likelihoods: [Double], module: [Double]? = nil, settings: GateSettings) -> [Double] {
        let n = state.memory.count
        guard n > 0, likelihoods.count == n else { return [] }
        let floorValue = max(settings.evidenceFloor, 1e-6)
        let reach = settings.reach
        let span = log(reach)
        let gains: [Double]
        let losses: [Double]
        let ratios: [Double]
        if let c = state.commons, settings.evidence == .lift {
            let base = max(likelihoods[c], 1e-12)
            ratios = (0..<n).map { t -> Double in
                guard t != c else { return 1 }
                var evidence = log(max(likelihoods[t], 1e-300) / base)
                // The module's e_t enters only when κ > 0 (it is logged whatever κ is).
                if settings.moduleGain > 0, let module, module.indices.contains(t) { evidence += settings.moduleGain * min(max(module[t], -1), 1) * span }
                return exp(min(max(evidence, -span), span))
            }
            gains = ratios.map { max(0, log($0)) / span }
            losses = ratios.map { max(0, -log($0)) / span }
        } else {
            // Absolute evidence: the probability between the floor and the ceiling; 0 loss = predicted.
            let ceiling = max(settings.evidenceCeiling, floorValue)
            let hits = likelihoods.map { min(max($0, floorValue), ceiling) }
            ratios = hits.map { $0 / ceiling }
            losses = hits.map { span > 0 ? log(ceiling / $0) / span : 0 }
            gains = losses.map { 1 - $0 }
        }
        state.seen += 1
        for t in 0..<n where likelihoods[t] >= floorValue { state.predicted[t] += 1 }
        let rate = min(max(settings.credibilityRate, 0), 1)
        for t in 0..<n { state.credibility[t] = (1 - rate) * state.credibility[t] + rate * gains[t] }
        guard n > 1 else {
            state.memory = [1]
            return ratios
        }
        let others = (0..<n).filter { $0 != state.commons }
        let weight = (settings.evidence == .lift && state.commons != nil ? others : Array(0..<n)).map { state.credibility[$0] }.max() ?? 0
        var updated = (0..<n).map { state.memory[$0] * pow(ratios[$0], weight) }
        let total = updated.reduce(0, +)
        updated = total > 0 ? updated.map { $0 / total } : state.memory
        let alpha = min(max(settings.shareRate, 0), 1)
        let given = (0..<n).map { updated[$0] * (1 - pow(1 - alpha, losses[$0])) }
        let pool = given.reduce(0, +)
        state.memory = (0..<n).map { updated[$0] - given[$0] + (pool - given[$0]) / Double(n - 1) }
        return ratios
    }

    /// The live gate weights: the memory.
    public static func weights(_ state: GateState) -> [Double] { state.memory }

    /// The shadow β4 counterfactual: the memory multiplied by exp(β·(trace_t − mean trace)) and
    /// renormalised. Logged beside the live gate; never applied.
    public static func shadowWeights(_ state: GateState, traces: [Double], beta: Double) -> [Double] {
        let memory = state.memory
        guard !memory.isEmpty, traces.count == memory.count else { return memory }
        let mean = traces.reduce(0, +) / Double(traces.count)
        let gates = memory.indices.map { memory[$0] * exp(beta * (traces[$0] - mean)) }
        let total = gates.reduce(0, +)
        return total > 0 ? gates.map { $0 / total } : memory
    }

    /// Which strands are mixed in: those at the floor, the largest always, the commons always;
    /// everyone when every gate is 0.
    public static func open(_ gates: [Double], commons: Int?, floor: Double) -> [Bool] {
        guard !gates.isEmpty else { return [] }
        if gates.allSatisfy({ $0 <= 0 }) { return gates.map { _ in true } }
        var best = 0
        for t in gates.indices where gates[t] > gates[best] { best = t }
        return gates.indices.map { t in t == best || t == commons || (gates[t] >= floor && gates[t] > 0) }
    }

    /// w′_t = g_t/Σ_open g; 0 when closed; even over the open strands when their gates sum to 0.
    public static func renormalised(_ gates: [Double], open: [Bool]) -> [Double] {
        let total = gates.indices.reduce(0.0) { $0 + (open[$1] ? gates[$1] : 0) }
        let count = Double(open.filter { $0 }.count)
        return gates.indices.map { t in
            guard open[t] else { return 0 }
            return total > 0 ? gates[t] / total : 1 / max(count, 1)
        }
    }

    /// Entropy of a weight vector (the gate's entropy is a derived view).
    public static func entropy(_ weights: [Double]) -> Double {
        var h = 0.0
        for w in weights where w > 0 { h -= w * log(w) }
        return h
    }

    /// A strand joins at the end: it takes 1/(k+1) of the Threads' memory mass, pro-rata from
    /// each Thread (the commons keeps its own), with no credibility yet. Σ memory stays 1.
    public static func attach(_ state: inout GateState) {
        let n = state.count
        let threads = (0..<n).filter { $0 != state.commons }
        let threadMass = threads.reduce(0.0) { $0 + state.memory[$1] }
        let k = Double(threads.count)
        var memory = state.memory
        let newcomer: Double
        if k > 0 {
            newcomer = threadMass / (k + 1)
            for t in threads { memory[t] *= k / (k + 1) }
        } else if let c = state.commons {
            // Only the commons so far: the newcomer takes what a Thread would start with.
            newcomer = min(max(1 - 0.9, 0), memory[c])
            memory[c] -= newcomer
        } else {
            newcomer = 1
        }
        memory.append(newcomer)
        state.memory = memory
        state.credibility.append(0)
        state.predicted.append(0)
    }

    /// A strand leaves: its memory goes pro-rata to the remaining Threads (to the commons when
    /// none remain). Indices above it shift down.
    public static func detach(_ state: inout GateState, at index: Int) {
        guard state.memory.indices.contains(index), index != state.commons else { return }
        let leaving = state.memory[index]
        state.memory.remove(at: index)
        state.credibility.remove(at: index)
        state.predicted.remove(at: index)
        if let c = state.commons, c > index { state.commons = c - 1 }
        let threads = state.memory.indices.filter { $0 != state.commons }
        let threadMass = threads.reduce(0.0) { $0 + state.memory[$1] }
        if threadMass > 0 {
            for t in threads { state.memory[t] += leaving * state.memory[t] / threadMass }
        } else if let c = state.commons {
            state.memory[c] += leaving
        } else if !threads.isEmpty {
            for t in threads { state.memory[t] += leaving / Double(threads.count) }
        }
    }
}

extension GateState {
    /// A state holding only a memory (for recomputing views from a logged memory).
    init(memoryOnly memory: [Double], commons: Int?) {
        self.memory = memory
        credibility = [Double](repeating: 0, count: memory.count)
        seen = 0
        predicted = [Int](repeating: 0, count: memory.count)
        self.commons = commons
    }
}
