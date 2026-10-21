//
//  StrandSlot.swift
//  BraidCore
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Who strand index t was at one step. Attach and detach lines move strands' indices in the
//        middle of a generation, so every per-step view — citations and spans, credit, the
//        followed-credit decision, royalties — reads a step's records through that step's own slots
//        and aggregates across steps by the Thread's name.
//

import Foundation

public struct StrandSlot: Sendable, Equatable, Hashable {
    public var name: String
    /// Where this strand's rows begin in the braid's global partition table, and how many it has (a
    /// re-attached Thread gets new rows).
    public var rowOffset: Int
    public var rowCount: Int
    public var tau: Double
    public var commons: Bool

    public init(name: String, rowOffset: Int, rowCount: Int = 0, tau: Double, commons: Bool) {
        self.name = name
        self.rowOffset = rowOffset
        self.rowCount = rowCount
        self.tau = tau
        self.commons = commons
    }

    public init(_ thread: SessionThread) {
        self.init(name: thread.name, rowOffset: thread.rowOffset, rowCount: thread.rowCount, tau: Double(thread.tau), commons: thread.commons)
    }

    /// Whether a global row is one of this strand's.
    public func holds(row: Int) -> Bool { !commons && row >= rowOffset && row < rowOffset + rowCount }
}

public enum StrandSlots {
    /// Slots for callers that know only offsets and τs: named by index ("0", "1", …).
    public static func indexed(rowOffsets: [Int], taus: [Double], commons: Int? = nil) -> [StrandSlot] {
        rowOffsets.indices.map { t in StrandSlot(name: "\(t)", rowOffset: rowOffsets[t], tau: t < taus.count ? taus[t] : 0.05, commons: t == commons) }
    }

    /// The commons' index among one step's slots.
    public static func commons(_ slots: [StrandSlot]) -> Int? { slots.firstIndex(where: \.commons) }
}
