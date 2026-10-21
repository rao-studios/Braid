//
//  RaoLMImport.swift
//  BraidCore
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: One RaoLM generation record becomes one Braid session log (`source: raolm`): the header
//        names RaoLM's strands and pack, the generation line its prompt and parameters, and every
//        trace becomes a `tok` line whose per-strand records carry RaoLM's memory, gate, open set,
//        p_lm, H_lm, share and trajectory, with each strand's own hits taken from the pooled
//        neighbours (global entries mapped back to the node's). What RaoLM never logged is derived
//        here and said so (`fieldNotes`): w′ from the gate and the open set, p_knn and H_knn from
//        the strand's hits and τ, the shadow β4 from the memory and the trace.
//  PIN:  Pure: no model. RaoLM scores a text with no eos opener, so step 0 is the text's first token
//        (no strands) and step i is RaoLM's trace i, whose hits predicted token i and whose chain
//        state followed tokens 0..<i. A Thread strand's hits are missing from a record wherever
//        RaoLM's mixture gave its retrieval no weight (its gate underflowed to 0, or it was not
//        asked); such a record logs no hits for it, and p_knn from what the strand alone gave the
//        token instead.
//

import Foundation

/// One RaoLM record as a Braid session, before or after it is written.
public struct ImportedSession: Sendable {
    public var header: SessionHeader
    public var gen: GenerationLine
    public var steps: [Step]
    public var partitions: [PartitionRef]
    public var text: String
    public var generated: Int
    public var stoppedOn: StopReason?
    /// Thread strand-positions whose hits the record lacks.
    public var missingHits: Int

    /// The generation's body lines as SessionWriter writes them, and the end line's hash of them.
    public func bodyLines() throws -> [String] { try [JSONCoding.line(gen)] + steps.map { try JSONCoding.line($0) } }

    func endLine(bodySHA256: String) -> EndLine {
        EndLine(generationID: gen.generationID, tokens: gen.prompt.tokens.count + generated, generated: generated, stoppedOn: stoppedOn, text: text,
                partitions: partitions, bodySHA256: bodySHA256)
    }

    /// The session as SessionReader reads it back from the file `write` makes.
    public func logged() throws -> LoggedSession {
        let hash = ContentHash.sha256Hex(try bodyLines().map { $0 + "\n" }.joined())
        let generation = LoggedGeneration(gen: gen, steps: steps, end: endLine(bodySHA256: hash), membership: [], bodySHA256: hash)
        return LoggedSession(header: header, generations: [generation], membership: [])
    }

    public func write(to url: URL) throws {
        let writer = try SessionWriter(url: url, header: header)
        defer { writer.close() }
        try writer.begin(gen)
        for step in steps { try writer.append(step) }
        try writer.end(generationID: gen.generationID, tokens: gen.prompt.tokens.count + generated, generated: generated, stoppedOn: stoppedOn, text: text,
                       partitions: partitions)
    }
}

public enum RaoLMImport {
    public static let source = "raolm"

    public enum Failure: Error, CustomStringConvertible {
        case notBraided(String)
        case strands(String)

        public var description: String {
            switch self {
            case .notBraided(let id): return "\(id) is not a braided RaoLM generation (no braid, or a gating other than braided)"
            case .strands(let detail): return "RaoLM record: \(detail)"
            }
        }
    }

    // MARK: - Strands and hits

    /// Per strand, its global entries: from its entryOffset to the next strand's (the last to the end
    /// of `counts` when known). The commons retrieves nothing, so its range holds no neighbour.
    public static func entryRanges(_ braid: RaoLMBraid, counts: [String: Int] = [:]) -> [Range<Int>] {
        braid.strands.map { strand in
            if strand.isCommons { return strand.entryOffset..<strand.entryOffset }
            if let count = counts[strand.name] { return strand.entryOffset..<(strand.entryOffset + count) }
            let next = braid.strands.map(\.entryOffset).filter { $0 > strand.entryOffset }.min() ?? Int.max
            return strand.entryOffset..<next
        }
    }

    /// Per strand, the hits RaoLM pooled at this trace, node-local (entry and cited row less the
    /// strand's offsets) and in the node's own order (score descending, then entry ascending, as
    /// RaoLM's index query sorts them). Nil for a Thread strand the record holds none of; empty for
    /// the commons.
    public static func hits(_ trace: RaoLMTrace, braid: RaoLMBraid, ranges: [Range<Int>]) -> [[Hit]?] {
        var byStrand = [[RaoLMNeighbour]](repeating: [], count: braid.strands.count)
        for neighbour in trace.neighbours {
            guard let t = ranges.firstIndex(where: { $0.contains(neighbour.entry) }) else { continue }
            byStrand[t].append(neighbour)
        }
        return braid.strands.indices.map { t -> [Hit]? in
            let strand = braid.strands[t]
            if strand.isCommons { return [] }
            guard !byStrand[t].isEmpty else { return nil }
            return byStrand[t]
                .sorted { $0.score != $1.score ? $0.score > $1.score : $0.entry < $1.entry }
                .map { n in
                    Hit(entry: Int32(n.entry - strand.entryOffset), score: n.score, value: Int32(n.value), row: Int32(n.cited.row - strand.rowOffset),
                        offset: Int32(n.cited.offset), loss: n.sourceLoss)
                }
        }
    }

    /// RaoLM's trajectory as Braid's trace state: the length and where the chain sits; the trace
    /// re-read from the length by `rule` (RaoLM's umbrella did the same); no partition-bounded run
    /// (RaoLM kept none).
    public static func traceState(_ trajectory: RaoLMTrajectory?, rule: TraceRule = .standard) -> TraceState? {
        guard let trajectory else { return nil }
        return TraceState(length: trajectory.length, trace: rule.trace(length: trajectory.length), entry: trajectory.entry.map { Int32($0) },
                          row: trajectory.at.map { Int32($0.row) }, offset: trajectory.at.map { Int32($0.offset) }, next: trajectory.next.map { Int32($0) },
                          partitionRun: 0)
    }

    /// λ_t: the request's λ for a Thread, 0 for the commons (RaoLM's lambdaScale; no calibration rides in a record).
    public static func lambdas(_ g: RaoLMGeneration, braid: RaoLMBraid) -> [Double] {
        braid.strands.map { $0.isCommons ? 0 : Double(g.params.lambda) }
    }

    // MARK: - The session

    /// The pack a RaoLM braid ran: its umbrella pack's sha, vocabulary and tokenizer, and, when the
    /// data root holds the umbrella (`umbrella/<sha12>/vocabulary.json`, `pack.json`), its name,
    /// hidden size and vocabulary size (0 when it does not).
    public static func pack(_ g: RaoLMGeneration, dataRoot: URL?) -> PackIdentity {
        struct Vocabulary: Decodable { var hiddenSize: Int; var vocabSize: Int }
        struct PackRecord: Decodable { var name: String }
        let braid = g.braid
        let sha = braid?.packSHA256
        var hidden = 0, vocabulary = 0
        var name: String?
        if let dataRoot, let sha {
            let directory = dataRoot.appendingPathComponent("umbrella", isDirectory: true).appendingPathComponent(String(sha.prefix(12)), isDirectory: true)
            if let v = try? JSONCoding.read(Vocabulary.self, from: directory.appendingPathComponent("vocabulary.json")) {
                hidden = v.hiddenSize
                vocabulary = v.vocabSize
            }
            name = (try? JSONCoding.read(PackRecord.self, from: directory.appendingPathComponent("pack.json")))?.name
        }
        return PackIdentity(sha256: sha, name: name, vocabularySHA256: braid?.vocabularySHA256 ?? "", tokenizerSHA256: g.manifest.tokenizerSHA256,
                            hiddenSize: hidden, vocabulary: vocabulary)
    }

    /// RaoLM's braided gate in Braid's settings: the evidence floor and ceiling, the share and
    /// credibility rates, the commons prior and the open floor carry over; agreement, the trajectory
    /// term, asking by manner, generated evidence and the share mode have no Braid setting (the
    /// import report lists them per arm).
    public static func gateSettings(_ braid: RaoLMBraid) -> GateSettings {
        var settings = GateSettings()
        if let gate = braid.gate {
            settings.evidenceFloor = decimal(gate.evidenceFloor)
            settings.evidenceCeiling = decimal(gate.evidenceCeiling)
            settings.shareRate = decimal(gate.shareRate)
            settings.credibilityRate = decimal(gate.credibilityRate)
            settings.commonsPrior = gate.commonsPrior.map(decimal) ?? 0.9
        }
        settings.openFloor = decimal(braid.gateFloor)
        settings.evidence = braid.strands.contains(where: \.isCommons) ? .lift : .absolute
        return settings
    }

    /// A RaoLM Float setting as the decimal it was written as (0.3, not 0.30000001192092896), so a
    /// constant RaoLM and Braid share reads as the same number and names the same gate fingerprint.
    static func decimal(_ value: Float) -> Double { Double("\(value)") ?? Double(value) }

    /// The strands as the session header names them.
    public static func threads(_ g: RaoLMGeneration, braid: RaoLMBraid, pack: PackIdentity) -> [SessionThread] {
        let lambdas = lambdas(g, braid: braid)
        return braid.strands.enumerated().map { t, strand in
            let nonEmpty: (String) -> String? = { $0.isEmpty ? nil : $0 }
            let address = strand.address.map { $0.hasPrefix("urn:rao:thread:") ? String($0.dropFirst("urn:rao:thread:".count)) : $0 }
            let descriptor = NodeDescriptor(
                name: strand.name, label: strand.label, kind: strand.isCommons ? .commons : .thread, vocabularySHA256: braid.vocabularySHA256,
                packSHA256: strand.isCommons ? nil : braid.packSHA256, hiddenSize: pack.hiddenSize, tokenizerSHA256: strand.manifest.tokenizerSHA256,
                indexSHA256: strand.isCommons ? nil : nonEmpty(strand.manifest.indexSHA256), checkpointsSHA256: nil, versionSHA256: address,
                corpusHash: nonEmpty(strand.manifest.corpusHash), threadID: strand.threadID, lane: nil, lambdaScale: strand.isCommons ? 0 : 1,
                tau: g.params.tau)
            return SessionThread(descriptor: descriptor, lambda: Float(lambdas[t]), rowOffset: strand.rowOffset, rowCount: strand.rowCount)
        }
    }

    /// A session id that names the record: the same record imports to the same id.
    public static func sessionID(set: String, file: String, generationID: String) -> String {
        String(ContentHash.sha256Hex("raolm-import|\(set)|\(file)|\(generationID)").prefix(32))
    }

    /// The whole record as a session. `rule` is the trace rule the log names (RaoLM's standard).
    public static func session(_ g: RaoLMGeneration, sessionID: String, pack: PackIdentity, ranges: [Range<Int>]? = nil,
                               rule: TraceRule = .standard) throws -> ImportedSession {
        guard let braid = g.braid, braid.gating == nil || braid.gating == "braided" else { throw Failure.notBraided(g.generationID) }
        guard !braid.strands.isEmpty else { throw Failure.strands("\(g.generationID) names no strands") }
        let commonsIndex = braid.strands.firstIndex(where: \.isCommons)
        let ranges = ranges ?? entryRanges(braid)
        let gate = gateSettings(braid)
        let threads = threads(g, braid: braid, pack: pack)
        let header = SessionHeader(sessionID: sessionID, createdAt: g.createdAt, source: source, pack: pack, gate: gate, trace: rule, module: nil,
                                   hitsLogged: g.params.k, threads: threads)
        var params = GenerationParameters()
        params.lambda = g.params.lambda
        params.tau = g.params.tau
        params.k = g.params.k
        params.temperature = g.params.temperature
        params.topK = g.params.topK
        params.seed = g.params.seed
        params.maxTokens = g.params.maxTokens
        let prompt = GenerationPrompt(text: g.prompt.text, tokens: g.prompt.tokens.map { Int32($0) })
        let gen = GenerationLine(generationID: g.generationID, prompt: prompt, context: nil, params: params, strands: braid.strands.map(\.name))
        let lambdas = lambdas(g, braid: braid)
        let taus = threads.map { Double($0.tau) }

        var steps: [Step] = []
        if let first = (g.prompt.tokens + g.tokens).first {
            steps.append(Step(index: 0, token: Int32(first), text: g.prompt.tokenTexts?.first ?? "", source: .prompt, prob: 1, lambda: g.params.lambda, threads: nil))
        }
        var missing = 0
        for trace in g.traces {
            guard let shares = trace.strands, shares.count == braid.strands.count else {
                throw Failure.strands("trace \(trace.index) of \(g.generationID) has \(trace.strands?.count ?? 0) strands for \(braid.strands.count)")
            }
            let y = trace.token
            let gates = shares.map { Double($0.gate) }
            let open = shares.map(\.open)
            let weights = Gate.renormalised(gates, open: open)
            let hits = hits(trace, braid: braid, ranges: ranges)
            let states = shares.map { traceState($0.trajectory, rule: rule) }
            // The shadow β4 Braid logs beside its live gate, here over RaoLM's memory and trace.
            let memory = shares.map { Double($0.memory ?? $0.gate) }
            let shadowGates = Gate.shadowWeights(GateState(memoryOnly: memory, commons: commonsIndex), traces: states.map { Double($0?.trace ?? 0) },
                                                 beta: gate.shadowBeta)
            let shadowWeights = Gate.renormalised(shadowGates, open: open)
            let alone = shares.map { $0.alone.map(Double.init) }
            let shadowP = shares.indices.reduce(0.0) { $0 + (open[$1] ? shadowWeights[$1] * (alone[$1] ?? 0) : 0) }
            var records: [ThreadRecord] = []
            for t in shares.indices {
                let share = shares[t]
                let own = hits[t]
                if own == nil { missing += 1 }
                let knnWeights = Mixer.weights((own ?? []).map { Double($0.score) }, tau: taus[t])
                var knn: [Int32: Double] = [:]
                for (i, hit) in (own ?? []).enumerated() { knn[hit.value, default: 0] += knnWeights[i] }
                var pknn = knn[Int32(y)] ?? 0
                if own == nil, lambdas[t] > 0, let p = share.alone, let plm = share.lmProb {
                    pknn = min(max((Double(p) - (1 - lambdas[t]) * Double(plm)) / lambdas[t], 0), 1)
                }
                let shadowShare = shadowP > 0 && open[t] ? shadowWeights[t] * (alone[t] ?? 0) / shadowP : 0
                records.append(ThreadRecord(
                    memory: Float(memory[t]), weight: Float(weights[t]), open: share.open, plm: share.lmProb, pknn: Float(pknn), share: share.share,
                    hlm: share.lmEntropy, hknn: Float(Mixer.entropy(knn.values)), shadowGate: Float(shadowGates[t]), shadowShare: Float(shadowShare),
                    hits: Array((own ?? []).prefix(g.params.k)), trace: states[t], gate: share.gate))
            }
            let candidates = (trace.candidates ?? []).map { Candidate(token: Int32($0.token), text: $0.text, prob: $0.prob, parts: $0.parts) }
            steps.append(Step(index: trace.index, token: Int32(y), text: trace.text, source: trace.isPrompt ? .prompt : .gen, prob: trace.mixedProb,
                              lambda: trace.lambda, threads: records, candidates: candidates))
        }
        let stoppedOn: StopReason? = g.stoppedOnEOS ? .eos : (g.params.maxTokens > 0 && g.tokens.count >= g.params.maxTokens ? .max : nil)
        return ImportedSession(header: header, gen: gen, steps: steps, partitions: g.partitions.map(\.partitionRef), text: g.text, generated: g.tokens.count,
                               stoppedOn: stoppedOn, missingHits: missing)
    }

    // MARK: - What maps where

    public struct FieldNote: Codable, Sendable, Equatable {
        /// RaoLM's field, as its record names it.
        public var raolm: String
        /// The Braid field it becomes, or nil when it has none.
        public var braid: String?
        public var note: String
    }

    /// Every RaoLM field of a record and what the import does with it; then every Braid field RaoLM
    /// never logged and how the import fills it.
    public static let fieldNotes: [FieldNote] = [
        // The record.
        FieldNote(raolm: "generationID", braid: "gen.generationID", note: "kept: RaoLM's id"),
        FieldNote(raolm: "createdAt", braid: "header.createdAt", note: "kept"),
        FieldNote(raolm: "version", braid: nil, note: "RaoLM's record version (1); the log is session schema \(BraidVersion.sessionSchema)"),
        FieldNote(raolm: "manifest", braid: nil, note: "the braid's combined manifest (runID braid:…, a combined index and corpus hash): no Braid field; each strand's own manifest maps per strand"),
        FieldNote(raolm: "prompt.text, prompt.tokens", braid: "gen.prompt", note: "kept; RaoLM scored the text with no eos opener, so step 0 is its first token"),
        FieldNote(raolm: "prompt.tokenTexts", braid: "tok.txt", note: "the first token's text goes on step 0; the rest ride on their traces"),
        FieldNote(raolm: "prompt.source, prompt.question", braid: nil, note: "not decoded: the trajectory bench sets neither"),
        FieldNote(raolm: "params.lambda, tau, k, temperature, topK, seed, maxTokens", braid: "gen.params", note: "kept"),
        FieldNote(raolm: "params.rankThreshold, minSpanLength", braid: nil, note: "RaoLM's span settings: Braid's spans are a derived view with its own settings"),
        FieldNote(raolm: "params.tapLayer, alpha", braid: nil, note: "RaoLM's key (tap layer and its mix with the final norm): Braid's key is the Mamba residual"),
        FieldNote(raolm: "tokens, text, stoppedOnEOS", braid: "end.generated, end.text, end.stoppedOn", note: "kept (the trajectory bench generates nothing)"),
        FieldNote(raolm: "partitions", braid: "end.partitions", note: "kept: the global rows the traces touch (thread partition id dropped: Braid has none)"),
        FieldNote(raolm: "spans, summary", braid: nil, note: "not decoded: spans, citations and the summary are derived views in Braid (Spans.annotate)"),
        // The braid.
        FieldNote(raolm: "braid.strands[].name, label, threadID, rowOffset, rowCount, commons", braid: "header.threads[]", note: "kept"),
        FieldNote(raolm: "braid.strands[].entryOffset", braid: nil, note: "used to map pooled global entries back to the node's own; not logged (Braid's hits are node-local)"),
        FieldNote(raolm: "braid.strands[].manifest.indexSHA256, corpusHash, tokenizerSHA256", braid: "header.threads[].indexSHA256, corpusHash; pack.tokenizerSHA256", note: "kept (the commons' empty ones as nil)"),
        FieldNote(raolm: "braid.strands[].address", braid: "header.threads[].versionSHA256", note: "the hex of urn:rao:thread:<sha256 of the version's manifest body>"),
        FieldNote(raolm: "braid.strands[].manifest.checkpointSHA256, runID, epoch, ledgerSHA256; version; ownerKey", braid: nil, note: "listed per node in the import report: Braid's checkpointSHA256 names an index's state checkpoints, not a Thread's weights; epoch and version locate the RaoLM index"),
        FieldNote(raolm: "braid.vocabularySHA256, packSHA256", braid: "header.pack", note: "kept; the pack's name, hidden size and vocabulary come from <dataRoot>/umbrella/<sha12>/ when present"),
        FieldNote(raolm: "braid.gate.evidenceFloor, evidenceCeiling, shareRate, credibilityRate, commonsPrior; braid.gateFloor", braid: "header.gate", note: "kept (gateFloor as openFloor); evidence is lift with a commons"),
        FieldNote(raolm: "braid.gate.agreement, credibility, share, generatedEvidence, trajectory, trajectoryBeta, ask, askFloor, thoughtAgreement; braid.gating", braid: nil, note: "RaoLM's gate switches (which arm made the record): no Braid setting; listed per set in the import report. Braid's gate fingerprint therefore does not tell RaoLM's arms apart"),
        // A trace.
        FieldNote(raolm: "traces[].index, token, text, isPrompt", braid: "tok.i, tok, txt, src", note: "kept: step i is trace i"),
        FieldNote(raolm: "traces[].mixedProb", braid: "tok.p", note: "kept"),
        FieldNote(raolm: "traces[].lambda", braid: "tok.lam", note: "kept: Σ w′_t·λ_t"),
        FieldNote(raolm: "traces[].candidates", braid: "tok.cand", note: "kept"),
        FieldNote(raolm: "traces[].lmEntropy, mixedEntropy, knnEntropy, sourceEntropy, threadEntropy, agreement", braid: nil, note: "mixture-level views (the mixture's reed and retrieval entropies, its p_knn of the token, the gate's spread): derived in Braid, not stored"),
        FieldNote(raolm: "traces[].citations, uncited, confidence, spanIndex, role, bits, followed", braid: nil, note: "citations, spans, token roles and followed credit are derived views in Braid (Spans, TokenRoles, FollowedCredit)"),
        FieldNote(raolm: "traces[].neighbours[]", braid: "tok.thr[t].hits", note: "split by strand by global entry; entry and cited row less the strand's offsets; ordered score desc, entry asc; sourceLoss as the hit's loss"),
        FieldNote(raolm: "traces[].neighbours[].rank, weight, matches, key, sourceEntropy", braid: nil, note: "the pooled rank and weight, the match flag and the key position are derivable (the key from the node's index); the eval entropy has no Braid field"),
        // A strand at a trace.
        FieldNote(raolm: "strands[].memory", braid: "thr.mem", note: "kept: the braided gate's memory"),
        FieldNote(raolm: "strands[].gate", braid: "thr.g", note: "kept: the gate the mixture renormalised (memory lifted by agreement, times the trace term in the β arms)"),
        FieldNote(raolm: "strands[].open", braid: "thr.open", note: "kept: asked and mixed"),
        FieldNote(raolm: "strands[].lmProb, lmEntropy", braid: "thr.plm, Hlm", note: "kept"),
        FieldNote(raolm: "strands[].share", braid: "thr.share", note: "kept"),
        FieldNote(raolm: "strands[].knn", braid: nil, note: "w′_t·p_knn,t(y), not p_knn: derivable as w′·p_knn"),
        FieldNote(raolm: "strands[].alone", braid: nil, note: "p_t(y) = λ_t·p_knn + (1−λ_t)·p_lm: Braid recomputes it from plm, pknn and λ_t; used for p_knn where the hits are missing"),
        FieldNote(raolm: "strands[].trajectory.length, entry, at, next", braid: "thr.tr.L, e, row, off, nx", note: "kept (node-local); tr.tr re-read from the length by the standard rule, as RaoLM's umbrella did"),
        FieldNote(raolm: "strands[].trajectory.trace", braid: nil, note: "the node's own trace: equal to the rule's on the length (counted by --check)"),
        FieldNote(raolm: "strands[].trajectory.phase, fit, arc, manner", braid: nil, note: "manner: deleted in Braid"),
        FieldNote(raolm: "strands[].backs, thought", braid: nil, note: "RaoLM's agreement and thought lifts: inside thr.g, no Braid field"),
        FieldNote(raolm: "strands[].lift", braid: nil, note: "log p_t − log p_commons: derived in Braid"),
        FieldNote(raolm: "strands[].credit", braid: nil, note: "RaoLM's token-role credit: a derived view in Braid (Credit.assign)"),
        FieldNote(raolm: "strands[].bestScore, threadID, strand", braid: nil, note: "the best score is the first hit's; the name and thread id are the header's"),
        // Braid fields RaoLM never logged.
        FieldNote(raolm: "—", braid: "thr.w", note: "derived: the gate renormalised over the open strands"),
        FieldNote(raolm: "—", braid: "thr.pknn", note: "derived: softmax(score/τ) mass of the strand's own hits on the token; where the record lacks the hits, (alone − (1−λ)·plm)/λ"),
        FieldNote(raolm: "—", braid: "thr.Hknn", note: "derived: the entropy of the strand's own retrieval distribution from its hits and τ; 0 where the record lacks the hits"),
        FieldNote(raolm: "—", braid: "thr.sg, thr.ss", note: "derived: Braid's shadow β4 (memory·exp(β·(trace − mean)), renormalised over the open strands) over RaoLM's memory and trace; RaoLM ran no shadow"),
        FieldNote(raolm: "—", braid: "thr.ev, thr.mod", note: "nil: RaoLM logged no bounded evidence and had no trajectory module"),
        FieldNote(raolm: "—", braid: "thr.tr.pr", note: "0: RaoLM kept no partition-bounded run"),
        FieldNote(raolm: "—", braid: "header.hitsLogged", note: "params.k: RaoLM pooled every hit of an open strand"),
    ]
}
