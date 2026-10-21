//
//  PackageLayeringTests.swift
//  BraidCoreTests
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The manifest to the package's rules, as text over Package.swift and Sources/: two
//        products; MLXLLM and MLXLMCommon linked by test targets only (Braid holds no KV cache
//        and no attention); no type named like a module; `Thread.` never written qualified
//        (Foundation's Thread shadows AII's module); no KV-cache or attention primitive anywhere
//        under Sources/.
//

import Foundation
import Testing

private let repoRoot: URL = {
    var url = URL(fileURLWithPath: #filePath)
    while url.lastPathComponent != "Tests" { url.deleteLastPathComponent() }
    return url.deletingLastPathComponent()
}()

private func text(_ relative: String) throws -> String {
    try String(contentsOf: repoRoot.appendingPathComponent(relative), encoding: .utf8)
}

private func swiftFiles(under relative: String) -> [URL] {
    let root = repoRoot.appendingPathComponent(relative)
    guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
    return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
}

@Suite("Package layering")
struct PackageLayeringTests {
    @Test("two products: the BraidKit library and the braid executable")
    func products() throws {
        let manifest = try text("Package.swift")
        #expect(manifest.contains(".library(name: \"BraidKit\""))
        #expect(manifest.contains(".executable(name: \"braid\""))
        #expect(manifest.components(separatedBy: ".library(name:").count == 2)
        #expect(manifest.components(separatedBy: ".executable(name:").count == 2)
    }

    @Test("MLXLLM and MLXLMCommon are linked by test targets only")
    func oracleStaysInTests() throws {
        let manifest = try text("Package.swift")
        let firstTest = manifest.range(of: ".testTarget(")!.lowerBound
        let sources = manifest[..<firstTest]
        #expect(!sources.contains("\"MLXLLM\""))
        #expect(!sources.contains("\"MLXLMCommon\""))
        for file in swiftFiles(under: "Sources") {
            let body = try String(contentsOf: file, encoding: .utf8)
            #expect(!body.contains("import MLXLLM"), "\(file.lastPathComponent) imports MLXLLM")
            #expect(!body.contains("import MLXLMCommon"), "\(file.lastPathComponent) imports MLXLMCommon")
        }
    }

    @Test("no KV cache and no attention primitive under Sources/")
    func kvFree() throws {
        for file in swiftFiles(under: "Sources") {
            let body = try String(contentsOf: file, encoding: .utf8)
            #expect(!body.contains("KVCache"), "\(file.lastPathComponent) names a KV cache")
            #expect(!body.contains("scaledDotProductAttention"), "\(file.lastPathComponent) uses attention")
            #expect(!body.contains("MultiHeadAttention"), "\(file.lastPathComponent) uses attention")
        }
    }

    @Test("no type is named like a module, and Thread is never written qualified")
    func names() throws {
        let modules = ["BraidKit", "BraidCore", "BraidThread", "BraidTerminal", "BraidStudio", "BraidCLI", "AII", "Seam", "Thread"]
        let declaration = try NSRegularExpression(pattern: "\\b(struct|class|enum|actor|protocol|typealias)\\s+(\\w+)")
        let qualified = try NSRegularExpression(pattern: "(?<![\\w.])Thread\\.[A-Z]")
        for file in swiftFiles(under: "Sources") {
            let body = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(body.startIndex..., in: body)
            for match in declaration.matches(in: body, range: range) {
                let name = String(body[Range(match.range(at: 2), in: body)!])
                #expect(!modules.contains(name), "\(file.lastPathComponent) declares a type named \(name)")
            }
            #expect(qualified.firstMatch(in: body, range: range) == nil, "\(file.lastPathComponent) writes Thread.X")
        }
    }
}
