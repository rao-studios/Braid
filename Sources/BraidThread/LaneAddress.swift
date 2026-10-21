//
//  LaneAddress.swift
//  BraidThread
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The address of a Braid Thread inside an Ambient Intelligence Index: `<aii>/<lane>`,
//        where `<aii>` names the machine's home (`home`) or a demo AII created by `braid aii
//        create`, and `<lane>` is an app registered on it (ambient, craft and veil from the start,
//        or any app that joined), whose secret puts the caller in that app's lane. A LaneCorpus
//        says what a Thread reads there: Braid's own corpus, or the app's records.
//  PIN:  A lane is the unit: one Braid Thread = one AII lane. The stack identity (`aii`) reads
//        every lane but may write none, so it is never a lane address.
//

import AII
import Foundation

public struct LaneAddress: Hashable, Sendable, Codable, CustomStringConvertible {
    public static let machine = "home"

    public var aii: String
    public var lane: AIIApp

    public init(aii: String = LaneAddress.machine, lane: AIIApp) {
        self.aii = aii
        self.lane = lane
    }

    /// `home/ambient`, `demo-a/craft`. A bare lane name means the machine's AII.
    public init?(parsing text: String) {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        switch parts.count {
        case 1:
            guard let lane = AIIApp(rawValue: parts[0]) else { return nil }
            self.init(lane: lane)
        case 2:
            guard !parts[0].isEmpty, let lane = AIIApp(rawValue: parts[1]) else { return nil }
            self.init(aii: parts[0], lane: lane)
        default:
            return nil
        }
    }

    public var description: String { "\(aii)/\(lane.rawValue)" }
    public var isMachine: Bool { aii == Self.machine }
}

/// What a Thread reads from a lane: Braid's own corpus deposited there (owner `braid`, group
/// `braid-<lane>`), or the records the lane's app filed (every group of the app's owner). A Thread
/// records it as its lane: `home/veil` for Braid's corpus, `app:home/notes` for an app's records.
public enum LaneCorpus: Hashable, Sendable, CustomStringConvertible {
    case braid(LaneAddress)
    case app(LaneAddress)

    public static let appPrefix = "app:"

    /// A Thread's recorded lane: `home/veil`, or `app:home/notes`.
    public init?(recorded text: String) {
        if text.hasPrefix(Self.appPrefix) {
            guard let address = LaneAddress(parsing: String(text.dropFirst(Self.appPrefix.count))) else { return nil }
            self = .app(address)
        } else {
            guard let address = LaneAddress(parsing: text) else { return nil }
            self = .braid(address)
        }
    }

    public var address: LaneAddress {
        switch self {
        case .braid(let address), .app(let address): return address
        }
    }

    public var description: String {
        switch self {
        case .braid(let address): return address.description
        case .app(let address): return Self.appPrefix + address.description
        }
    }
}
