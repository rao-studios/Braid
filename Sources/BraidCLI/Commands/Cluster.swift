//
//  Cluster.swift
//  BraidCLI
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: `braid cluster spawn --threads a,b --prompt "…"`: the braid in this process — the commons
//        and the named Threads under one reed — one generation, every token printed as the
//        handoff's block (the chosen token, every strand's share, the trace, both entropies with
//        their one-step deltas, the citation), the royalties, and the session log's path.
//

import ArgumentParser
import BraidKit
import Foundation

struct ClusterCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "cluster", abstract: "The braid in this process.", subcommands: [Spawn.self], defaultSubcommand: Spawn.self)

    struct Spawn: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "spawn", abstract: "Assemble the named Threads and the commons, run one generation, log the session.")
        @OptionGroup var workArea: WorkAreaOptions
        @Option(help: "Comma-separated Thread names (default: braid.toml's [cluster] attach).")
        var threads: String?
        @Option(help: "The prompt to complete.")
        var prompt: String
        @Option(name: .customLong("max-tokens")) var maxTokens: Int = 24
        @Option var lambda: Float = 0.5
        @Option var temperature: Float = 0
        @Flag(name: .customLong("no-commons"), help: "Leave the commons out (the gate then uses absolute evidence).")
        var noCommons = false
        @Flag(help: "Print the generation as JSON instead of the token blocks.")
        var json = false
        @Option(help: "Attach a Thread at a generated position: name@pos (repeatable). It catches up on the session and joins at the next token boundary.")
        var attach: [String] = []
        @Option(help: "Detach a Thread at a generated position: name@pos (repeatable).")
        var detach: [String] = []

        func run() throws {
            guarded {
                let area = try workArea.resolve()
                let config = try workArea.config(in: area)
                guard let packRecord = config.pack, let pack = try Packs.find(packRecord.sha256, in: area) else { throw BraidFailure.missing("braid.toml names no pack that is on disk") }
                let names = (threads.map { $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } } ?? config.attach).filter { !$0.isEmpty }
                guard !names.isEmpty else { throw BraidFailure.usage("no Threads: pass --threads or create one") }
                let tokenizer = try BraidTokenizer(folder: pack.tokenizerFolder)
                let reed = pack.reed(tokens: tokenizer.vocabSize)
                var settings = ClusterSettings()
                settings.gate = config.gate
                if noCommons { settings.gate.evidence = .absolute }
                settings.k = config.index.k
                let cluster = Cluster(reed: reed, tokenizer: tokenizer, pack: pack.identity, settings: settings)
                let scheme = KeyScheme(parsing: packRecord.keyScheme) ?? .residual(afterBlocks: pack.config.tapAfterBlocks)
                note("cluster: loading the commons")
                let commons = try ThreadStore.commons(pack: pack, scheme: scheme)
                note(String(format: "cluster: the commons' tail %@ · blocks %d–%d, the embedding and norm_f · %.0f MB · run by every Thread", String(commons.languageModule.seamSHA256.prefix(12)),
                            pack.config.cut, pack.config.numHiddenLayers - 1, Double(StorageMath(config: pack.config).tailBytes) / 1_000_000))
                if noCommons {
                    note("cluster: the commons' strand is left out; its tail still serves the Threads")
                } else {
                    try cluster.attach(commons)
                }
                for name in names {
                    note("cluster: loading \(name) · its head, blocks 0–\(pack.config.cut - 1), and its index")
                    let loaded = try ThreadStore.load(name, in: area, pack: pack, commons: commons, tau: Float(config.index.tau))
                    try cluster.attach(loaded.node)
                }
                try FileManager.default.createDirectory(at: area.sessions, withIntermediateDirectories: true)
                let logURL = area.sessions.appendingPathComponent(SessionLog.fileName(sessionID: cluster.sessionID))
                try cluster.startLog(at: logURL)
                var params = GenerationParameters()
                params.lambda = lambda
                params.maxTokens = maxTokens
                params.temperature = temperature
                params.tau = Float(config.index.tau)
                params.k = config.index.k
                let promptTokens = tokenizer.encode(prompt)
                note("cluster: \(cluster.strandNames.joined(separator: ", ")) · prompt \(promptTokens.count) tokens")
                func schedule(_ specs: [String]) throws -> [Int: [String]] {
                    var out: [Int: [String]] = [:]
                    for spec in specs {
                        let parts = spec.split(separator: "@")
                        guard parts.count == 2, let at = Int(parts[1]) else { throw BraidFailure.usage("expected name@pos, got \(spec)") }
                        out[at, default: []].append(String(parts[0]))
                    }
                    return out
                }
                let attachAt = try schedule(attach)
                let detachAt = try schedule(detach)
                cluster.onEvent = { event in
                    switch event {
                    case .attached(let name, let position, let caughtUp, let seconds): note(String(format: "cluster: %@ attached at %d (caught up %d tokens in %.2f s)", name, position, caughtUp, seconds))
                    case .detached(let name, let position): note("cluster: \(name) detached at \(position)")
                    case .step: break
                    }
                }
                var generated = 0
                let started = Date()
                let generation = try cluster.generate(prompt: GenerationPrompt(text: prompt, tokens: promptTokens), params: params) { step in
                    guard step.source == .gen else { return }
                    generated += 1
                    for name in attachAt[generated] ?? [] {
                        do {
                            let thread = try ThreadStore.load(name, in: area, pack: pack, commons: commons, tau: Float(config.index.tau))
                            try cluster.attach(thread.node)
                        } catch { note("cluster: cannot attach \(name): \(error)") }
                    }
                    for name in detachAt[generated] ?? [] {
                        do { try cluster.detach(name) } catch { note("cluster: cannot detach \(name): \(error)") }
                    }
                }
                cluster.closeLog()
                let seconds = Date().timeIntervalSince(started)
                if json {
                    print(String(decoding: try JSONCoding.prettyEncoder().encode(generation.steps), as: UTF8.self))
                } else {
                    TokenBlock.print(generation, cluster: cluster, tokenizer: tokenizer)
                }
                note(String(format: "cluster: %d tokens in %.1f s (%.2f s/token) · session %@", generation.generated.count, seconds, seconds / Double(max(generation.generated.count, 1)), logURL.path))
            }
        }
    }
}

enum TokenBlock {
    static func f(_ x: Float, _ digits: Int = 2) -> String { String(format: "%.\(digits)f", x) }

    /// The per-token block over the shared steps (context lines excluded), each step read through
    /// the strands it was recorded with, then the royalties by Thread and by document.
    static func print(_ generation: Generation, cluster: Cluster, tokenizer: any Tokenizing) {
        Swift.print("> \(generation.gen.prompt.text)▸\(generation.text)")
        let sharedIndices = generation.steps.indices.filter { generation.steps[$0].source != .ctx }
        var previous: (records: [ThreadRecord], slots: [StrandSlot])? = nil
        for (k, index) in sharedIndices.enumerated() {
            let step = generation.steps[index]
            let slots = index < generation.slots.count ? generation.slots[index] : []
            func name(_ t: Int) -> String { t < slots.count ? slots[t].name : "strand \(t)" }
            func isCommons(_ t: Int) -> Bool { t < slots.count && slots[t].commons }
            guard let records = step.threads else { continue }
            defer { previous = (records, slots) }
            guard !step.isPrompt else { continue }
            let ordered = records.indices.sorted { records[$0].share > records[$1].share }
            guard let lead = ordered.first else { continue }
            let others = ordered.dropFirst().map { "\(name($0)) \(f(records[$0].share))" }.joined(separator: ", ")
            Swift.print("  token \(step.text.debugDescription)  ← \(name(lead))  share \(f(records[lead].share))  (\(others))   p \(f(step.prob))")
            var line2 = "                    "
            if let trace = records[lead].trace, trace.length >= TraceRule.standard.phrase, let row = trace.row, lead < slots.count {
                let partition = cluster.partitions[Int(row) + slots[lead].rowOffset]
                line2 += "trace: in-doc \(partition?.documentID.suffix(12) ?? "#\(row)") L=\(trace.length)"
            } else {
                line2 += "trace: off-trace L=\(records[lead].trace?.length ?? 0)"
            }
            let before = previous.flatMap { prior -> ThreadRecord? in
                guard let t = prior.slots.firstIndex(where: { $0.name == name(lead) }), prior.records.indices.contains(t) else { return nil }
                return prior.records[t]
            }
            line2 += "  H_knn \(before.map { f($0.hknn) + "→" } ?? "")\(f(records[lead].hknn))"
            if let hlm = records[lead].hlm { line2 += "  H_lm \(before?.hlm.map { f($0) + "→" } ?? "")\(f(hlm))" }
            if !isCommons(lead) { line2 += "   (shadow β4: \(name(lead)) \(f(records[lead].shadowShare)))" }
            Swift.print(line2)
            let annotation = k < generation.annotations.count ? generation.annotations[k] : nil
            if let citation = annotation?.citations.first {
                let span = annotation?.spanIndex.map { " · span \($0 + 1)" } ?? ""
                Swift.print("                    cited: \(citation.address.documentID.suffix(16))/partition-\(citation.address.partitionIndex)@\(citation.address.tokenOffset)  conf \(f(citation.confidence))\(span)")
            } else if !isCommons(lead) {
                Swift.print("                    uncited: no retrieved context predicted this token")
            }
        }
        Swift.print("royalties (generated tokens: \(generation.royalties.generated))")
        for line in generation.royalties.strands {
            Swift.print("  \(line.name.padding(toLength: 12, withPad: " ", startingAt: 0)) led \(line.led)  share Σ \(String(format: "%.2f", line.share))  credit·bits \(String(format: "%.1f", line.credit))")
        }
        for doc in generation.royalties.documents.prefix(5) {
            Swift.print("  \(doc.name)/\(doc.documentID.suffix(16))  \(doc.tokens) tokens  share Σ \(String(format: "%.2f", doc.share))")
        }
        if !generation.spans.isEmpty { Swift.print("spans: \(generation.spans.map { "\($0.text.debugDescription) → \($0.source.documentID.suffix(12)) p\($0.source.partitionIndex)@\($0.source.tokenOffset)" }.joined(separator: "; "))") }
    }
}
