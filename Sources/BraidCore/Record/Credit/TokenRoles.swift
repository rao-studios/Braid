//
//  TokenRoles.swift
//  BraidCore
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The owner's blend: the commons provides a text's structure and form, the Threads its
//        content, information and taste. Every token is form (whitespace, punctuation, a function
//        word) or content; roles go by whole words, so every piece of a word takes the word's
//        role. A form token's credit is the commons'; a content token's is each strand's as it
//        supplied it. Each token counts by its bits, −log₂ of what the commons gave it.
//  PIN:  A derived view over the session log, never stored per token.
//

import Foundation

public enum TokenRole: String, Codable, Sendable { case form, content }

public enum TokenRoles {
    public static let functionWords: Set<String> = Set("""
        a an the this that these those my your his her its our their i you he she it we they me him us them who whom whose which what
        of in on at to for with by from about as into onto over under between through during before after above below up down out off
        near since until upon within without and or but nor so yet if then than because while when where though although whether
        is are was were be been being am has have had do does did will would can could may might shall should must
        not no there here also just very too only more most such each every some any all both either neither other another own same
        """.split(whereSeparator: \.isWhitespace).map(String.init))

    static let clitics: Set<String> = ["'s", "'t", "'re", "'ll", "'d", "'ve", "'m", "’s", "’t", "’re", "’ll", "’d", "’ve", "’m"]

    /// Each token's role, from the tokens' texts in order, each as the tokenizer decodes it alone.
    public static func roles(_ texts: [String]) -> [TokenRole] {
        var roles = [TokenRole](repeating: .content, count: texts.count)
        var start = 0
        func close(_ end: Int) {
            guard end > start else { return }
            let role = role(of: texts[start..<end].joined().trimmingCharacters(in: .whitespacesAndNewlines))
            for i in start..<end { roles[i] = role }
            start = end
        }
        for i in texts.indices.dropFirst() where startsWord(texts[i], after: texts[i - 1]) { close(i) }
        close(texts.count)
        return roles
    }

    static func role(of word: String) -> TokenRole {
        if !word.contains(where: { $0.isLetter || $0.isNumber }) { return .form }
        let lower = word.lowercased()
        if clitics.contains(lower) { return .form }
        if word.allSatisfy(\.isLetter), functionWords.contains(lower) { return .form }
        return .content
    }

    static func startsWord(_ text: String, after previous: String) -> Bool {
        guard let first = text.first else { return false }
        if first.isWhitespace || !(first.isLetter || first.isNumber) { return true }
        guard let last = previous.last else { return true }
        return !(last.isLetter || last.isNumber)
    }
}
