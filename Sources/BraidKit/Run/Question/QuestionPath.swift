//
//  QuestionPath.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The question path `braid chat` and `braid bench question` share. A question is rewritten
//        by the commons into a corpus-style stem (or a stem is given), the stem is encoded with a
//        leading space, its subject placed, and each Thread is asked for its own context: the
//        sentence before its best hit at the recognition floor, read from its index. The braid then
//        completes the stem behind each Thread's context, the commons on the bare stem, and stops at
//        the end of the sentence.
//  PIN:  One path, so what the bench measures is what chat answers. The rewrite never sees a
//        Thread's fact; a rewrite the adapter rejects falls back to the question itself.
//

import BraidCore
import Foundation

/// One question, ready to complete.
public struct QuestionTurn: Sendable {
    public var question: String
    /// The commons' rewrite (nil when the stem was given).
    public var rewrite: QuestionRewrite?
    /// What the braid completes: the rewrite's stem, the given stem, or the question itself.
    public var stem: String
    public var tokens: [Int32]
    /// The stem's tokens that write the question's subject, when they do.
    public var subject: Range<Int>?
    /// Per Thread, the sentence it completes behind (Threads that found none complete the bare stem).
    public var contexts: [String: NodeContext]

    public init(question: String, rewrite: QuestionRewrite?, stem: String, tokens: [Int32], subject: Range<Int>?, contexts: [String: NodeContext]) {
        self.question = question
        self.rewrite = rewrite
        self.stem = stem
        self.tokens = tokens
        self.subject = subject
        self.contexts = contexts
    }

    public var prompt: GenerationPrompt { GenerationPrompt(text: stem, tokens: tokens, question: rewrite) }
}

public enum QuestionPath {
    /// A Thread's best hit must score this to hand back a context.
    public static let floor: Float = 0.6

    /// Stems are encoded with a leading space, so a Thread's context and the stem concatenate to the
    /// tokens of the joined text.
    public static func stemTokens(_ stem: String, tokenizer: any Tokenizing) -> [Int32] {
        tokenizer.encode(" " + stem.trimmingCharacters(in: .whitespaces))
    }

    /// The commons rewrites `question` (with `adapter`) unless `stem` is given; each of `nodes` then
    /// looks for its context at `floor`.
    public static func prepare(question: String, stem given: String? = nil, adapter: QuestionAdapter?, nodes: [(name: String, node: LocalNode)],
                               tokenizer: BraidTokenizer, k: Int, floor: Float = floor, rewriteTokens: Int = 24) throws -> QuestionTurn {
        var rewrite: QuestionRewrite? = nil
        if given == nil, let adapter { rewrite = adapter.rewrite(question, maxTokens: rewriteTokens) }
        return try prepare(question: question, rewrite: rewrite, stem: given ?? rewrite?.stem ?? question, nodes: nodes, tokenizer: tokenizer, k: k, floor: floor)
    }

    /// The same with the rewrite already made (the bench asks one question in several sets).
    public static func prepare(question: String, rewrite: QuestionRewrite?, stem: String, nodes: [(name: String, node: LocalNode)],
                               tokenizer: BraidTokenizer, k: Int, floor: Float = floor) throws -> QuestionTurn {
        let tokens = stemTokens(stem, tokenizer: tokenizer)
        let subject = QuestionAdapter.subjectRange(stem: tokens, subject: QuestionAdapter.subject(of: question), text: { tokenizer.text($0) })
        var contexts: [String: NodeContext] = [:]
        for (name, node) in nodes {
            if let found = try node.context(stem: tokens, subject: subject, k: k, floor: floor) { contexts[name] = found }
        }
        return QuestionTurn(question: question, rewrite: rewrite, stem: stem, tokens: tokens, subject: subject, contexts: contexts)
    }

    /// The parameters an answer is generated with: `base`, stopping at the end of the sentence.
    public static func parameters(_ base: GenerationParameters) -> GenerationParameters {
        var params = base
        params.stopAtSentenceEnd = true
        return params
    }

    /// Completes the turn on `cluster`.
    public static func answer(_ turn: QuestionTurn, cluster: Cluster, params: GenerationParameters) throws -> Generation {
        try cluster.generate(prompt: turn.prompt, contexts: turn.contexts, params: parameters(params))
    }

    /// RaoLM's stem comparison: lowercase, trailing punctuation stripped, spaces collapsed.
    public static func normalised(_ stem: String) -> String {
        var text = stem.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = text.last, ".?!:,;".contains(last) { text.removeLast() }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Token F1 of two stems over their normalised words.
    public static func tokenF1(_ a: String, _ b: String) -> Double {
        let x = normalised(a).split(separator: " ").map(String.init)
        let y = normalised(b).split(separator: " ").map(String.init)
        guard !x.isEmpty, !y.isEmpty else { return x.isEmpty && y.isEmpty ? 1 : 0 }
        var counts: [String: Int] = [:]
        for word in y { counts[word, default: 0] += 1 }
        var common = 0
        for word in x where (counts[word] ?? 0) > 0 {
            common += 1
            counts[word]! -= 1
        }
        guard common > 0 else { return 0 }
        let precision = Double(common) / Double(x.count)
        let recall = Double(common) / Double(y.count)
        return 2 * precision * recall / (precision + recall)
    }
}
