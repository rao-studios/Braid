//
//  TokenizerFixtureTests.swift
//  BraidKitTests
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation
import Testing
@testable import BraidKit

private let packDirectory: URL? = {
    guard let area = WorkArea.resolve() else { return nil }
    let urls = (try? FileManager.default.contentsOfDirectory(at: area.packs, includingPropertiesForKeys: nil)) ?? []
    return urls.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent(Pack.infoFile).path) }
}()

@Suite("The pack's tokenizer against Hugging Face's", .enabled(if: packDirectory != nil))
struct TokenizerFixtureTests {
    @Test func matchesTheFixture() throws {
        let fixture = Bundle.module.url(forResource: "neox-tokens", withExtension: "json", subdirectory: "Fixtures")!
        let recorded = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as! [String: Any]
        let tokenizer = try BraidTokenizer(folder: packDirectory!.appendingPathComponent(Pack.tokenizerDirectory))
        #expect(tokenizer.vocabSize == recorded["<vocab>"] as! Int)
        #expect(tokenizer.eos == 0)
        for (text, ids) in recorded where text != "<vocab>" {
            let expected = (ids as! [Int]).map(Int32.init)
            #expect(tokenizer.encode(text) == expected, "\(text.debugDescription)")
            #expect(tokenizer.decode(expected) == text, "decode \(text.debugDescription)")
        }
        #expect(tokenizer.paragraphBreak == tokenizer.encode("\n\n"))
        let offsets = tokenizer.byteOffsets(tokenizer.encode("Hello world."))
        #expect(offsets.first == 0 && offsets.last == "Hello world.".utf8.count)
    }
}
