//
//  GateTests.swift
//  BraidCoreTests
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation
import Testing
@testable import BraidCore

@Suite("The gate")
struct GateTests {
    func close(_ a: [Double], _ b: [Double], _ tolerance: Double = 1e-9) -> Bool { a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= tolerance } }

    @Test("absolute evidence: a token every strand predicts moves nothing; one strand's token alone leans to about 0.70")
    func absolute() {
        var settings = GateSettings()
        settings.evidence = .absolute
        var state = GateState(strands: 2)
        Gate.observe(&state, likelihoods: [0.9, 0.9], settings: settings)
        #expect(close(state.memory, [0.5, 0.5]))
        // From a fresh state: credibility 0.3 after the one token: u ∝ [0.5, 0.5·0.1^0.3]; variable
        // share hands a tenth of the loser's weight across.
        var fresh = GateState(strands: 2)
        Gate.observe(&fresh, likelihoods: [0.95, 0.001], settings: settings)
        let u1: Double = 0.5 * pow(0.1, 0.3)
        let u0: Double = 0.5 / (0.5 + u1)
        let u1n: Double = u1 / (0.5 + u1)
        let give: Double = u1n * (1 - pow(0.9, 1.0))
        let expected: [Double] = [u0 + give, u1n - give]
        #expect(close(fresh.memory, expected, 1e-9))
        #expect(fresh.memory[0] > 0.69 && fresh.memory[0] < 0.71)
        #expect(abs(fresh.memory.reduce(0, +) - 1) < 1e-12)
        // After a template token the credibility is already 0.3 each, so the same token moves more.
        Gate.observe(&state, likelihoods: [0.95, 0.001], settings: settings)
        #expect(state.memory[0] > fresh.memory[0] && abs(state.memory.reduce(0, +) - 1) < 1e-12)
    }

    @Test("bounded: at full credibility one token moves the memory by at most ceiling/floor, 10 to 1")
    func bounded() {
        var settings = GateSettings()
        settings.evidence = .absolute
        settings.credibilityRate = 1  // full credibility at once
        settings.shareRate = 0        // no redistribution, to read the bound alone
        var state = GateState(strands: 2)
        Gate.observe(&state, likelihoods: [1.0, 1e-9], settings: settings)
        let bound: [Double] = [10.0 / 11, 1.0 / 11]
        #expect(close(state.memory, bound, 1e-9))
        var again = GateState(strands: 2)
        Gate.observe(&again, likelihoods: [0.5, 0.05], settings: settings)
        #expect(close(again.memory, state.memory, 1e-9))
    }

    @Test("lift evidence: the memory starts on the commons; a ratio of a million moves it exactly as a ratio of ten")
    func lift() {
        let settings = GateSettings()
        var a = GateState(strands: 3, commons: 0, prior: 0.9)
        #expect(close(a.memory, [0.9, 0.05, 0.05]))
        Gate.observe(&a, likelihoods: [1e-6, 1.0, 1e-6], settings: settings)
        var b = GateState(strands: 3, commons: 0, prior: 0.9)
        Gate.observe(&b, likelihoods: [0.1, 1.0, 0.1], settings: settings)
        #expect(close(a.memory, b.memory, 1e-12))
        #expect(a.memory[1] > a.memory[2] && abs(a.memory.reduce(0, +) - 1) < 1e-12)
        // A strand that knows no more than the commons moves nothing.
        var c = GateState(strands: 3, commons: 0, prior: 0.9)
        Gate.observe(&c, likelihoods: [0.3, 0.3, 0.3], settings: settings)
        #expect(close(c.memory, [0.9, 0.05, 0.05], 1e-12))
    }

    @Test("the module's evidence enters before the one clamp: it cannot push a token past 10 to 1")
    func moduleClamped() {
        var settings = GateSettings()
        settings.moduleGain = 0.5
        var plain = GateState(strands: 2, commons: 0)
        Gate.observe(&plain, likelihoods: [0.1, 1.0], settings: settings)
        var boosted = GateState(strands: 2, commons: 0)
        Gate.observe(&boosted, likelihoods: [0.1, 1.0], module: [0, 1], settings: settings)
        #expect(close(plain.memory, boosted.memory, 1e-12))
        // With no lift of its own, e = 1 at κ 0.5 is a ratio of √10.
        var module = GateState(strands: 2, commons: 0)
        let ratios = Gate.observe(&module, likelihoods: [0.3, 0.3], module: [0, 1], settings: settings)
        #expect(abs(ratios[1] - sqrt(10)) < 1e-9)
    }

    @Test("open: the floor, the largest always, the commons always, everyone when every gate is 0")
    func opening() {
        #expect(Gate.open([0.97, 0.03], commons: nil, floor: 0.05) == [true, false])
        #expect(Gate.open([0.02, 0.01], commons: nil, floor: 0.05) == [true, false])
        #expect(Gate.open([0, 0], commons: nil, floor: 0.05) == [true, true])
        #expect(Gate.open([0.5, 0, 0.5], commons: nil, floor: 0.05) == [true, false, true])
        #expect(Gate.open([0.97, 0.03], commons: 1, floor: 0.05) == [true, true])
        #expect(Gate.floor(0.05, strands: 2) == 0.05 && abs(Gate.floor(0.05, strands: 4) - 0.025) < 1e-12)
        #expect(close(Gate.renormalised([0.6, 0.3, 0.1], open: [true, false, true]), [6.0 / 7, 0, 1.0 / 7]))
        #expect(close(Gate.renormalised([0, 0], open: [true, true]), [0.5, 0.5]))
    }

    @Test("attach takes 1/(k+1) of the Threads' mass pro rata; detach returns it; the sum stays 1")
    func membership() {
        var state = GateState(strands: 3, commons: 0, prior: 0.9)
        state.memory = [0.4, 0.45, 0.15]
        Gate.attach(&state)
        #expect(state.count == 4)
        let expected: [Double] = [0.4, 0.45 * 2 / 3, 0.15 * 2 / 3, 0.6 / 3]
        #expect(close(state.memory, expected, 1e-12))
        Gate.detach(&state, at: 3)
        #expect(close(state.memory, [0.4, 0.45, 0.15], 1e-12))
        Gate.detach(&state, at: 1)
        #expect(close(state.memory, [0.4, 0.6], 1e-12))
        Gate.detach(&state, at: 1)
        #expect(close(state.memory, [1.0], 1e-12) && state.commons == 0)
        var noCommons = GateState(strands: 2)
        Gate.detach(&noCommons, at: 0)
        #expect(close(noCommons.memory, [1.0]))
    }

    @Test("the shadow β4 gate multiplies the memory by exp(β·(trace − mean)) and is never the live gate")
    func shadow() {
        let state = GateState(strands: 3, commons: 0, prior: 0.9)
        let shadow = Gate.shadowWeights(state, traces: [0, 1, 0], beta: 4)
        let mean: Double = 1.0 / 3
        let low: Double = exp(4 * (0 - mean))
        let high: Double = exp(4 * (1 - mean))
        let raw: [Double] = [0.9 * low, 0.05 * high, 0.05 * low]
        let total: Double = raw.reduce(0, +)
        let expected: [Double] = raw.map { $0 / total }
        #expect(close(shadow, expected, 1e-12))
        #expect(close(Gate.weights(state), [0.9, 0.05, 0.05]))
        #expect(close(Gate.shadowWeights(state, traces: [0, 0, 0], beta: 4), [0.9, 0.05, 0.05], 1e-12))
    }

    @Test func fingerprint() {
        var a = GateSettings()
        let b = GateSettings()
        #expect(a.fingerprint == b.fingerprint && a.fingerprint.count == 8)
        a.moduleGain = 0.5
        #expect(a.fingerprint != b.fingerprint)
    }
}
