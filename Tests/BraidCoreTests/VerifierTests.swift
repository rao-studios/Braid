//
//  VerifierTests.swift
//  BraidCoreTests
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The span checks of `braid verify` against their source: an unchanged source verifies every
//        span, an edited partition is stale, a removed document is missing, a tokenizer other than the
//        session's is refused; hits round-trip in both log forms.
//

import Foundation
import Testing
@testable import BraidCore

@Suite("Verify: spans against their source")
struct VerifierTests {
    struct Reader: PartitionReading {
        var texts: [String: String]
        func partitionText(documentID: String, partitionIndex: Int) throws -> String? { partitionIndex == 0 ? texts[documentID] : nil }
    }

    struct OtherTokenizer: Tokenizing {
        var eos: Int32 { 0 }
        var sha256: String { "another-tokenizer" }
        func encode(_ text: String) -> [Int32] { FakeTokenizer().encode(text) }
        func decode(_ tokens: [Int32]) -> String { FakeTokenizer().decode(tokens) }
        func text(_ token: Int32) -> String { FakeTokenizer().text(token) }
    }

    static let sources: [String: String] = [
        "doc-a-0": FakeTokenizer().decode(Fixtures.catDocument),
        "doc-b-0": FakeTokenizer().decode(Fixtures.dogDocument),
    ]

    /// The cat session of SessionTests: a's document walks the prompt, so the generation cites it verbatim.
    static func catSession() throws -> LoggedSession {
        let cluster = Fixtures.cluster()
        _ = try Fixtures.threeStrands(into: cluster)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("braid-verify-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try cluster.startLog(at: url)
        var params = GenerationParameters()
        params.maxTokens = 6
        _ = try cluster.generate(prompt: GenerationPrompt(text: " the cat sat on", tokens: [1, 2, 3, 4]), params: params)
        cluster.closeLog()
        return try SessionReader.read(url)
    }

    @Test("an unchanged source verifies every span; an edited partition is stale; a removed document is missing")
    func spanStatuses() throws {
        let session = try Self.catSession()
        let clean = Verifier.verify(session: session, name: "cat", layouts: { _ in nil }, reader: Reader(texts: Self.sources), tokenizer: FakeTokenizer())
        #expect(clean.status == .ok, "\(clean.issues.map(\.description)) \(clean.spans.map(\.status))")
        #expect(clean.spansVerified >= 1 && clean.spansFailed == 0)
        #expect(clean.spans.contains { $0.documentID == "doc-a-0" })

        var edited = Self.sources
        edited["doc-a-0"] = " the cat sat on the mat today."
        let stale = Verifier.verify(session: session, name: "cat", layouts: { _ in nil }, reader: Reader(texts: edited), tokenizer: FakeTokenizer())
        #expect(stale.status == .failed)
        #expect(stale.spans.filter { $0.documentID == "doc-a-0" }.allSatisfy { $0.status == .stale })

        var removed = Self.sources
        removed["doc-a-0"] = nil
        let missing = Verifier.verify(session: session, name: "cat", layouts: { _ in nil }, reader: Reader(texts: removed), tokenizer: FakeTokenizer())
        #expect(missing.status == .failed)
        #expect(missing.spans.filter { $0.documentID == "doc-a-0" }.allSatisfy { $0.status == .missing })
    }

    @Test("a tokenizer other than the session's is refused; spans are not checked against it")
    func otherTokenizerRefused() throws {
        let session = try Self.catSession()
        let report = Verifier.verify(session: session, name: "cat", layouts: { _ in nil }, reader: Reader(texts: Self.sources), tokenizer: OtherTokenizer())
        #expect(report.status == .failed)
        #expect(report.issues.contains { $0.check == "tokenizer" })
        #expect(report.spans.isEmpty)
    }

    @Test("hits are logged as compact arrays and the first logs' object form still reads")
    func hitForms() throws {
        let hit = Hit(entry: 12, score: 0.5, value: 7, row: 3, offset: 9, loss: 0.25)
        let encoded = String(decoding: try JSONCoding.lineEncoder().encode(hit), as: UTF8.self)
        #expect(encoded == "[12,0.5,7,3,9,0.25]")
        #expect(try JSONCoding.decoder().decode(Hit.self, from: Data(encoded.utf8)) == hit)
        let object = #"{"e":12,"l":0.25,"o":9,"r":3,"s":0.5,"v":7}"#
        #expect(try JSONCoding.decoder().decode(Hit.self, from: Data(object.utf8)) == hit)
    }
}
