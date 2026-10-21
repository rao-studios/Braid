//
//  RaoLMPortTests.swift
//  BraidCoreTests
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The RaoLM import and the port validation on a tiny synthetic CitedGeneration: two Threads
//        and the commons, a text that follows Thread a's document and jumps once, every number
//        written the way RaoLM's umbrella writes it (pooled neighbours with global entries, w′·p_knn
//        as `knn`, shares from the gate). The import must replay clean under `braid verify`, check
//        (a) must recompute the shares, check (b) must replay the chains over the node's layout,
//        and a record that lacks a strand's hits (its gate 0) must count as unreplayable, not
//        failed. Also the safetensors reader and the RaoLM index loader, from files.
//

import Foundation
import Testing
@testable import BraidCore

/// A RaoLM braid with no model: Thread a holds one document (tokens 100…139), Thread b one
/// (200…229), and the commons. The text is a's tokens 100…114 then 125…139: it follows a's document,
/// jumps ten tokens, and follows it again, so a chain must be seeded again after the jump.
struct SyntheticRaoLM {
    static let lambda = 0.5
    static let tau = 0.05
    static let k = 4
    let text: [Int] = Array(100...114) + Array(125...139)
    /// Per strand: entries in its own index, its global entry and row offsets.
    let counts = [39, 29]
    let entryOffsets = [0, 39, 68]
    let rowOffsets = [0, 1, 2]
    /// Trace indices at which a strand's gate is 0 (RaoLM pools none of its hits there).
    var zeroGate: [Int: Set<Int>] = [1: [10]]

    var layoutA: IndexLayout {
        IndexLayout(values: (0..<39).map { Int32(101 + $0) }, keyRow: (0..<39).map { _ in 0 }, keyOffset: (0..<39).map { Int32($0) },
                    partitions: [PartitionRef(row: 0, documentID: "doc-a", documentName: "A", partitionIndex: 0, textSHA256: "sha-a", tokenCount: 40)], breakLength: 0)
    }

    var layoutB: IndexLayout {
        IndexLayout(values: (0..<29).map { Int32(201 + $0) }, keyRow: (0..<29).map { _ in 0 }, keyOffset: (0..<29).map { Int32($0) },
                    partitions: [PartitionRef(row: 0, documentID: "doc-b", documentName: "B", partitionIndex: 0, textSHA256: "sha-b", tokenCount: 30)], breakLength: 0)
    }

    var layouts: [String: IndexLayout] { ["a": layoutA, "b": layoutB] }

    /// Strand t's own hits at text position j (they predict token j + 1): (entry, score), score descending.
    func hits(_ t: Int, at j: Int) -> [(entry: Int, score: Float)] {
        if t == 0 {
            // a's best hit expects the text's next token: entry e's value is 101 + e.
            let next = j + 1 < text.count ? text[j + 1] : text[j] + 1
            let e = min(max(next - 101, 0), 38)
            return [(e, 0.95), ((e + 7) % 39, 0.6), ((e + 13) % 39, 0.5), ((e + 21) % 39, 0.4)]
        }
        return [((j + 3) % 29, 0.7), ((j + 11) % 29, 0.65), ((j + 17) % 29, 0.3), ((j + 23) % 29, 0.2)]
    }

    /// The record as RaoLM writes it.
    func json(tamper: ((inout [[String: Any]]) -> Void)? = nil) throws -> Data {
        let names = ["a", "b", "commons"]
        let lambdas = [Self.lambda, Self.lambda, 0]
        // Trajectories as the node computes them: from every hit, whatever the gate.
        let rule = TraceRule.standard
        var trackers = [TraceTracker(corpus: layoutA.corpus), TraceTracker(corpus: layoutB.corpus)]
        var traces: [[String: Any]] = []
        for k in 1..<text.count {
            let j = k - 1
            let y = text[k]
            var gates = [min(0.2 + 0.02 * Double(k), 0.6), 0.1, 0]
            for (t, ks) in zeroGate where ks.contains(k) { gates[t] = 0 }
            gates[2] = 1 - gates[0] - gates[1]
            let memory = [max(gates[0] - 0.01, 0), gates[1], gates[2] + min(0.01, gates[0])]
            let plm = [0.6, 0.01, 0.05]
            var pknn = [0.0, 0.0, 0.0]
            var within: [[Double]] = [[], [], []]
            for t in 0..<2 {
                let own = hits(t, at: j)
                within[t] = Mixer.weights(own.map { Double($0.score) }, tau: Self.tau)
                for (i, hit) in own.enumerated() where (t == 0 ? 101 : 201) + hit.entry == y { pknn[t] += within[t][i] }
            }
            let alone = (0..<3).map { lambdas[$0] * pknn[$0] + (1 - lambdas[$0]) * plm[$0] }
            let weights = Gate.renormalised(gates, open: [true, true, true])
            let p = (0..<3).reduce(0.0) { $0 + weights[$1] * alone[$1] }
            let l = (0..<3).reduce(0.0) { $0 + weights[$1] * lambdas[$1] }
            var pooled: [(entry: Int, score: Float, weight: Double, value: Int, row: Int, offset: Int)] = []
            for t in 0..<2 where weights[t] > 0 {
                for (i, hit) in hits(t, at: j).enumerated() {
                    let knnWeight = weights[t] * lambdas[t] / l
                    pooled.append((entryOffsets[t] + hit.entry, hit.score, knnWeight * within[t][i], (t == 0 ? 101 : 201) + hit.entry, rowOffsets[t], hit.entry))
                }
            }
            pooled.sort { $0.weight != $1.weight ? $0.weight > $1.weight : $0.entry < $1.entry }
            let neighbours: [[String: Any]] = pooled.enumerated().map { rank, n in
                ["rank": rank + 1, "entry": n.entry, "score": n.score, "weight": Float(n.weight), "value": n.value, "matches": n.value == y,
                 "key": ["row": n.row, "offset": n.offset], "cited": ["row": n.row, "offset": n.offset + 1], "sourceLoss": Float(0.01), "sourceEntropy": Float(0.1)]
            }
            var strands: [[String: Any]] = []
            for t in 0..<3 {
                var strand: [String: Any] = [
                    "strand": names[t], "gate": Float(gates[t]), "open": true, "lmProb": Float(plm[t]), "lmEntropy": Float(1 + t), "knn": Float(weights[t] * pknn[t]),
                    "share": Float(p > 0 ? weights[t] * alone[t] / p : weights[t]), "memory": Float(memory[t]), "backs": Float(0), "alone": Float(alone[t]),
                ]
                if t < 2 {
                    let own = hits(t, at: j).map { Hit(entry: Int32($0.entry), score: $0.score, value: Int32((t == 0 ? 101 : 201) + $0.entry), row: 0, offset: Int32($0.entry + 1)) }
                    let state = trackers[t].step(token: Int32(text[j]), hits: own)
                    var trajectory: [String: Any] = ["length": state.length, "trace": rule.trace(length: state.length), "fit": Float(0), "phase": Float(0)]
                    if let entry = state.entry, let row = state.row, let offset = state.offset, let next = state.next {
                        trajectory["entry"] = Int(entry)
                        trajectory["at"] = ["row": Int(row), "offset": Int(offset)]
                        trajectory["next"] = Int(next)
                    }
                    strand["trajectory"] = trajectory
                    strand["bestScore"] = own.first!.score
                    strand["lift"] = Float(log(alone[t]) - log(alone[2]))
                }
                strands.append(strand)
            }
            traces.append([
                "index": k, "token": y, "text": "<\(y)>", "isPrompt": true, "lmEntropy": Float(2), "knnEntropy": Float(1), "mixedEntropy": Float(2),
                "sourceEntropy": Float(1), "lmProb": Float(0.3), "agreement": Float(0.2), "mixedProb": Float(p), "lambda": Float(l), "neighbours": neighbours,
                "citations": [], "uncited": false, "strands": strands, "threadEntropy": Float(0.5),
                "candidates": [["token": y, "text": "<\(y)>", "prob": Float(p), "parts": (0..<3).map { Float(weights[$0] * alone[$0] / p) }]],
            ])
        }
        tamper?(&traces)
        func manifest(_ index: String, epoch: Int) -> [String: Any] {
            ["runID": "run", "epoch": epoch, "checkpointSHA256": "ck", "indexSHA256": index, "corpusHash": index.isEmpty ? "" : "corpus-" + index,
             "tokenizerSHA256": "tok", "ledgerSHA256": "ledger"]
        }
        let braidStrands: [[String: Any]] = [
            ["name": "a", "label": "A", "threadID": "T-A", "version": 1, "manifest": manifest("idx-a", epoch: 3), "rowOffset": 0, "rowCount": 1, "entryOffset": 0,
             "address": "urn:rao:thread:" + String(repeating: "a", count: 64), "ownerKey": "key-a"],
            ["name": "b", "label": "B", "threadID": "T-B", "version": 1, "manifest": manifest("idx-b", epoch: 3), "rowOffset": 1, "rowCount": 1, "entryOffset": 39],
            ["name": "commons", "label": "Commons", "version": 0, "manifest": manifest("", epoch: 0), "rowOffset": 2, "rowCount": 0, "entryOffset": 68, "commons": true],
        ]
        let record: [String: Any] = [
            "version": 1, "generationID": "gen-0123456789abcdef", "createdAt": "2026-10-15T17:27:53Z",
            "manifest": manifest("combined", epoch: 3),
            "prompt": ["text": "", "tokens": text, "tokenTexts": text.map { "<\($0)>" }],
            "params": ["lambda": Self.lambda, "tau": Self.tau, "k": Self.k, "rankThreshold": 3, "minSpanLength": 3, "temperature": 0, "topK": 0, "seed": 42,
                       "maxTokens": 0, "tapLayer": 10, "alpha": 0.5],
            "tokens": [], "text": "", "stoppedOnEOS": false,
            "partitions": [["row": 0, "documentID": "doc-a", "documentName": "A", "partitionIndex": 0, "textSHA256": "sha-a", "tokenCount": 40, "threadID": "T-A"],
                           ["row": 1, "documentID": "doc-b", "documentName": "B", "partitionIndex": 0, "textSHA256": "sha-b", "tokenCount": 30, "threadID": "T-B"]],
            "traces": traces, "spans": [], "summary": ["generated": 0, "supportOnly": 0, "uncited": 0, "verbatimCovered": 0, "verbatimSpans": 0],
            "braid": ["vocabularySHA256": "vocab", "gateFloor": 0.05, "gating": "braided", "packSHA256": "pack", "strands": braidStrands,
                      "gate": ["agreement": true, "credibility": true, "credibilityRate": 0.3, "evidenceCeiling": 0.5, "evidenceFloor": 0.05,
                               "generatedEvidence": false, "share": "variable", "shareRate": 0.1]],
        ]
        return try JSONSerialization.data(withJSONObject: record)
    }

    func generation(tamper: ((inout [[String: Any]]) -> Void)? = nil) throws -> RaoLMGeneration {
        try JSONCoding.decoder().decode(RaoLMGeneration.self, from: json(tamper: tamper))
    }

    var pack: PackIdentity { PackIdentity(sha256: "pack", name: "synthetic", vocabularySHA256: "vocab", tokenizerSHA256: "tok", hiddenSize: 8, vocabulary: 256) }

    func ranges(_ g: RaoLMGeneration) -> [Range<Int>] { RaoLMImport.entryRanges(g.braid!, counts: ["a": 39, "b": 29]) }

    func imported(_ g: RaoLMGeneration) throws -> ImportedSession {
        try RaoLMImport.session(g, sessionID: "test-session", pack: pack, ranges: ranges(g))
    }
}

@Suite("RaoLM import and the port validation")
struct RaoLMPortTests {
    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("braid-raolm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("a record imports as a session that verify replays clean: weights from the logged gate, shares, p, H_knn, the trace")
    func importReplays() throws {
        let fixture = SyntheticRaoLM()
        let g = try fixture.generation()
        let imported = try fixture.imported(g)
        #expect(imported.header.source == "raolm")
        #expect(imported.header.threads.map(\.name) == ["a", "b", "commons"])
        #expect(imported.header.threads.map(\.lambda) == [0.5, 0.5, 0])
        #expect(imported.header.threads[0].versionSHA256 == String(repeating: "a", count: 64))
        #expect(imported.header.threads[2].indexSHA256 == nil && imported.header.threads[2].commons)
        // RaoLM's Float constants read as the decimals they were written as: Braid's own gate, by fingerprint.
        #expect(imported.header.gate == GateSettings() && imported.header.gateFingerprint == GateSettings().fingerprint)
        #expect(imported.steps.count == fixture.text.count)
        #expect(imported.steps[0].threads == nil && imported.steps[0].token == 100)
        #expect(imported.missingHits == 1, "b lacks hits where its gate is 0")
        // Hits come back node-local, in the node's order; the gate rides beside a memory that is not it.
        let step = imported.steps[5]
        let records = try #require(step.threads)
        #expect(records[0].hits.map(\.entry) == fixture.hits(0, at: 4).map { Int32($0.entry) })
        #expect(records[1].hits.map(\.entry) == fixture.hits(1, at: 4).map { Int32($0.entry) })
        #expect(records[1].hits.first?.row == 0 && records[0].hits.first?.offset == Int32(fixture.hits(0, at: 4)[0].entry + 1))
        #expect(records.map(\.gate) == g.traces[4].strands!.map { Optional($0.gate) })
        #expect(records[0].memory != records[0].gate!)
        #expect(records[2].hits.isEmpty && records[2].trace == nil)
        let missing = try #require(imported.steps[10].threads)
        #expect(missing[1].hits.isEmpty && missing[1].weight == 0 && missing[1].share == 0)
        // The session verify sees.
        let session = try imported.logged()
        #expect(SessionReplay.check(session.generations[0], session: session).isEmpty)
        let report = Verifier.verify(session: session, name: "synthetic", layouts: { fixture.layouts[$0] }, reader: nil, tokenizer: nil)
        #expect(report.issues.isEmpty, "\(report.issues.map(\.description))")
        #expect(report.status == .ok)
        #expect(report.skipped == ["memory recursion", "shadow β4", "spans"])
        #expect(report.notes.contains { $0.hasPrefix("source raolm") })
        #expect(report.traces.map(\.positions) == [fixture.text.count - 1, fixture.text.count - 1])
        #expect(report.traces.allSatisfy { $0.mismatches == 0 && $0.unreplayable == 0 })
    }

    @Test("the written log reads back as the in-memory session, its body hash intact")
    func writeRoundTrip() throws {
        let fixture = SyntheticRaoLM()
        let imported = try fixture.imported(try fixture.generation())
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("record.jsonl")
        try imported.write(to: url)
        let read = try SessionReader.read(url)
        let memory = try imported.logged()
        #expect(read.header == memory.header)
        #expect(read.generations.count == 1)
        #expect(read.generations[0] == memory.generations[0])
        #expect(read.generations[0].end?.bodySHA256 == read.generations[0].bodySHA256)
        #expect(SessionReplay.check(read.generations[0], session: read).isEmpty)
    }

    @Test("a Braid log's own replay is unchanged: the memory recursion and the shadow still run")
    func braidLogsKeepEveryCheck() {
        let header = SessionHeader(sessionID: "s", pack: PackIdentity(sha256: nil, name: nil, vocabularySHA256: "v", tokenizerSHA256: "t", hiddenSize: 1, vocabulary: 1),
                                   gate: GateSettings(), trace: .standard, module: nil, hitsLogged: 16, threads: [])
        #expect(SessionReplay.skipped(for: header).isEmpty)
        var imported = header
        imported.source = "raolm"
        #expect(SessionReplay.skipped(for: imported) == ["memory recursion", "shadow β4"])
    }

    @Test("(a): shares recompute from the gate, the open set and alone, and from gate/open/lmProb/knn; a changed share fails")
    func sharesCheck() throws {
        let fixture = SyntheticRaoLM()
        let g = try fixture.generation()
        let shares = RaoLMCheck.shares(g, file: "f", ranges: fixture.ranges(g))
        #expect(shares.positions == fixture.text.count - 1 && shares.values == 3 * (fixture.text.count - 1))
        #expect(shares.maxErrorAlone < 1e-6 && shares.maxErrorLogged < 1e-6, "\(shares.maxErrorAlone) \(shares.maxErrorLogged)")
        #expect(shares.maxLambdaError < 1e-6 && shares.maxRelativeP < 1e-6)
        #expect(shares.aloneFromHits > 0 && shares.maxAloneFromHitsError < 1e-6)
        #expect(shares.passes)
        let tampered = try fixture.generation { traces in
            var strands = traces[6]["strands"] as! [[String: Any]]
            strands[0]["share"] = (strands[0]["share"] as! Float) + 1e-4
            traces[6]["strands"] = strands
        }
        let bad = RaoLMCheck.shares(tampered, file: "f", ranges: fixture.ranges(tampered))
        #expect(!bad.passes && bad.worst?.index == 7 && bad.worst?.strand == "a")
        let session = try fixture.imported(tampered).logged()
        #expect(SessionReplay.check(session.generations[0], session: session).contains { $0.check == "share" })
    }

    @Test("(b): the tracker over the node's layout reproduces every logged chain, and the pooled hits land on the node's index")
    func traceReplay() throws {
        let fixture = SyntheticRaoLM()
        let g = try fixture.generation()
        let corpora = fixture.layouts.mapValues(\.corpus)
        let replay = RaoLMCheck.replay(g, corpora: corpora, ranges: fixture.ranges(g), rule: .standard)
        let traces = RaoLMCheck.traces(g, replay: replay, set: "base", file: "f", rule: .standard)
        #expect(traces.strands["a"]?.positions == fixture.text.count - 1 && traces.strands["a"]?.matched == fixture.text.count - 1)
        #expect(traces.strands["b"]?.missingHits == 1 && traces.strands["b"]?.mismatches == 0)
        #expect(traces.passes && traces.mismatches.isEmpty)
        // The chain follows the text, breaks at the jump and is seeded again.
        let lengths = replay.states[0]!.map(\.length)
        #expect(lengths[14] == 14 && lengths[15] == 1 && lengths.last == 14, "\(lengths)")
        #expect(replay.final[0]?.length == 15 && replay.final[2] == nil)
        let mapping = RaoLMCheck.mapping(g, layouts: fixture.layouts, ranges: fixture.ranges(g), rule: .standard)
        #expect(mapping.passes && mapping.hits > 0 && mapping.chains > 0, "\(mapping)")
        // A logged length that is wrong where every hit is present fails.
        let wrong = try fixture.generation { traces in
            var strands = traces[20]["strands"] as! [[String: Any]]
            var trajectory = strands[0]["trajectory"] as! [String: Any]
            trajectory["length"] = (trajectory["length"] as! Int) + 1
            strands[0]["trajectory"] = trajectory
            traces[20]["strands"] = strands
        }
        let failed = RaoLMCheck.traces(wrong, replay: RaoLMCheck.replay(wrong, corpora: corpora, ranges: fixture.ranges(wrong), rule: .standard), set: "base", file: "f",
                                       rule: .standard)
        #expect(failed.strands["a"]?.mismatches == 1 && !failed.passes)
        let session = try fixture.imported(wrong).logged()
        let report = Verifier.verify(session: session, name: "wrong", layouts: { fixture.layouts[$0] }, reader: nil, tokenizer: nil)
        #expect(report.issues.contains { $0.check == "trace" } && report.status == .failed)
    }

    @Test("(b): where a record lacks the hits that seeded a chain, the replay's misses are unreplayable, not failures")
    func lackingHits() throws {
        var fixture = SyntheticRaoLM()
        // a's gate is 0 at trace 15, whose hits (from position 14) seed the chain after the jump.
        fixture.zeroGate = [0: [15]]
        let g = try fixture.generation()
        let replay = RaoLMCheck.replay(g, corpora: fixture.layouts.mapValues(\.corpus), ranges: fixture.ranges(g), rule: .standard)
        let traces = RaoLMCheck.traces(g, replay: replay, set: "base", file: "f", rule: .standard)
        let a = try #require(traces.strands["a"])
        #expect(a.missingHits == 1 && a.mismatches == 0)
        #expect(a.mismatchesAfterMissing > 0 && a.explained == a.mismatchesAfterMissing, "\(a)")
        #expect(traces.passes)
        #expect(traces.mismatches.first?.index == 16 && traces.mismatches.first?.missingNear == [15])
        let session = try fixture.imported(g).logged()
        let report = Verifier.verify(session: session, name: "lacking", layouts: { fixture.layouts[$0] }, reader: nil, tokenizer: nil)
        #expect(report.status == .ok, "\(report.issues.map(\.description))")
        #expect(report.traces.first { $0.strand == 0 }?.unreplayable == a.mismatchesAfterMissing)
    }

    @Test("what phase A keeps of a record: the chain after every token (the last from the tracker), the logged numbers by trace")
    func scoredText() throws {
        let fixture = SyntheticRaoLM()
        let g = try fixture.generation()
        let replay = RaoLMCheck.replay(g, corpora: fixture.layouts.mapValues(\.corpus), ranges: fixture.ranges(g), rule: .standard)
        let scored = RaoLMCheck.scoredText(g, file: "f", replay: replay, imported: try fixture.imported(g),
                                           documentOfRow: ["a": [0: "doc-a"], "b": [0: "doc-b"]])
        #expect(scored.commons == 2 && scored.strands == ["a", "b", "commons"])
        let lengths = try #require(scored.lengths[0])
        #expect(lengths.count == fixture.text.count)
        #expect(Array(lengths.dropLast()) == g.traces.map { $0.strands![0].trajectory!.length })
        #expect(lengths.last == replay.final[0]?.length)
        #expect(scored.lengths[2] == nil)
        #expect(scored.best[1][9] == nil && scored.best[1][8] != nil, "b lacks its hits at trace 10")
        #expect(scored.alone.count == g.traces.count && scored.memory[0].count == 3)
        #expect(scored.wireLongest[0] >= 13)
    }

    @Test("entry ranges and the pooled hits split by strand")
    func ranges() throws {
        let fixture = SyntheticRaoLM()
        let g = try fixture.generation()
        let braid = try #require(g.braid)
        #expect(RaoLMImport.entryRanges(braid) == [0..<39, 39..<68, 68..<68])
        #expect(RaoLMImport.entryRanges(braid, counts: ["a": 39, "b": 29]) == [0..<39, 39..<68, 68..<68])
        let hits = RaoLMImport.hits(g.traces[9], braid: braid, ranges: fixture.ranges(g))
        #expect(hits[0]?.count == 4 && hits[1] == nil && hits[2]?.isEmpty == true)
        #expect(RaoLMImport.traceState(nil) == nil)
        let state = try #require(RaoLMImport.traceState(g.traces[20].strands![0].trajectory))
        #expect(state.trace == TraceRule.standard.trace(length: state.length) && state.partitionRun == 0)
    }

    // MARK: - Files

    /// A safetensors file's bytes from (name, dtype, shape, little-endian payload).
    static func safetensors(_ tensors: [(String, String, [Int], Data)], metadata: [String: String] = ["format": "test"]) throws -> Data {
        var header: [String: Any] = ["__metadata__": metadata]
        var payload = Data()
        for (name, dtype, shape, bytes) in tensors {
            header[name] = ["dtype": dtype, "shape": shape, "data_offsets": [payload.count, payload.count + bytes.count]]
            payload.append(bytes)
        }
        let json = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        var data = Data()
        withUnsafeBytes(of: UInt64(json.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(json)
        data.append(payload)
        return data
    }

    static func bytes<T: FixedWidthInteger>(_ values: [T]) -> Data {
        var data = Data()
        for value in values { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }

    @Test("safetensors: I32, F32 and F16 (normal, subnormal, signed, infinite) read back exactly; bad ranges and dtypes are refused")
    func safetensorsReader() throws {
        let halves: [UInt16] = [0x3C00, 0xC000, 0x3800, 0x0001, 0x7BFF, 0x7C00, 0x8000, 0x0400]
        let data = try Self.safetensors([
            ("ints", "I32", [3], Self.bytes([Int32(1), -2, 300_000])),
            ("floats", "F32", [2], Self.bytes([Float(3.25).bitPattern, Float(-0.5).bitPattern])),
            ("halves", "F16", [2, 4], Self.bytes(halves)),
        ])
        let file = try SafetensorsFile(data: data)
        #expect(file.metadata["format"] == "test")
        #expect(try file.int32("ints") == [1, -2, 300_000])
        #expect(try file.float32("floats") == [3.25, -0.5])
        let widened = try file.float32("halves")
        #expect(Array(widened.prefix(3)) == [1, -2, 0.5])
        #expect(widened[3] == Float(bitPattern: 0x3380_0000) && widened[4] == 65504 && widened[5] == .infinity)
        #expect(widened[6] == 0 && widened[6].sign == .minus && widened[7] == Float(bitPattern: 0x3880_0000))
        #expect(file.tensors["halves"]?.shape == [2, 4])
        #expect(throws: SafetensorsFile.Failure.self) { try file.int32("floats") }
        #expect(throws: SafetensorsFile.Failure.self) { try file.float32("missing") }
        #expect(throws: SafetensorsFile.Failure.self) { try SafetensorsFile(data: data.prefix(data.count - 4)) }
        #expect(throws: SafetensorsFile.Failure.self) { try SafetensorsFile(data: Data([1, 2, 3])) }
        let short = try Self.safetensors([("ints", "I32", [4], Self.bytes([Int32(1), 2, 3]))])
        #expect(throws: SafetensorsFile.Failure.self) { try SafetensorsFile(data: short) }
        #expect(file.sha256 == ContentHash.sha256Hex(data))
    }

    @Test("a RaoLM index directory loads as the layout the tracker reads, and only under its own sha256")
    func indexLoads() throws {
        let fixture = SyntheticRaoLM()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = RaoLMIndex.directory(dataRoot: root, node: "a", version: 1, epoch: 3)
        #expect(directory.path.hasSuffix("nodes/a/versions/v0001/provenance/epoch-3"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let layout = fixture.layoutA
        let data = try Self.safetensors([
            ("values", "I32", [39], Self.bytes(layout.values)), ("key_row", "I32", [39], Self.bytes(layout.keyRow)),
            ("key_offset", "I32", [39], Self.bytes(layout.keyOffset)), ("keys", "F16", [39, 2], Self.bytes([UInt16](repeating: 0x3C00, count: 78))),
        ])
        try data.write(to: directory.appendingPathComponent("index.safetensors"))
        try Data(#"{"count": 39, "epoch": 3, "paragraphBreak": [9, 9]}"#.utf8).write(to: directory.appendingPathComponent("index.json"))
        try JSONCoding.lineEncoder().encode(layout.partitions.map {
            RaoLMPartition(row: $0.row, documentID: $0.documentID, documentName: $0.documentName, partitionIndex: 0, partitionURL: nil, threadPartitionID: "tp",
                           textSHA256: $0.textSHA256, tokenCount: $0.tokenCount, memorisedAtEpoch: nil, threadID: nil, createdAt: nil)
        }).write(to: directory.appendingPathComponent("partitions.json"))
        let sha = ContentHash.sha256Hex(data)
        let index = try RaoLMIndex.load(directory: directory, node: "a", expectedSHA256: sha)
        #expect(index.sha256 == sha && index.count == 39)
        #expect(index.layout.values == layout.values && index.layout.keyRow == layout.keyRow && index.layout.keyOffset == layout.keyOffset)
        #expect(index.layout.breakLength == 2 && index.layout.partitions.map(\.documentID) == ["doc-a"])
        #expect(index.documentOfRow == [0: "doc-a"])
        #expect(throws: RaoLMIndex.Failure.self) { try RaoLMIndex.load(directory: directory, node: "a", expectedSHA256: String(repeating: "0", count: 64)) }
        #expect(try RaoLMIndex.find(dataRoot: root, node: "a", sha256: sha)?.count == 39)
        #expect(try RaoLMIndex.find(dataRoot: root, node: "a", sha256: "nope") == nil)
        #expect(try RaoLMIndex.find(dataRoot: root, node: "b", sha256: sha) == nil)
    }

    @Test("the dump's sets: the base pass and each arm, an arm complete only with every told and source record")
    func sets() throws {
        let dump = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dump) }
        let texts = [
            RaoLMDumpText(file: "held-000-a.json", index: 0, kind: "held", label: "h", owner: "a", near: nil, document: "d", tokens: 3, answers: []),
            RaoLMDumpText(file: "told-001-a.json", index: 1, kind: "told", label: "t", owner: "a", near: "b", document: "d", tokens: 3,
                          answers: [RaoLMAnswer(start: 0, count: 2, text: " x")]),
        ]
        let index = RaoLMDumpIndex(createdAt: Date(timeIntervalSince1970: 0), dataRoot: "/nowhere", nodes: ["a": 1], arms: ["no agreement": "arms/no-agreement", "lift": "arms/lift"],
                                   texts: texts)
        try FileManager.default.createDirectory(at: dump.appendingPathComponent("arms/no-agreement"), withIntermediateDirectories: true)
        for file in ["held-000-a.json", "told-001-a.json", "arms/no-agreement/told-001-a.json"] { try Data("{}".utf8).write(to: dump.appendingPathComponent(file)) }
        let sets = RaoLMPort.sets(dump: dump, index: index)
        #expect(sets.map(\.name) == ["base", "lift", "no agreement"])
        #expect(sets.map(\.complete) == [true, false, true])
        #expect(sets[2].texts.map(\.file) == ["told-001-a.json"] && sets[2].outputDirectory == "arms/no-agreement")
        #expect(try RaoLMPort.select(sets, only: nil).map(\.name) == ["base", "no agreement"])
        #expect(try RaoLMPort.select(sets, only: "no-agreement").map(\.name) == ["no agreement"])
        #expect(throws: RaoLMPort.Failure.self) { try RaoLMPort.select(sets, only: "both β9") }
        #expect(texts[1].answerPositions == [1], "position 0 has no trace")
    }
}
