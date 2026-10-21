//
//  main.swift
//  Proof
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The proof that the delta, a Thread's own blocks on the commons' trunk, is the key to
//        provenance, and of the two places it works. Two Threads read one corpus behind one commons.
//        proof-<node>-delta trains blocks 0..<12 of its own; proof-<node>-frozen keeps the commons'
//        blocks 0..<12, bit for bit. Both index the same documents and withhold the same ones. The
//        same texts are scored through both in one braid. Detection reads the Thread's own entropy,
//        H_lm, on texts no index holds; citation reads the retrieval entropy, H_knn, on texts the
//        index holds. ProofRules.swift says, before any number, what counts as proof, and quotes
//        beside each rule the passage of the essay below that it tests.
//  IN:   The T9 mounted for the dataset, and for the pack unless it was downloaded once. Nothing
//        else on the GPU. Run by Examples/proof.sh; `proof.sh --help` lists the options.
//  OUT:  Numbered steps, the readings per set and arm, the rules and their verdicts, a report under
//        Examples/.work/bench/proof/, and the session log `braid verify` replays. Exit 0 only when
//        C0, D1, D2, R1 and R2 pass.
//  PIN:  One MLX workload at a time: building, indexing and scoring run on this thread, one after
//        another. No default changes: the cut, the key, τ, k and the gate are braid.toml's. The arms
//        are built once and reused while their corpus is unchanged.
//
//  Where the idea comes from: Suchir Balaji, "When does generative AI qualify for fair use?",
//  suchir.net/fair_use.html, 2024. Its reading of entropy, that a model's low-entropy outputs are
//  the likeliest to carry its training data, met Braid's distributed design: many Threads, each a
//  delta of its own on one shared commons. Together they gave the idea this proof tests, that the
//  delta, read through the Thread's own entropy H_lm, is what makes provenance. I think we would
//  have made a great team.
//
//  This example is primarily used as a resource to cite as the technical example when writing. The
//  proof is currently being worked on and this is currently not the final, but a starting point that
//  doubles as research towards an optimal distributed design for language models that hopes to address
//  multiple ethical concerns in the A.I. space.   

import BraidKit
import Foundation
import Scratch

setvbuf(stdout, nil, _IOLBF, 0)
let options = ProofOptions.parseOrExit()
let startedAt = Date()
ProofShow.title(startedAt)

var proved = false
do {
    // 0. MLX's Metal library beside this binary, before anything touches MLX.
    if let source = try ScratchArea.installMetalLibrary() { ProofShow.step(0, "metal", "mlx.metallib copied beside this binary from \(source)") }

    // 1. The playground's work area and the commons' pack.
    let scratch = try ScratchArea.prepare(at: ScratchArea.playground().appendingPathComponent(".work", isDirectory: true)) { ProofShow.note($0) }
    let area = scratch.area
    let pack = scratch.pack
    let cut = pack.config.cut
    ProofShow.step(1, "work area", "\(area.root.path) · pack \(pack.info.name) \(pack.sha256.prefix(12)), \(scratch.origin)")

    // 2. The dataset: the arms' corpus, and the texts neither arm reads.
    guard case .dataset(let datasetName, let node) = try CorpusSourceSpec(parsing: options.corpus) else {
        throw BraidFailure.usage("the proof reads a dataset, not \(options.corpus)", hint: "--corpus dataset:<name>#<node>")
    }
    let world = BenchWorld(dataset: try BraidDataset.load(DatasetsRoot.locate(datasetName, root: DatasetsRoot.resolve(workArea: area.root))))
    guard let corpus = world.corpora[node] else {
        throw BraidFailure.missing("dataset \(world.name) has no node \(node)", hint: "its nodes: \(world.corpora.keys.sorted().joined(separator: ", "))")
    }
    let others = world.corpora.keys.sorted().filter { $0 != node }
    ProofShow.step(2, "dataset", "\(world.name) · \(node), \(corpus.documents.count) documents; both arms read the first \(options.limit) "
                   + "and withhold \(BenchFormat.pct(options.withhold)) of them from their index (seed \(options.seed))")
    if !others.isEmpty { ProofShow.more("\(others.joined(separator: " and ")) give the unrelated texts, from what a Thread of each would read") }

    // 3. The arms: the same recipe twice, with training on for one and off for the other. Their names
    //    carry the node, so another corpus's arms are never touched.
    let spec = CorpusSourceSpec.dataset(nameOrPath: datasetName, node: node)
    let deltaName = ProofArms.delta(node)
    let frozenName = ProofArms.frozen(node)
    if options.fresh {
        for name in [frozenName, deltaName] {
            let root = area.thread(name).root
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            try FileManager.default.removeItem(at: root)
            ProofShow.more("--fresh: removed \(root.path)")
        }
    }
    let tokenizer = try BraidTokenizer(folder: pack.tokenizerFolder)
    let reed = pack.reed(tokens: tokenizer.vocabSize)
    let scheme = KeyScheme(parsing: scratch.config.pack?.keyScheme ?? "") ?? .residual(afterBlocks: pack.config.tapAfterBlocks)
    let built = Date()
    do {
        let commons = try ThreadStore.commons(pack: pack, scheme: scheme)    // the trunk both heads run behind
        let engine = BraidEngine(area: area, config: scratch.config, pack: pack, tokenizer: tokenizer, reed: reed, commons: commons) { event in
            if let line = event.line { ProofShow.note(line) }
        }
        func arm(_ name: String, _ training: TrainingPlan) -> ThreadRecipe {
            ThreadRecipe(name, corpus: spec).limit(options.limit).withhold(options.withhold).seed(options.seed).training(training).attached(false)
        }
        // The frozen arm first: it takes seconds, so a refusal shows before the minutes of training.
        let recipe = BraidRecipe(threads: [arm(frozenName, .off), arm(deltaName, .on(steps: options.steps))])
        let plans = try engine.plan(recipe)
        ProofShow.plan(3, plans)
        if let changed = plans.first(where: { $0.intent == .sync }) {
            throw BraidFailure.usage("thread \(changed.name)'s corpus changed since it was built; a sync would train it on from its live version",
                                     hint: "Examples/proof.sh --fresh builds both arms again")
        }
        if plans.contains(where: { $0.name == deltaName && $0.intent == .create }) {
            var hyper = DeltaHyper()
            if let steps = options.steps { hyper.scratchSteps = steps }
            ProofShow.more("the delta trains with DeltaHyper's defaults: windows of \(hyper.seqLen), batches of \(hyper.batchSize), "
                           + "learning rate \(hyper.peakLR) falling to \(hyper.finalLR), \(hyper.scratchSteps) steps planned, "
                           + "stopping once \(BenchFormat.pct(hyper.learnedThreshold)) is memorised")
        }
        for (plan, outcome) in zip(plans, try engine.build(recipe)) {
            ProofShow.more(outcome?.summary ?? "\(plan.name) is up to date")
        }
    }
    ProofShow.more("arms ready in \(Int(Date().timeIntervalSince(built).rounded())) s")

    // 4. One braid: the commons and both arms under one reed. Each strand's H_knn, H_lm, hits,
    //    trace and lift are its own, so the two arms can share a braid and every text is scored once.
    let braid = try BenchBraid.assemble(area: area, config: scratch.config, pack: pack, threadNames: [deltaName, frozenName],
                                        commons: true) { ProofShow.note($0) }
    guard let deltaThread = braid.threads.first(where: { $0.info.name == deltaName }),
          let frozenThread = braid.threads.first(where: { $0.info.name == frozenName }),
          let own = try braid.benchThreads(world: world, warn: { ProofShow.note("warning: \($0)") }).first(where: { $0.name == deltaName })
    else { throw BraidFailure.data("the braid lacks an arm") }
    let records = ProofRecords(packSHA256: pack.sha256,
                               drawn: Withholding.draw(Array(own.present), fraction: options.withhold, seed: options.seed).sorted(),
                               delta: ProofArm(deltaThread), frozen: ProofArm(frozenThread))
    ProofShow.step(4, "braid", braid.names.joined(separator: " + ") + " under one reed, τ \(scratch.config.index.tau), k \(scratch.config.index.k)")
    ProofShow.arm(records.delta, cut: cut)
    ProofShow.arm(records.frozen, cut: cut)
    // C0's records are known before any text is scored; when they fail, no other rule can be read.
    let failures = ProofRules.recordFailures(records)
    guard failures.isEmpty else {
        throw BraidFailure.data("C0 fails before any text is scored, so no other rule is read: " + failures.joined(separator: "; "),
                                hint: "Examples/proof.sh --fresh builds both arms again")
    }

    // 5. The texts, from the copy itself, where citation is read, through the withheld documents,
    //    where detection is read, to what neither arm was given (ProofTexts.swift).
    let texts = ProofTexts.build(world: world, node: node, present: own.present, withheld: Set(records.delta.withheld), limit: options.limit,
                                 tokenizer: braid.tokenizer, paragraphBreak: braid.tokenizer.paragraphBreak)
    ProofShow.step(5, "texts", ProofSet.allCases.map { set in "\(set.title) \(texts.filter { $0.set == set }.count)" }.joined(separator: " · "))
    ProofShow.more("each read as its index read it, whole up to 256 tokens when it has at least 64")

    // 6. Score every text through every strand, prompt only, in one kept session.
    guard let d = braid.index(of: deltaName), let f = braid.index(of: frozenName), let c = braid.commonsIndex else {
        throw BraidFailure.data("the braid lacks the commons or an arm")
    }
    let module = braid.settings.module ?? ModuleSettings()
    let session = try braid.keepSession()
    ProofShow.step(6, "scoring", "\(texts.count) texts through \(braid.names.count) strands, nothing generated")
    let scoring = Date()
    var scored: [ProofText] = []
    for (i, text) in texts.enumerated() {
        if i % 20 == 0 { ProofShow.note("scoring \(i)/\(texts.count)") }
        let generation = try braid.score(text.tokens)
        scored.append(ProofTexts.read(text, generation: generation, names: braid.names, delta: d, frozen: f, commons: c, module: module))
        if i % 8 == 7 { braid.relax() }
    }
    braid.finishSession()
    ProofShow.more("scored in \(Int(Date().timeIntervalSince(scoring).rounded())) s")
    print("")

    // 7–8. Read the rules, written before this data was read, over what was scored.
    let verdict = ProofRules.evaluate(texts: scored, records: records)
    ProofShow.readings(7, verdict.rows)
    ProofShow.rules(8, verdict)
    ProofShow.reported(verdict)

    let report = ProofReport(createdAt: BenchFormat.wholeSecond(startedAt), corpus: spec.description, dataset: world.name, limit: options.limit,
                             withhold: options.withhold, seed: options.seed, steps: options.steps, threads: braid.threadRecords,
                             gate: braid.settings.gate, tau: scratch.config.index.tau, k: scratch.config.index.k, from: ProofRules.from,
                             sizes: StitchedSizes(), records: records, texts: scored, verdict: verdict, sessions: braid.sessions.map(\.path))
    let reportURL = options.report.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        ?? BenchFormat.reportURL(area: area, bench: "proof", at: startedAt)
    try JSONCoding.write(report, to: reportURL)
    let repository = ScratchArea.playground().deletingLastPathComponent()
    print("  report    " + ProofShow.short(reportURL, repository: repository))
    print("  session   " + ProofShow.short(session, repository: repository))
    print("  verify    Scripts/cli.sh verify --work-area Examples/.work " + ProofShow.short(session, repository: repository))

    ProofShow.verdict(verdict, on: startedAt, cut: cut, corpus: "\(world.name)'s \(node) node")
    proved = verdict.proved
} catch {
    print("proof: \(error)")
    exit(1)
}
exit(proved ? 0 : 1)
