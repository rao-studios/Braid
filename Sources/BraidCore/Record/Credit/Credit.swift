//
//  Credit.swift
//  BraidCore
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The credit view over a generation: per position, the token's role, its bits and each
//        strand's credit. A form token's credit is the commons'; a content token's is each
//        strand's share.
//  PIN:  A derived view over the session log, never stored per token.
//

import Foundation

/// Per position: the token's role, its bits and each strand's credit.
public struct CreditRow: Sendable, Equatable {
    public var role: TokenRole
    /// −log₂ p_commons(y); nil without a commons.
    public var bits: Float?
    public var credit: [Float]
    /// The strand whose document the sentence followed, when credit moved there.
    public var followed: Int?
}

public enum Credit {
    /// The blend over a generation's steps: a form token is wholly the commons', a content token
    /// each strand's as it supplied it (the commons keeping what it filled in). `texts` are the
    /// texts of every step in order, so the word a token belongs to is whole.
    public static func assign(_ steps: [Step], commons: Int?) -> [CreditRow?] { assign(steps) { _ in commons } }

    /// The same, with the commons wherever each step's slots put it.
    public static func assign(_ steps: [Step], slots: [[StrandSlot]]) -> [CreditRow?] {
        assign(steps) { i in i < slots.count ? StrandSlots.commons(slots[i]) : nil }
    }

    static func assign(_ steps: [Step], commonsAt: (Int) -> Int?) -> [CreditRow?] {
        let roles = TokenRoles.roles(steps.map(\.text))
        return steps.indices.map { i in
            guard let threads = steps[i].threads else { return nil }
            let commons = commonsAt(i)
            let role = roles[i]
            let base = commons.flatMap { threads.indices.contains($0) ? threads[$0].plm : nil }
            let bits = base.map { Float(-log2(Double(max($0, 1e-30)))) }
            let credit = threads.indices.map { t -> Float in role == .form ? (t == commons ? 1 : 0) : threads[t].share }
            return CreditRow(role: role, bits: bits, credit: credit, followed: nil)
        }
    }
}
