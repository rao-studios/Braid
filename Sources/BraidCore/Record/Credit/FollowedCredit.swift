//
//  FollowedCredit.swift
//  BraidCore
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The owner's rule for a fact several Threads hold: "the trajectory is the decision maker
//        if it's the same fact". Per generated sentence, the Thread whose chains advanced on the
//        most tokens (its trace expected the token that was written), by a margin of two and on
//        more than half the sentence's content tokens, takes the Threads' credit of every content
//        token two or more Threads hold. Threads within the margin split that credit evenly; where
//        nobody decides, nothing moves. Weight never decides. Only credit moves.
//  PIN:  Threads are named, not indexed: an attach or detach inside a sentence moves indices, so
//        each step is read through its own slots and the decision counts by name.
//

import Foundation

public struct FollowDecision: Codable, Sendable, Equatable {
    public var window: TokenRange
    /// The Thread whose chains advanced on the most tokens, by the margin, if any.
    public var followed: String?
    /// The Threads within the margin of the best when nobody decides.
    public var tied: [String]
    public var documentID: String?
    /// Per Thread, the tokens its chain expected and got.
    public var advances: [String: Int]
}

public enum FollowedCredit {
    public static let margin = 2

    /// Re-assigns the Threads' credit sentence by sentence. `credits` is `Credit.assign`'s output
    /// for the same steps; `slots[i]` names step i's strands and places their rows in `partitions`.
    @discardableResult
    public static func apply(_ credits: inout [CreditRow?], steps: [Step], slots: [[StrandSlot]], partitions: [Int: PartitionRef],
                             margin: Int = margin) -> [FollowDecision] {
        var decisions: [FollowDecision] = []
        for window in sentences(steps) {
            let decision = decide(steps, window: window, slots: slots, partitions: partitions, margin: margin)
            decisions.append(decision)
            for i in window.start..<window.end {
                guard i < slots.count, var row = credits[i], row.role == .content, let threads = steps[i].threads else { continue }
                let here = slots[i]
                let holders = threads.indices.filter { $0 < here.count && !here[$0].commons && row.credit[$0] > 0 }
                guard holders.count >= 2 else { continue }
                let pooled = holders.reduce(Float(0)) { $0 + row.credit[$1] }
                if let followed = decision.followed, let follower = here.firstIndex(where: { $0.name == followed }), threads.indices.contains(follower) {
                    for h in holders { row.credit[h] = 0 }
                    row.credit[follower] = pooled
                    row.followed = follower
                } else if decision.tied.count >= 2 {
                    let sharers = holders.filter { decision.tied.contains(here[$0].name) }
                    guard sharers.count >= 2 else { continue }
                    let among = sharers.reduce(Float(0)) { $0 + row.credit[$1] }
                    for h in sharers { row.credit[h] = among / Float(sharers.count) }
                } else {
                    continue
                }
                credits[i] = row
            }
        }
        return decisions
    }

    /// The generated steps split into sentences, as `AnswerStop` reads them.
    static func sentences(_ steps: [Step]) -> [TokenRange] {
        var windows: [TokenRange] = []
        var start: Int?
        var text = ""
        for i in steps.indices {
            guard !steps[i].isPrompt else { continue }
            if let s = start, AnswerStop.sentenceEnded(previous: text, next: steps[i].text) {
                windows.append(TokenRange(start: s, end: i))
                start = nil
                text = ""
            }
            if start == nil { start = i }
            text += steps[i].text
        }
        if let s = start { windows.append(TokenRange(start: s, end: steps.count)) }
        return windows
    }

    static func decide(_ steps: [Step], window: TokenRange, slots: [[StrandSlot]], partitions: [Int: PartitionRef], margin: Int) -> FollowDecision {
        var advances: [String: Int] = [:]
        var documents: [String: [String: Int]] = [:]
        let roles = TokenRoles.roles(steps.map(\.text))
        for i in window.start..<window.end {
            guard i < slots.count, let threads = steps[i].threads else { continue }
            let here = slots[i]
            for (t, record) in threads.enumerated() where t < here.count && !here[t].commons {
                guard let trace = record.trace, trace.next == steps[i].token else { continue }
                let name = here[t].name
                advances[name, default: 0] += 1
                if let row = trace.row, let partition = partitions[here[t].rowOffset + Int(row)] {
                    documents[name, default: [:]][partition.documentID, default: 0] += 1
                }
            }
        }
        let content = (window.start..<window.end).filter { roles[$0] == .content }.count
        let ranked = advances.filter { $0.value > 0 }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        var followed: String?
        var tied: [String] = []
        if let best = ranked.first, best.value * 2 > content {
            if (ranked.dropFirst().first?.value ?? 0) + margin <= best.value {
                followed = best.key
            } else {
                tied = ranked.filter { $0.value + margin > best.value }.map(\.key).sorted()
            }
        }
        // The document the followed chains ran through most (ties: the smaller id).
        let document = followed.flatMap { documents[$0]?.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key }
        return FollowDecision(window: window, followed: followed, tied: tied, documentID: document, advances: advances)
    }
}
