//
//  BraidRecipe.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: A braid's Threads as one declaration, written the way a SwiftUI body is: one recipe per
//        line, with `if` and `for` where the set depends on something.
//
//            let braid = try BraidRecipe {
//                for node in ["ambient", "craft"] {
//                    ThreadRecipe(node, corpus: .dataset("braid-n3", node: node))
//                }
//                if withVeil { try ThreadRecipe("veil", corpus: "aii:demo-a/veil").training(.off) }
//            }
//
//        The commons is braid.toml's pack. BraidEngine.plan(_:) says what building it would do;
//        BraidEngine.build(_:) does it, one Thread after another.
//

import Foundation

@resultBuilder
public enum BraidBuilder {
    public static func buildExpression(_ recipe: ThreadRecipe) -> [ThreadRecipe] { [recipe] }
    public static func buildExpression(_ recipes: [ThreadRecipe]) -> [ThreadRecipe] { recipes }
    public static func buildBlock(_ parts: [ThreadRecipe]...) -> [ThreadRecipe] { parts.flatMap { $0 } }
    public static func buildOptional(_ part: [ThreadRecipe]?) -> [ThreadRecipe] { part ?? [] }
    public static func buildEither(first part: [ThreadRecipe]) -> [ThreadRecipe] { part }
    public static func buildEither(second part: [ThreadRecipe]) -> [ThreadRecipe] { part }
    public static func buildArray(_ parts: [[ThreadRecipe]]) -> [ThreadRecipe] { parts.flatMap { $0 } }
}

public struct BraidRecipe: Sendable, Equatable {
    public var threads: [ThreadRecipe]

    public init(@BraidBuilder _ content: () throws -> [ThreadRecipe]) rethrows {
        threads = try content()
    }

    public init(threads: [ThreadRecipe]) {
        self.threads = threads
    }
}
