//
//  main.swift
//  Braid
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The loop, top to bottom: join this Mac's AII as an app of its own, record test data in the
//        app's lane, train one Thread on those records, attach it to a braid beside the commons,
//        complete an entry in its own words, and verify the session the answer was logged in.
//  IN:   AII installed on this Mac (`aii status`); the T9 mounted, or the network for one download.
//        Run by Examples/run.sh, or from Xcode (Examples/Package.swift, Run): step 0 puts MLX's
//        Metal library beside whichever binary runs. `run.sh forget` takes the records out of the lane.
//  OUT:  One numbered block per step. Kept afterwards: the braidplayground lane and its records in
//        ~/.rao, and Examples/.work (braid.toml, the pack link, threads/harbour, sessions/). Exit
//        0 only when the answer names the fact and the session verifies.
//  PIN:  AII's calls are awaited; Braid's are synchronous, on this thread, which owns MLX (one MLX
//        workload at a time). Never aii.leave(): with no other app holding the servers it would
//        stop this Mac's Sewn and Thread. The playground only releases its own hold.
//

import AII
import BraidKit
import Foundation
import Scratch

setvbuf(stdout, nil, _IOLBF, 0)

// 0. MLX's Metal library beside this binary, before anything touches MLX (a run from Xcode has none).
do {
    if let source = try ScratchArea.installMetalLibrary() { print("0 metal     mlx.metallib copied beside this binary from \(source)") }
} catch {
    print("playground: \(error)")
    exit(1)
}

// 1. Join this Mac's AII as an app of its own: its lane is registered (a secret, and an entry in
//    ~/.rao/aii/lanes.json), the running Sewn and Thread are adopted (or started), and both prove
//    the app's secret.
let aii = AIIInstance(PlaygroundApp.self)
do {
    try await aii.join()
} catch {
    await aii.supervisor.release()
    print("playground: \(error)")
    print("  is AII installed? aii status, then aii install")
    exit(1)
}
print("1 join      the \(aii.app) lane is registered; Sewn and Thread proved its secret (owner \(aii.owner))")

// `run.sh forget`: take the records out of the lane (removing the lane alone keeps its documents).
if CommandLine.arguments.dropFirst().first == "forget" {
    do {
        let forgotten = try await aii.forget(groups: [LogEntry.group.id])
        print("  forget    \(forgotten.documentCount) records from \(forgotten.groups.joined(separator: ", ")); the lane stays: aii lanes remove \(aii.app) --yes")
    } catch {
        print("playground: \(error)")
    }
    await aii.supervisor.release()
    exit(0)
}

var passed = false
do {
    // 2. Record the test data. AII files each entry as a record in the app's lane and returns once
    //    Thread holds every one; AII's own search finds them.
    let filed = try await aii.remember(harbourLog)
    print("2 remember  \(filed) entries as \(aii.app)/\(LogEntry.kind)/<id> in \(AIIRecord.groupID(app: aii.app, group: LogEntry.group.id))")
    for match in try await aii.recall(TestQuery.recall, as: LogEntry.self, topK: 2) {
        print("  recall    \(match.value.title) (\(match.hit.documentID)) · distance \(String(format: "%.3f", match.hit.distance))")
    }

    // 3. A Braid work area of the playground's own, with the commons' pack.
    let scratch = try ScratchArea.prepare(at: ScratchArea.playground().appendingPathComponent(".work", isDirectory: true)) { print("    \($0)") }
    let area = scratch.area
    let pack = scratch.pack
    print("3 work area \(area.root.path) · pack \(pack.info.name) \(pack.sha256.prefix(12)), \(scratch.origin)")

    // 4. Train one Thread on the app's records. A training window must fit in the token stream
    //    (eos ‖ d0 ‖ eos ‖ d1 ‖ …): 128 tokens here, against the log's ~750.
    let tokenizer = try BraidTokenizer(folder: pack.tokenizerFolder)
    let reed = pack.reed(tokens: tokenizer.vocabSize)
    let window = 128
    let stream = 1 + harbourLog.reduce(0) { $0 + tokenizer.encode($1.text).count + 1 }
    guard stream > window + 1 else { throw BraidFailure.usage("the log is \(stream) tokens; training needs more than one window of \(window)") }
    let scheme = KeyScheme(parsing: scratch.config.pack?.keyScheme ?? "") ?? .residual(afterBlocks: pack.config.tapAfterBlocks)
    let commons = try ThreadStore.commons(pack: pack, scheme: scheme)                   // the trunk the Thread trains and runs behind
    let engine = BraidEngine(area: area, config: scratch.config, pack: pack, tokenizer: tokenizer, reed: reed, commons: commons) { event in
        if let line = event.line { print("    \(line)") }
    }
    let braid = BraidRecipe {
        ThreadRecipe("harbour", corpus: .app("home/\(PlaygroundApp.app)"))
            .training(.on(steps: 300, seqLen: window))
    }
    for plan in try engine.plan(braid) {
        print("4 plan      " + plan.summary.replacingOccurrences(of: "\n", with: "\n          "))
    }
    for outcome in try engine.build(braid) {
        print("  built     " + (outcome?.summary ?? "harbour is up to date"))
    }

    // 5. The braid: the commons and the harbour Thread under one reed, logged from here on.
    let config = engine.config
    var settings = ClusterSettings()
    settings.gate = config.gate
    settings.k = config.index.k
    let cluster = Cluster(reed: reed, tokenizer: tokenizer, pack: pack.identity, settings: settings)
    try cluster.attach(commons)
    let harbour = try ThreadStore.load("harbour", in: area, pack: pack, commons: commons, tau: Float(config.index.tau))
    try cluster.attach(harbour.node)
    let sessionURL = area.sessions.appendingPathComponent(SessionLog.fileName(sessionID: cluster.sessionID))
    try cluster.startLog(at: sessionURL)
    print("5 braid     \(cluster.strandNames.joined(separator: " + ")) · harbour v\(harbour.version.version), \(harbour.version.entries) entries, memorised \(String(format: "%.1f", harbour.version.memorised * 100))%")

    // 6. The test query: the lighthouse entry in its own words, completed to the end of its sentence.
    var params = GenerationParameters()
    params.maxTokens = 32
    params.stopAtSentenceEnd = true
    params.tau = Float(config.index.tau)
    params.k = config.index.k
    let prompt = GenerationPrompt(text: TestQuery.prompt, tokens: tokenizer.encode(TestQuery.prompt))
    let generation = try cluster.generate(prompt: prompt, params: params)
    cluster.closeLog()
    print("6 query")
    Show.generation(generation)
    let answered = generation.text.contains(TestQuery.expected)
    print(answered ? "  ✓ the answer names \(TestQuery.expected), which only the harbour log holds"
                   : "  ✗ the answer does not name \(TestQuery.expected)")

    // 7. Verify the session as `braid verify` does: hashes, shares, the gate's memory, the trace, and
    //    every span re-read from the Thread's snapshot.
    let snapshot = try CorpusSnapshot.load(from: area.thread("harbour").snapshot(hash: harbour.version.snapshotHash))
    let report = Verifier.verify(session: try SessionReader.read(sessionURL), name: sessionURL.lastPathComponent,
                                 layouts: { $0 == "harbour" ? harbour.node.index?.layout : nil },
                                 reader: SnapshotPartitionReader(snapshots: [snapshot]), tokenizer: tokenizer)
    let mismatches = report.traces.reduce(0) { $0 + $1.mismatches }
    print("7 verify    \(report.status.rawValue): \(report.issues.count) issues, \(mismatches) trace mismatches, spans \(report.spansVerified) verified, \(report.spansFailed) failed")
    print("  session   \(sessionURL.path)")
    passed = answered && report.status == .ok
} catch {
    await aii.supervisor.release()
    print("playground: \(error)")
    exit(1)
}

// 8. Let go of the playground's hold on the servers, stopping nothing. The lane and its records stay.
await aii.supervisor.release()
print("8 kept      the \(aii.app) lane and its \(harbourLog.count) records (owner \(aii.owner))")
print("  remove    Examples/run.sh forget, then aii lanes remove \(aii.app) --yes; the braid: rm -rf Examples/.work")
exit(passed ? 0 : 1)
