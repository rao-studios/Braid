//
//  QuestionAdapter.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The question path's first step: the commons rewrites a natural question into the
//        corpus-style stem the Threads complete, shown ten public-knowledge pairs and the question,
//        its greedy continuation cut at the blank. It never sees a Thread's fact. A rewrite that is
//        empty, still a question, or drops a capitalised word of the question (the subject) falls
//        back to the question itself.
//

import BraidCore
import Foundation
import MLX

public final class QuestionAdapter {
    public static let examples: [(question: String, stem: String)] = [
        ("When was the Eiffel Tower completed?", "The Eiffel Tower was completed in ___"),
        ("Who wrote Pride and Prejudice?", "Pride and Prejudice was written by ___"),
        ("What is the capital of Australia?", "The capital of Australia is ___"),
        ("Who painted the Mona Lisa?", "The Mona Lisa was painted by ___"),
        ("When did the Berlin Wall fall?", "The Berlin Wall fell in ___"),
        ("Who discovered penicillin?", "Penicillin was discovered by ___"),
        ("What is the largest ocean on Earth?", "The largest ocean on Earth is ___"),
        ("When was the printing press invented?", "The printing press was invented in ___"),
        ("Who composed The Magic Flute?", "The Magic Flute was composed by ___"),
        ("How many moons does Mars have?", "The number of moons Mars has is ___"),
    ]

    static let questionWords: Set<String> = ["who", "what", "when", "where", "why", "how", "which", "is", "are", "was", "were", "did", "does", "do", "can", "could"]

    public let trunk: Trunk
    public let reed: MLXReed
    public let tokenizer: BraidTokenizer

    public init(trunk: Trunk, reed: MLXReed, tokenizer: BraidTokenizer) {
        self.trunk = trunk
        self.reed = reed
        self.tokenizer = tokenizer
    }

    public func prompt(for question: String) -> String {
        Self.examples.map { "Question: \($0.question)\nStem: \($0.stem)\n\n" }.joined() + "Question: \(question)\nStem:"
    }

    /// The commons' greedy continuation up to the blank or a newline, at most `maxTokens` tokens.
    public func rewrite(_ question: String, maxTokens: Int = 24) -> QuestionRewrite {
        let started = Date()
        var ids: [Int32] = [tokenizer.eos] + tokenizer.encode(prompt(for: question))
        var out = trunk.forward(tokens: MLXArray(ids, [1, ids.count]), state: nil, resets: nil)
        var last = out.final[0, ids.count - 1]
        var generated: [Int32] = []
        for _ in 0..<maxTokens {
            let logits = reed.logits(array: last.reshaped([1, trunk.config.hiddenSize]))
            let next = Int32(argMax(logits, axis: -1).item(Int32.self))
            if next == tokenizer.eos { break }
            let text = tokenizer.text(next)
            if text.contains("\n") { break }
            generated.append(next)
            ids.append(next)
            if text.contains("_") { break }
            out = trunk.step(token: MLXArray([next]), state: out.state, reset: nil)
            last = out.final[0]
        }
        let raw = tokenizer.decode(generated)
        let stem = Self.clean(raw)
        let seconds = Date().timeIntervalSince(started)
        if Self.acceptable(stem: stem, question: question) {
            return QuestionRewrite(question: question, stem: stem, rewriter: "commons", seconds: seconds)
        }
        return QuestionRewrite(question: question, stem: question, rewriter: "none", seconds: seconds)
    }

    /// Everything before the first underscore, trimmed, trailing `?`/`:` dropped.
    public static func clean(_ raw: String) -> String {
        var text = raw
        if let blank = text.firstIndex(of: "_") { text = String(text[..<blank]) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = text.last, last == "?" || last == ":" { text.removeLast() }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Non-empty, not a question, keeps every capitalised word of the question (the subject).
    public static func acceptable(stem: String, question: String) -> Bool {
        guard !stem.isEmpty, !stem.hasSuffix("?") else { return false }
        let firstWord = stem.split(whereSeparator: { !$0.isLetter }).first.map { $0.lowercased() } ?? ""
        if questionWords.contains(firstWord) { return false }
        let subjects = question.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init).dropFirst().filter { $0.first?.isUppercase == true }
        let lowered = stem.lowercased()
        return subjects.allSatisfy { lowered.contains($0.lowercased()) }
    }

    /// The question's capitalised words after the first: the subject the Threads look for.
    public static func subject(of question: String) -> [String] {
        question.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init).dropFirst().filter { $0.first?.isUppercase == true }
    }

    /// The token range of `stem` that covers the subject's words (the first through the last, in
    /// order of appearance), or nil when the stem does not write them.
    public static func subjectRange(stem: [Int32], subject: [String], text: (Int32) -> String) -> Range<Int>? {
        guard let first = subject.first else { return nil }
        var joined = ""
        var starts: [Int] = []
        for token in stem {
            starts.append(joined.utf8.count)
            joined += text(token)
        }
        guard let head = joined.range(of: first) else { return nil }
        var tail = head
        var cursor = head.upperBound
        for word in subject.dropFirst() {
            guard let found = joined.range(of: word, range: cursor ..< joined.endIndex) else { break }
            tail = found
            cursor = found.upperBound
        }
        let lowerByte = joined.utf8.distance(from: joined.utf8.startIndex, to: head.lowerBound.samePosition(in: joined.utf8) ?? joined.utf8.startIndex)
        let upperByte = joined.utf8.distance(from: joined.utf8.startIndex, to: tail.upperBound.samePosition(in: joined.utf8) ?? joined.utf8.endIndex)
        guard let startToken = starts.lastIndex(where: { $0 <= lowerByte }), let endToken = starts.lastIndex(where: { $0 < upperByte }), startToken <= endToken else { return nil }
        return startToken ..< endToken + 1
    }
}
