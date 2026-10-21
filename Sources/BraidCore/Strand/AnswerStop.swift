//
//  AnswerStop.swift
//  BraidCore
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Where an answer ends: the rule a generation stops on (`stop: sentence`) and that
//        followed credit closes a sentence with.
//

import Foundation

/// Where an answer ends: a sentence ends when the text so far ends in `.?!` and the next token
/// opens with whitespace or a capital, or when the next token holds a newline.
public enum AnswerStop {
    public static func sentenceEnded(previous: String, next: String) -> Bool {
        if next.contains("\n") { return true }
        guard let last = previous.last(where: { !$0.isWhitespace }), ".?!".contains(last) else { return false }
        guard let first = next.first else { return false }
        return first.isWhitespace || first.isNewline || first.isUppercase
    }
}
