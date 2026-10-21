//
//  ThreadRecipe.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: A Thread as a recipe: its name, its corpus source, and the settings that shape it (label,
//        limit, key scheme, checkpoints, training, withheld documents, seed, attach). A recipe is a
//        value; it builds nothing. The engine reads it and runs the stages it calls for. Modifiers
//        return a changed copy, so a recipe reads top to bottom:
//
//            ThreadRecipe("ambient", corpus: .dataset("braid-n3", node: "ambient"))
//                .limit(40)
//                .training(.on(steps: 1000))
//
//  PIN:  Every unset setting keeps today's default: the key comes from braid.toml (else the pack's
//        tap), checkpoints every 1,024 tokens, DeltaHyper's budget, seed 42, attached.
//

import BraidCore
import Foundation

public struct ThreadRecipe: Sendable, Equatable {
    public struct Settings: Sendable, Equatable {
        /// The display label; nil capitalises the name.
        public var label: String?
        /// Only the first N documents of a dataset node (feeding order).
        public var limit: Int?
        /// The key scheme; nil takes braid.toml's, then the pack's tap.
        public var key: KeyScheme?
        public var checkpoints = CheckpointPolicy()
        public var training: TrainingPlan = .standard
        /// A fraction of the documents trained on but left out of the index, drawn by `seed`.
        public var withhold: Double?
        /// The training seed, which also draws the withheld documents; nil is DeltaHyper's (42).
        public var seed: UInt64?
        /// Add the Thread to `[cluster] attach` in braid.toml. Never detaches.
        public var attach = true

        public init() {}
    }

    public var name: String
    public var corpus: CorpusSourceSpec
    public var settings = Settings()

    public init(_ name: String, corpus: CorpusSourceSpec) {
        self.name = name
        self.corpus = corpus
    }

    /// `corpus` as `braid thread create --corpus` takes it: `dataset:<name>#<node>`, `dir:<path>`, `aii:<aii>/<lane>`, `app:<aii>/<app>`.
    public init(_ name: String, corpus: String) throws {
        self.init(name, corpus: try CorpusSourceSpec(parsing: corpus))
    }

    private func with(_ change: (inout Settings) -> Void) -> ThreadRecipe {
        var copy = self
        change(&copy.settings)
        return copy
    }

    public func label(_ label: String) -> ThreadRecipe { with { $0.label = label } }
    public func limit(_ documents: Int) -> ThreadRecipe { with { $0.limit = documents } }
    public func key(_ scheme: KeyScheme) -> ThreadRecipe { with { $0.key = scheme } }
    public func checkpoints(_ policy: CheckpointPolicy) -> ThreadRecipe { with { $0.checkpoints = policy } }
    public func training(_ plan: TrainingPlan) -> ThreadRecipe { with { $0.training = plan } }
    public func withhold(_ fraction: Double) -> ThreadRecipe { with { $0.withhold = fraction } }
    public func seed(_ seed: UInt64) -> ThreadRecipe { with { $0.seed = seed } }
    public func attached(_ attach: Bool) -> ThreadRecipe { with { $0.attach = attach } }
}

extension CorpusSourceSpec {
    /// One node of a braid dataset: `dataset:<name or path>#<node>`.
    public static func dataset(_ nameOrPath: String, node: String) -> CorpusSourceSpec { .dataset(nameOrPath: nameOrPath, node: node) }

    /// A folder of .txt files, one document each: `dir:<path>`.
    public static func folder(_ path: String) -> CorpusSourceSpec {
        .directory(URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true))
    }
}

extension KeyScheme {
    /// `residual:<n>`, `pooled-state:<layer>` or `state-delta:<layer>`, or a usage failure.
    public static func parsed(_ text: String) throws -> KeyScheme {
        guard let scheme = KeyScheme(parsing: text) else { throw BraidFailure.usage("unknown key scheme \(text)") }
        return scheme
    }
}

extension CheckpointPolicy {
    /// A checkpoint at every partition boundary (for transfer), not only every 1,024 tokens.
    public static var atEveryPartition: CheckpointPolicy {
        var policy = CheckpointPolicy()
        policy.everyPartition = true
        return policy
    }
}
