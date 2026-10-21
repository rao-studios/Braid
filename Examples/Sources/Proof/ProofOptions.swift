//
//  ProofOptions.swift
//  Proof
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: What `proof.sh` takes. Every default is the data the rules in ProofRules.swift are read on
//        first, as the owner chose on 2026-10-19: braid-n3's craft node, its first 60 documents, a
//        third of them withheld from the index (20), seed 42 and DeltaHyper's training budget. The
//        first run read ambient's first 40 with a fifth withheld, the recipe of the bench braid's
//        ambient-p: `--corpus dataset:braid-n3#ambient --limit 40 --withhold 0.2`.
//  PIN:  The options name the arms. They never change a default of the braid: the cut, the key,
//        τ, k and the gate are the pack's and braid.toml's. --fresh deletes only the node's two
//        arms, threads/proof-<node>-delta and threads/proof-<node>-frozen, in Examples/.work.
//

import ArgumentParser
import Foundation

struct ProofOptions: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "proof.sh",
        abstract: "The delta over entropy: whether a Thread's own blocks are what make its retrieval entropy a provenance signal.",
        discussion: """
            Builds two Threads on one corpus in Examples/.work. proof-<node>-delta trains blocks 0..<12 of its own; \
            proof-<node>-frozen keeps the commons' blocks 0..<12. Both index the same documents and withhold the same ones. \
            The same texts are scored through both in one braid and read by the rules in Sources/Proof/ProofRules.swift: \
            detection by the Thread's own entropy on texts no index holds, citation by the retrieval entropy on texts \
            the index holds. The arms are built once and reused while their corpus is unchanged. Exit 0 only when C0, \
            D1, D2, R1 and R2 pass.
            """)

    @Option(help: ArgumentHelp("The corpus both arms read.", valueName: "dataset:<name>#<node>"))
    var corpus = "dataset:braid-n3#craft"

    @Option(help: "How many documents both arms read, the first in feeding order.")
    var limit = 60

    @Option(help: "The fraction of those documents both arms read but leave out of their index.")
    var withhold = 0.33

    @Option(help: "Draws the withheld documents and seeds the delta's training.")
    var seed: UInt64 = 42

    @Option(help: "Training steps planned for the delta (default DeltaHyper's 1,000; it stops once it has learned).")
    var steps: Int?

    @Flag(help: "Delete both arms and build them again.")
    var fresh = false

    @Option(help: ArgumentHelp("Where to write the report (default Examples/.work/bench/proof/<UTC stamp>.json).", valueName: "path"))
    var report: String?

    func validate() throws {
        guard limit >= 2 else { throw ValidationError("--limit takes at least 2 documents") }
        guard withhold > 0, withhold < 1 else { throw ValidationError("--withhold takes a fraction between 0 and 1, not \(withhold)") }
        if let steps, steps < 1 { throw ValidationError("--steps takes a positive number") }
    }
}
