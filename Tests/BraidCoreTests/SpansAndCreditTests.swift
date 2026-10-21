//
//  SpansAndCreditTests.swift
//  BraidCoreTests
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation
import Testing
@testable import BraidCore

@Suite("Spans and credit")
struct SpansAndCreditTests {
    static let partitions: [Int: PartitionRef] = [
        0: PartitionRef(row: 0, documentID: "d0", documentName: "D0", partitionIndex: 0, textSHA256: "s0", tokenCount: 8),
        1: PartitionRef(row: 1, documentID: "d1", documentName: "D1", partitionIndex: 0, textSHA256: "s1", tokenCount: 8),
    ]

    /// A step whose only strand retrieved `hits` and chose `token`.
    static func step(_ i: Int, token: Int32, hits: [Hit], prompt: Bool = false) -> Step {
        let record = ThreadRecord(memory: 1, weight: 1, open: true, plm: 0.5, pknn: 0.5, share: 1, hlm: 1, hknn: 0, shadowGate: 1, shadowShare: 1, hits: hits, trace: nil)
        return Step(index: i, token: token, text: FakeTokenizer().text(token), source: prompt ? .prompt : .gen, prob: 0.5, lambda: 0.5, threads: [record])
    }

    @Test("three consecutive matching hits make a verbatim span; a break position is never cited")
    func spans() {
        var steps: [Step] = []
        // Tokens 1,2,3 walk partition 0 at offsets 1,2,3 with rank-1 hits.
        for (i, token) in [Int32(1), 2, 3].enumerated() {
            steps.append(Self.step(i, token: token, hits: [Hit(entry: Int32(i), score: 0.95, value: token, row: 0, offset: Int32(i + 1), loss: 0.1)]))
        }
        // A fourth token whose hit lands past the partition's tokens (a break): uncited.
        steps.append(Self.step(3, token: 6, hits: [Hit(entry: 9, score: 0.95, value: 6, row: 0, offset: 8, loss: 0.1)]))
        let (annotations, spans) = Spans.annotate(steps: steps, rowOffsets: [0], taus: [0.05], partitions: Self.partitions)
        #expect(spans.count == 1)
        #expect(spans[0].tokenRange == TokenRange(start: 0, end: 3) && spans[0].kind == .verbatim && spans[0].source.documentID == "d0")
        #expect(annotations[0].spanIndex == 0 && annotations[2].spanIndex == 0 && annotations[3].spanIndex == nil)
        #expect(annotations[3].uncited)
        #expect(annotations[0].citations.first!.confidence > 0.8)
        #expect(CitationMath.confidence(score: 1, support: 1, sourceLoss: 0) == 1)
    }

    @Test("roles go by whole words; form belongs to the commons, content to the strands")
    func roles() {
        #expect(TokenRoles.roles([" the", " cat", " sat", "."]) == [.form, .content, .content, .form])
        #expect(TokenRoles.roles(["Kes", "trel", " Bridge", "'s"]) == [.content, .content, .content, .form])
        let record = { (share: Float) in ThreadRecord(memory: 0.5, weight: 0.5, open: true, plm: 0.25, pknn: 0, share: share, hlm: 1, hknn: 0, shadowGate: 0.5, shadowShare: share, hits: [], trace: nil) }
        let steps = [
            Step(index: 1, token: 1, text: " the", source: .gen, prob: 0.5, lambda: 0.5, threads: [record(0.5), record(0.5)]),
            Step(index: 2, token: 2, text: " cat", source: .gen, prob: 0.5, lambda: 0.5, threads: [record(0.2), record(0.8)]),
        ]
        let credits = Credit.assign(steps, commons: 0)
        #expect(credits[0]!.role == .form && credits[0]!.credit == [1, 0])
        #expect(credits[1]!.role == .content && credits[1]!.credit == [0.2, 0.8])
        #expect(abs(credits[1]!.bits! - 2) < 1e-6)
    }

    @Test("followed credit moves a shared fact to the strand whose chain advanced, by a margin of two")
    func followed() {
        func record(share: Float, next: Int32?) -> ThreadRecord {
            ThreadRecord(memory: 0.33, weight: 0.33, open: true, plm: 0.3, pknn: 0.3, share: share, hlm: 1, hknn: 0, shadowGate: 0.33, shadowShare: share, hits: [],
                         trace: next.map { TraceState(length: 30, trace: 0.1, entry: 0, row: 0, offset: 0, next: $0) })
        }
        let tokens: [Int32] = [2, 3, 4, 5]  // cat sat on mat — content words a sentence long
        let steps = tokens.enumerated().map { i, token in
            Step(index: i + 1, token: token, text: FakeTokenizer().text(token), source: .gen, prob: 0.5, lambda: 0.5,
                 threads: [record(share: 0.2, next: nil), record(share: 0.4, next: token), record(share: 0.4, next: i == 0 ? token : 99)])
        }
        let slots = [StrandSlot(name: "commons", rowOffset: 0, tau: 0.05, commons: true), StrandSlot(name: "a", rowOffset: 0, tau: 0.05, commons: false),
                     StrandSlot(name: "b", rowOffset: 0, tau: 0.05, commons: false)]
        var credits = Credit.assign(steps, commons: 0)
        let decisions = FollowedCredit.apply(&credits, steps: steps, slots: steps.map { _ in slots }, partitions: Self.partitions)
        #expect(decisions.count == 1 && decisions[0].followed == "a" && decisions[0].advances == ["a": 4, "b": 1])
        #expect(credits[1]!.credit == [0.2, 0.8, 0] && credits[1]!.followed == 1)
        // Within the margin: an even split.
        let tied = tokens.enumerated().map { i, token in
            Step(index: i + 1, token: token, text: FakeTokenizer().text(token), source: .gen, prob: 0.5, lambda: 0.5,
                 threads: [record(share: 0.2, next: nil), record(share: 0.5, next: token), record(share: 0.3, next: i < 3 ? token : 99)])
        }
        var tiedCredits = Credit.assign(tied, commons: 0)
        let tiedDecisions = FollowedCredit.apply(&tiedCredits, steps: tied, slots: tied.map { _ in slots }, partitions: Self.partitions)
        #expect(tiedDecisions[0].followed == nil && tiedDecisions[0].tied == ["a", "b"])
        #expect(tiedCredits[0]!.credit == [0.2, 0.4, 0.4])
    }

    @Test("after a detach shifts indices, each step's citations, spans, credit and royalties follow its own strands")
    func viewsFollowMembership() {
        // Strands: commons, a (rows 0–9), b (rows 10–19). After step 2, a detaches and b moves to index 1.
        let commons = StrandSlot(name: "commons", rowOffset: 0, tau: 0.05, commons: true)
        let a = StrandSlot(name: "a", rowOffset: 0, rowCount: 10, tau: 0.05, commons: false)
        let b = StrandSlot(name: "b", rowOffset: 10, rowCount: 10, tau: 0.05, commons: false)
        var partitions = Self.partitions
        partitions[10] = PartitionRef(row: 10, documentID: "doc-b", documentName: "B", partitionIndex: 0, textSHA256: "bb", tokenCount: 20)
        func hit(_ value: Int32, offset: Int32) -> Hit { Hit(entry: offset, score: 0.99, value: value, row: 0, offset: offset) }
        func record(share: Float, hits: [Hit]) -> ThreadRecord {
            ThreadRecord(memory: 0.5, weight: 0.5, open: true, plm: 0.1, pknn: 0.5, share: share, hlm: 1, hknn: 0, shadowGate: 0.5, shadowShare: share, hits: hits, trace: nil)
        }
        let tokens: [Int32] = [2, 3, 4, 5, 6]
        var steps: [Step] = []
        var slots: [[StrandSlot]] = []
        for (i, token) in tokens.enumerated() {
            let offset = Int32(i + 1)
            if i < 2 {
                steps.append(Step(index: i + 1, token: token, text: FakeTokenizer().text(token), source: .gen, prob: 0.5, lambda: 0.5,
                                  threads: [record(share: 0, hits: []), record(share: 0.1, hits: []), record(share: 0.9, hits: [hit(token, offset: offset)])]))
                slots.append([commons, a, b])
            } else {
                // b is now strand 1; its hits still sit on its own rows.
                steps.append(Step(index: i + 1, token: token, text: FakeTokenizer().text(token), source: .gen, prob: 0.5, lambda: 0.5,
                                  threads: [record(share: 0.05, hits: []), record(share: 0.95, hits: [hit(token, offset: offset)])]))
                slots.append([commons, b])
            }
        }
        let (annotations, spans) = Spans.annotate(steps: steps, slots: slots, partitions: partitions)
        #expect(annotations.allSatisfy { $0.citations.first?.row == 10 }, "every token cites b's row, before and after the shift")
        #expect(spans.count == 1 && spans[0].row == 10 && spans[0].tokens == tokens)
        var credits = Credit.assign(steps, slots: slots)
        _ = FollowedCredit.apply(&credits, steps: steps, slots: slots, partitions: partitions)
        let royalties = Royalties.view(steps: steps, credits: credits, slots: slots, partitions: partitions)
        #expect(royalties.strands.map(\.name) == ["commons", "a", "b"])
        let bLine = royalties.strands.first { $0.name == "b" }
        #expect(bLine?.led == 5, "b led every token, under both indices")
        #expect(abs((bLine?.share ?? 0) - (0.9 * 2 + 0.95 * 3)) < 1e-5)
        #expect(royalties.documents.map(\.name) == ["b"] && royalties.documents.first?.documentID == "doc-b")
        // Read with the generation's first strands at every step, b's later hits land on a's rows.
        let (_, wrong) = Spans.annotate(steps: steps, rowOffsets: [0, 0, 10], taus: [0.05, 0.05, 0.05], partitions: partitions)
        #expect(wrong.allSatisfy { $0.row != 10 || $0.tokens.count < tokens.count }, "the constant mapping misattributes the shifted steps")
    }

    @Test func answerStop() {
        #expect(AnswerStop.sentenceEnded(previous: "the mat.", next: " The"))
        #expect(AnswerStop.sentenceEnded(previous: "the mat.", next: "Its"))
        #expect(!AnswerStop.sentenceEnded(previous: "v2.", next: "1"))
        #expect(AnswerStop.sentenceEnded(previous: "x", next: "\n"))
    }
}
