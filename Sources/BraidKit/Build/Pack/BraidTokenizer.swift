//
//  BraidTokenizer.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The pack's tokenizer, loaded from its folder with Frigate's tokenizer stack. The GPT-NeoX
//        class is not in Frigate's registry, so the loader runs non-strict and falls back to the
//        byte-level BPE model, which is what the files describe. Checked at import: eos is 0, no
//        special tokens are added, encode/decode round-trips, and the paragraph break is recorded
//        from the tokenizer rather than hardcoded.
//

import BraidCore
import Foundation
import Tokenizers

public final class BraidTokenizer: Tokenizing, @unchecked Sendable {
    public let folder: URL
    public let sha256: String
    public let eos: Int32
    public let vocabSize: Int
    public let paragraphBreak: [Int32]
    private let tokenizer: any Tokenizer
    private var textCache: [Int32: String] = [:]
    private let lock = NSLock()

    public init(folder: URL) throws {
        self.folder = folder
        let file = folder.appendingPathComponent("tokenizer.json")
        guard FileManager.default.fileExists(atPath: file.path) else { throw BraidFailure.missing("no tokenizer.json in \(folder.path)") }
        sha256 = try ContentHash.sha256Hex(fileAt: file)
        let loaded = try Blocking.run { try await AutoTokenizer.from(modelFolder: folder, strict: false) }
        tokenizer = loaded
        guard let eosID = loaded.eosTokenId else { throw BraidFailure.data("the tokenizer declares no eos token") }
        eos = Int32(eosID)
        // The vocabulary size: count ids that decode to a token (the embedding may hold padding rows past it).
        let data = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        let model = data?["model"] as? [String: Any]
        let vocab = model?["vocab"] as? [String: Any]
        let added = (data?["added_tokens"] as? [[String: Any]])?.compactMap { $0["id"] as? Int } ?? []
        vocabSize = max(vocab?.count ?? 0, (added.max() ?? -1) + 1)
        paragraphBreak = loaded.encode(text: "\n\n", addSpecialTokens: false).map(Int32.init)
        guard loaded.encode(text: "a", addSpecialTokens: true) == loaded.encode(text: "a", addSpecialTokens: false) else {
            throw BraidFailure.data("the tokenizer adds special tokens on encode; Braid's streams carry their own eos")
        }
    }

    public func encode(_ text: String) -> [Int32] { tokenizer.encode(text: text, addSpecialTokens: false).map(Int32.init) }
    public func decode(_ tokens: [Int32]) -> String { tokenizer.decode(tokens: tokens.map(Int.init), skipSpecialTokens: false) }

    public func text(_ token: Int32) -> String {
        lock.lock()
        if let cached = textCache[token] { lock.unlock(); return cached }
        lock.unlock()
        let decoded = tokenizer.decode(tokens: [Int(token)], skipSpecialTokens: false)
        lock.lock()
        textCache[token] = decoded
        lock.unlock()
        return decoded
    }

    /// For each token, the UTF-8 byte offset where it begins in the decoded text (plus the end).
    public func byteOffsets(_ tokens: [Int32]) -> [Int] {
        var offsets: [Int] = []
        var consumed = 0
        offsets.reserveCapacity(tokens.count + 1)
        for i in 0...tokens.count {
            offsets.append(consumed)
            if i < tokens.count { consumed = decode(Array(tokens[0...i])).utf8.count }
        }
        return offsets
    }
}

/// Runs an async operation to completion from synchronous code (the CLI and the MLX thread).
public enum Blocking {
    public static func run<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task.detached {
            do { box.result = .success(try await body()) } catch { box.result = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try box.result!.get()
    }

    final class ResultBox<T>: @unchecked Sendable {
        var result: Result<T, Error>?
    }
}
