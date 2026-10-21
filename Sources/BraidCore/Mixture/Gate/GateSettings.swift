//
//  GateSettings.swift
//  BraidCore
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The gate's constants, carried from RaoLM's braided gate: evidence bounded between the
//        floor and the ceiling (one token moves the memory by at most ceiling/floor = 10 to 1),
//        credibility that fades at 0.3 a token, a tenth given up on a token predicted worse than
//        the commons, the memory starting 0.9 on the commons, an open floor of 0.05 for two
//        strands that shrinks as strands are added. `moduleGain` κ is the trajectory module's
//        entry (0 until step 7); `shadowBeta` is the β of the counterfactual trace gate, logged
//        and never applied.
//  PIN:  The fingerprint names the settings in every session header and generation id, so a log
//        says which gate made it.
//

import Foundation

public struct GateSettings: Codable, Sendable, Equatable {
    public enum Evidence: String, Codable, Sendable {
        /// A strand's evidence for a token is its probability over the commons' (the default).
        case lift
        /// Without a commons: the probability itself, clamped (RaoLM's gate before the commons).
        case absolute
    }

    public var evidenceFloor: Double = 0.05
    public var evidenceCeiling: Double = 0.5
    public var shareRate: Double = 0.1
    public var credibilityRate: Double = 0.3
    public var commonsPrior: Double = 0.9
    public var openFloor: Double = 0.05
    public var moduleGain: Double = 0
    public var shadowBeta: Double = 4
    public var evidence: Evidence = .lift

    public init() {}

    /// ceiling/floor: how far one token can move the memory.
    public var reach: Double { max(evidenceCeiling / max(evidenceFloor, 1e-6), 1 + 1e-6) }

    /// The first 8 hex of the SHA-256 of the sorted-key JSON: the settings' name.
    public var fingerprint: String {
        let data = (try? JSONCoding.lineEncoder().encode(self)) ?? Data()
        return String(ContentHash.sha256Hex(data).prefix(8))
    }
}
