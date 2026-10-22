//
//  ScaleSmokeTests.swift
//  BraidKitTests
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Step 10's scale-out smoke on the work area's Threads: six Threads and the commons in one
//        cluster, nodes advancing serially; one Thread detaches mid-answer and attaches again;
//        every step's shares sum to 1, the log replays clean (arithmetic, memory recursion, shadow,
//        traces, spans against the snapshots); and a braid of four nodes stays under 4 GB of peak
//        memory, with the active memory once the nodes are loaded printed beside it. One partition
//        of 16,384 tokens or more indexes under 1.5 GB above the loaded Thread (a 16,384-token
//        segment took 9.25 GB before the language module ran a segment 1,024 tokens at a time,
//        2026-10-19).
//

import Foundation
import MLX
import Testing
@testable import BraidKit

extension BraidMLXSuites {
    @Suite("Scale smoke", .enabled(if: mlxTests), .serialized)
    struct ScaleSmokeTests {
        static let prompt = "The article says Tillyburn was founded in"

        @Test("six Threads and the commons: a detach and a re-attach mid-answer, invariants hold, the log verifies")
        func sixThreads() throws {
            guard let (area, pack, _) = liveThread else { return }
            let names = try ThreadStore.list(in: area).map(\.name)
            guard names.count >= 6 else {
                print("SCALE: \(names.count) Threads in the work area; six are needed (braid thread create … --no-train adds one)")
                return
            }
            let chosen = Array(names.prefix(6))
            let tokenizer = try BraidTokenizer(folder: pack.tokenizerFolder)
            let cluster = Cluster(reed: pack.reed(tokens: tokenizer.vocabSize), tokenizer: tokenizer, pack: pack.identity, settings: ClusterSettings())
            let commons = try ThreadStore.commons(pack: pack, scheme: .residual(afterBlocks: pack.config.tapAfterBlocks))
            try cluster.attach(commons)
            var loaded: [String: LoadedThread] = [:]
            for name in chosen {
                let thread = try ThreadStore.load(name, in: area, pack: pack, commons: commons)
                loaded[name] = thread
                try cluster.attach(thread.node)
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("braid-scale-\(UUID().uuidString.prefix(8)).jsonl")
            defer { try? FileManager.default.removeItem(at: url) }
            try cluster.startLog(at: url)
            var params = GenerationParameters()
            params.maxTokens = 16
            let moving = chosen[1]
            var generatedSoFar = 0
            let started = Date()
            let generation = try cluster.generate(prompt: GenerationPrompt(text: Self.prompt, tokens: tokenizer.encode(" " + Self.prompt)), params: params) { step in
                guard step.source == .gen else { return }
                generatedSoFar += 1
                if generatedSoFar == 4 { try? cluster.detach(moving) }
                if generatedSoFar == 8, let node = loaded[moving]?.node { try? cluster.attach(node) }
            }
            cluster.closeLog()
            let seconds = Date().timeIntervalSince(started)
            let generated = generation.generated
            print(String(format: "SCALE: %d strands, %d tokens in %.1f s (%.2f s/token): %@", chosen.count + 1, generated.count, seconds, seconds / Double(max(1, generated.count)), generation.text.debugDescription))
            #expect(generated.count == 16)
            let counts: [Int] = generated.map { $0.threads?.count ?? 0 }
            let lastCount = counts.last ?? 0
            #expect(counts.contains(chosen.count), "a step with the Thread detached")
            #expect(lastCount == chosen.count + 1, "the Thread attached again")
            for step in generation.steps where step.threads != nil && step.source != .ctx {
                let sum = step.threads!.reduce(0.0) { $0 + Double($1.share) }
                #expect(abs(sum - 1) < 1e-5, "step \(step.index): shares sum to \(sum)")
                let memory = step.threads!.reduce(0.0) { $0 + Double($1.memory) }
                #expect(abs(memory - 1) < 1e-4, "step \(step.index): memory sums to \(memory)")
            }
            // The log replays clean, every strand's trace and every span included.
            let session = try SessionReader.read(url)
            var snapshots: [CorpusSnapshot] = []
            var layouts: [String: IndexLayout] = [:]
            for (name, thread) in loaded {
                layouts[name] = thread.node.index?.layout
                snapshots.append(try CorpusSnapshot.load(from: area.thread(name).snapshot(hash: thread.version.snapshotHash)))
            }
            let report = Verifier.verify(session: session, name: url.lastPathComponent, layouts: { layouts[$0] }, reader: SnapshotPartitionReader(snapshots: snapshots), tokenizer: tokenizer)
            print("SCALE: verify \(report.status) · \(report.issues.count) issues · traces \(report.traces.map { "\($0.positions)/\($0.mismatches)" }) · spans \(report.spansVerified) verified, \(report.spansFailed) failed")
            #expect(report.status == .ok, "\(report.issues.prefix(5).map(\.description)) \(report.spans.filter { $0.status != .verified }.map(\.text))")
        }

        @Test("a braid of four nodes stays under 4 GB of peak memory")
        func fourNodesMemory() throws {
            guard let (area, pack, _) = liveThread else { return }
            let names = Array(try ThreadStore.list(in: area).map(\.name).prefix(3))
            guard names.count == 3 else { return }
            Memory.clearCache()
            Memory.peakMemory = 0
            let tokenizer = try BraidTokenizer(folder: pack.tokenizerFolder)
            let cluster = Cluster(reed: pack.reed(tokens: tokenizer.vocabSize), tokenizer: tokenizer, pack: pack.identity, settings: ClusterSettings())
            let commons = try ThreadStore.commons(pack: pack, scheme: .residual(afterBlocks: pack.config.tapAfterBlocks))
            try cluster.attach(commons)
            for name in names { try cluster.attach(try ThreadStore.load(name, in: area, pack: pack, commons: commons).node) }
            // What the four nodes hold before a token moves: the pack's arrays and every node's weights, as MLX counts them.
            let loaded = Double(Memory.activeMemory) / 1_073_741_824
            var params = GenerationParameters()
            params.maxTokens = 16
            _ = try cluster.generate(prompt: GenerationPrompt(text: Self.prompt, tokens: tokenizer.encode(" " + Self.prompt)), params: params)
            let peak = Double(Memory.peakMemory) / 1_073_741_824
            print(String(format: "SCALE: four nodes, active memory %.2f GB once loaded, peak memory %.2f GB over 16 tokens", loaded, peak))
            #expect(peak <= 4, "peak \(peak) GB")
        }

        @Test("one partition of 16,384 tokens or more indexes under 1.5 GB of peak memory above the loaded Thread")
        func longPartitionMemory() throws {
            guard let (area, pack, loaded) = liveThread else { return }
            let tokenizer = try BraidTokenizer(folder: pack.tokenizerFolder)
            let snapshot = try CorpusSnapshot.load(from: area.thread(loaded.info.name).snapshot(hash: loaded.version.snapshotHash))
            // The Thread's text run together with no blank line: one document, one partition, one segment.
            let text = snapshot.documents.flatMap(\.partitions).map(\.text).joined(separator: " ")
            let repeats = 16_384 / max(1, tokenizer.encode(text).count) + 1
            let long = SnapshotDocument(id: "long", name: "long", ownerID: snapshot.owner, groupID: snapshot.group, groupLabel: "", createdAt: 0, mediaType: "text/plain",
                                        partitions: [SnapshotPartition(index: 0, text: Array(repeating: text, count: repeats).joined(separator: " "))])
            let corpus = TokenizedCorpus(snapshot: CorpusSnapshot(documents: [long], slug: snapshot.slug, source: snapshot.source, threadID: snapshot.threadID, owner: snapshot.owner,
                                                                  group: snapshot.group, documentIDPrefix: snapshot.documentIDPrefix),
                                         tokenizer: tokenizer, paragraphBreak: tokenizer.paragraphBreak, threadID: loaded.info.threadID)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("braid-long-\(UUID().uuidString.prefix(8))", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            Memory.clearCache()
            Memory.peakMemory = 0
            let before = Memory.activeMemory
            let built = try IndexBuilder.build(languageModule: loaded.node.languageModule, reed: pack.reed(tokens: tokenizer.vocabSize), corpus: corpus, pack: pack, blocksSHA256: loaded.version.blocksSHA256,
                                               threadID: loaded.info.threadID, options: IndexBuildOptions(scheme: loaded.version.keyScheme), into: directory)
            let peak = Double(Memory.peakMemory - before) / 1_073_741_824
            let tokens = corpus.partitions[0].tokens.count
            print(String(format: "SCALE: one %d-token partition indexed, %d entries, peak memory %.2f GB above the loaded Thread, evalLoss %.4f, evalEntropy %.4f",
                         tokens, built.info.count, peak, built.info.evalLoss, built.info.evalEntropy))
            #expect(tokens >= 16_384 && built.info.count == tokens - 1 && built.info.evalEntropy.isFinite)
            #expect(peak <= 1.5, "peak \(peak) GB")
            Memory.clearCache()
        }
    }
}
