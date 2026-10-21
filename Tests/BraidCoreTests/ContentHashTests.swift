//
//  ContentHashTests.swift
//  BraidCoreTests
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation
import Testing
@testable import BraidCore

@Suite("Content hashing")
struct ContentHashTests {
    @Test func sha256() {
        #expect(ContentHash.sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(ContentHash.sha256Hex(parts: [Data("ab".utf8), Data("c".utf8)]) == ContentHash.sha256Hex("abc"))
    }

    @Test func corpusHashIsOrderIndependent() {
        let a = ContentHash.CorpusEntry(documentID: "d1", partitionIndex: 0, textSHA256: "x")
        let b = ContentHash.CorpusEntry(documentID: "d1", partitionIndex: 1, textSHA256: "y")
        let c = ContentHash.CorpusEntry(documentID: "d0", partitionIndex: 3, textSHA256: "z")
        #expect(ContentHash.corpusHash([a, b, c]) == ContentHash.corpusHash([c, b, a]))
        #expect(ContentHash.corpusHash([a, b, c]) == ContentHash.sha256Hex("d0\t3\tz\nd1\t0\tx\nd1\t1\ty\n"))
    }

    @Test func canonicalAndIDs() {
        #expect(ContentHash.canonical("a \r\nb\t\n\n") == "a\nb")
        let id = DocumentID.make(slug: "ambient", canonicalText: "hello")
        #expect(id.hasPrefix("braid-ambient-") && id.count == "braid-ambient-".count + 24)
        #expect(DocumentID.isValid(id))
        #expect(DocumentID.isValid("raolm-craft-0123456789abcdef01234567"))
        #expect(!DocumentID.isValid("braid/x"))
        #expect(DocumentID.isValidHandle("braid-ambient") && !DocumentID.isValidHandle("Braid"))
        #expect(DocumentID.partitionURL(aii: "home", lane: "ambient", documentID: id, index: 2) == "braid://home/ambient/\(id)/2")
    }

    @Test func standardizedJSON() throws {
        let text = #"{"a": [0.0, Infinity], "b": -Infinity, "c": NaN, "s": "Infinity stays \"NaN\" here"}"#
        let fixed = JSONCoding.standardized(text)
        #expect(fixed == #"{"a": [0.0, "inf"], "b": "-inf", "c": "nan", "s": "Infinity stays \"NaN\" here"}"#)
        struct Shape: Decodable { var a: [Float]; var b: Float; var c: Float; var s: String }
        let decoded = try JSONCoding.decoder().decode(Shape.self, from: Data(fixed.utf8))
        #expect(decoded.a[1] == .infinity && decoded.b == -.infinity && decoded.c.isNaN)
    }
}
