//
//  Chat.swift
//  BraidCLI
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: `braid chat "<prompt>"`: one headless turn of the braid, printing the per-token block the
//        studio shows. A prompt ending in "?" is a question: the commons rewrites it into a stem,
//        each Thread finds in its own index the sentence before the stem's best match and completes
//        the stem behind it, and the answer stops at the sentence's end. Any other prompt is
//        completed as written. Every turn is logged as a session; --json prints the session's lines
//        instead. Without a prompt, the studio opens (the GUI).
//

import ArgumentParser
import BraidKit
import Foundation

struct ChatCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "chat", abstract: "One turn of the braid: a completion, or a question (ending in ?) answered through the stem adapter and per-Thread context.")
    @OptionGroup var workArea: WorkAreaOptions
    @Argument(help: "The prompt; a trailing ? makes it a question. Omit it to open the studio.") var prompt: String?
    @Option(help: "Comma-separated Thread names (default: braid.toml's [cluster] attach).") var threads: String?
    @Flag(name: .customLong("no-question"), help: "Complete the prompt as written even when it ends in ?.") var noQuestion = false
    @Option var lambda: Float = 0.5
    @Option(name: .customLong("max-tokens")) var maxTokens: Int = 24
    @Option(help: "0 = likeliest token; above 0 samples.") var temperature: Float = 0
    @Flag(help: "Print the session's JSONL lines instead of the token block.") var json = false

    func run() async throws {
        guard let prompt, !prompt.trimmingCharacters(in: .whitespaces).isEmpty else {
            // No prompt: the studio, as bare `braid`.
            var ui = try UICommand.parse([])
            ui.workArea = workArea
            try await ui.run()
            return
        }
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
            settings.k = config.index.k
            let cluster = Cluster(reed: reed, tokenizer: tokenizer, pack: pack.identity, settings: settings)
            let scheme = KeyScheme(parsing: packRecord.keyScheme) ?? .residual(afterBlocks: pack.config.tapAfterBlocks)
            let commons = try ThreadStore.commons(pack: pack, scheme: scheme)
            try cluster.attach(commons)
            var nodes: [String: LocalNode] = [:]
            for name in names {
                let loaded = try ThreadStore.load(name, in: area, pack: pack, commons: commons, tau: Float(config.index.tau))
                nodes[name] = loaded.node
                try cluster.attach(loaded.node)
            }
            let isQuestion = !noQuestion && prompt.trimmingCharacters(in: .whitespaces).hasSuffix("?")
            let turn: QuestionTurn
            if isQuestion {
                // The question path the bench measures: the commons' stem, each Thread's own context.
                turn = try QuestionPath.prepare(question: prompt, adapter: QuestionAdapter(languageModule: commons.languageModule, reed: reed, tokenizer: tokenizer),
                                                nodes: names.compactMap { name in nodes[name].map { (name: name, node: $0) } }, tokenizer: tokenizer,
                                                k: config.index.k, rewriteTokens: maxTokens)
                if !json {
                    print("Q  \(prompt)")
                    if let rewrite = turn.rewrite { print("▸  \(rewrite.stem)   (\(rewrite.rewriter), \(String(format: "%.0f", rewrite.seconds * 1000)) ms)") }
                    for name in names {
                        if let found = turn.contexts[name] {
                            print("   \(name): context \(tokenizer.decode(found.tokens).debugDescription) (cos \(String(format: "%.2f", found.score)), \(found.documentID.suffix(12)))")
                        } else {
                            print("   \(name): no context (bare stem)")
                        }
                    }
                }
            } else {
                turn = QuestionTurn(question: prompt, rewrite: nil, stem: prompt, tokens: tokenizer.encode(" " + prompt), subject: nil, contexts: [:])
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
            let generation = isQuestion ? try QuestionPath.answer(turn, cluster: cluster, params: params)
                : try cluster.generate(prompt: turn.prompt, params: params)
            cluster.closeLog()
            if json {
                print(try String(contentsOf: logURL, encoding: .utf8), terminator: "")
                return
            }
            TokenBlock.print(generation, cluster: cluster, tokenizer: tokenizer)
            for decision in generation.decisions {
                let followed = decision.followed ?? (decision.tied.isEmpty ? "nobody (no chain advanced by the margin)" : "tie: " + decision.tied.joined(separator: ", "))
                print("followed: \(followed)  advances \(decision.advances.map { "\($0.key) \($0.value)" }.sorted().joined(separator: ", "))")
            }
            note("chat: session \(logURL.path)")
        }
    }
}
