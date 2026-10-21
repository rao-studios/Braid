//
//  ConfigTests.swift
//  BraidCoreTests
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation
import Testing
@testable import BraidCore

@Suite("braid.toml")
struct ConfigTests {
    @Test func roundTrip() throws {
        var config = BraidConfig(pack: BraidConfig.Pack(name: "mamba2-130m", sha256: "abc", vocabularySHA256: "v", tokenizerSHA256: "t", hiddenSize: 768, layers: 24, heads: 24,
                                                        headDim: 64, stateSize: 128, convKernel: 4, vocabRows: 50288, vocabTokens: 50277, keyScheme: "residual:12"))
        config.attach = ["a", "b c"]
        config.gate.moduleGain = 0.5
        let text = config.render()
        #expect(text.contains("[pack]") && text.contains("attach = [\"a\", \"b c\"]") && text.contains("module_gain = 0.5"))
        let parsed = try BraidConfig.parse(text)
        #expect(parsed == config)
        #expect(parsed.sha256 == config.sha256)
    }

    @Test func subset() throws {
        let document = try TOMLSubset.parse("""
            # a comment
            version = 1
            [table]
            s = "a \\"quoted\\" string # not a comment"
            i = 42
            f = 2.5
            b = true
            arr = ["x", "y, z"]
            """)
        #expect(TOMLSubset.value(document, "", "version")?.integer == 1)
        #expect(TOMLSubset.value(document, "table", "s")?.string == "a \"quoted\" string # not a comment")
        #expect(TOMLSubset.value(document, "table", "arr")?.strings == ["x", "y, z"])
        #expect(TOMLSubset.value(document, "table", "f")?.float == 2.5 && TOMLSubset.value(document, "table", "b")?.bool == true)
        #expect(throws: TOMLSubset.Failure.self) { try TOMLSubset.parse("[[x]]") }
        #expect(throws: TOMLSubset.Failure.self) { try TOMLSubset.parse("k = {a = 1}") }
        #expect(throws: BraidFailure.self) { try BraidConfig.parse("[pack]\nname = \"x\"") }
    }
}
