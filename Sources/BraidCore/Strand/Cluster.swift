//
//  Cluster.swift
//  BraidCore
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The braid at run time: the strands attached (Threads and the commons), the one reed,
//        the gate, and the generation loop that mixes every position, chooses, records a step and
//        advances every node. Strands attach and detach at token boundaries; a strand that joins
//        catches up on the session so far with one forward. Every generation writes the session
//        log that `braid verify` replays.
//  PIN:  The final distribution is the cluster's output, not any node's. Every number that chooses
//        a token or sets a share is Double on the CPU. Trace is computed here from the hits, so it
//        is a function of the log; the shadow β4 gate is computed and logged, never applied.
//

import Foundation

public struct ClusterSettings: Sendable {
    public var gate = GateSettings()
    public var trace = TraceRule.standard
    /// The trajectory module's settings. It runs in every session, so its e_t is logged (`mod`) beside
    /// the shadow β4 at every prompt and context position; its evidence enters the gate only when
    /// `gate.moduleGain` (κ) is above 0. Nil turns it off.
    public var module: ModuleSettings? = ModuleSettings()
    public var k = 16
    public var hitsLogged = 16
    public var candidates = 3
    public var spans = Spans.Settings()

    public init() {}
}

/// What a generation returns: the lines as logged plus the derived views.
public struct Generation: Sendable {
    public var gen: GenerationLine
    public var steps: [Step]
    public var end: EndLine
    public var strands: [SessionThread]
    public var annotations: [SpanAnnotation]
    public var spans: [CitedSpan]
    public var credits: [CreditRow?]
    public var decisions: [FollowDecision]
    public var royalties: RoyaltiesView
    /// Per step (aligned with `steps`), the strands its records are in.
    public var slots: [[StrandSlot]] = []

    public var text: String { end.text }
    public var generated: [Step] { steps.filter { !$0.isPrompt } }
}

public enum ClusterEvent: Sendable {
    case attached(name: String, position: Int, caughtUp: Int, seconds: Double)
    case detached(name: String, position: Int)
    case step(Step)
}

public enum ClusterError: Error, CustomStringConvertible {
    case duplicate(String)
    case unknown(String)
    case commonsTwice
    case noStrands

    public var description: String {
        switch self {
        case .duplicate(let name): return "a strand named \(name) is already attached"
        case .unknown(let name): return "no strand named \(name)"
        case .commonsTwice: return "a braid has one commons"
        case .noStrands: return "no strands attached"
        }
    }
}

public final class Cluster {
    struct Member {
        var node: any Node
        var descriptor: NodeDescriptor
        var layout: IndexLayout?
        var corpus: TraceCorpus?
        var rowOffset: Int
        var tau: Double
        var lambdaScale: Double
        var record: SessionThread
    }

    private enum Pending { case attach(any Node), detach(String) }

    public let reed: any Reed
    public let tokenizer: any Tokenizing
    public let pack: PackIdentity
    public var settings: ClusterSettings
    var members: [Member] = []
    public private(set) var writer: SessionWriter?
    public let sessionID: String
    public var onEvent: ((ClusterEvent) -> Void)?

    private var pending: [Pending] = []
    private let lock = NSLock()
    private var partitionTable: [Int: PartitionRef] = [:]
    private var sharedNgrams: Set<UInt64> = []
    private var nextRow = 0
    private var cancelled = false

    public init(reed: any Reed, tokenizer: any Tokenizing, pack: PackIdentity, settings: ClusterSettings = ClusterSettings(), sessionID: String = SessionLog.newSessionID()) {
        self.reed = reed
        self.tokenizer = tokenizer
        self.pack = pack
        self.settings = settings
        self.sessionID = sessionID
    }

    public var strandNames: [String] { members.map(\.descriptor.name) }
    public var commonsIndex: Int? { members.firstIndex { $0.descriptor.isCommons } }
    public var strandRecords: [SessionThread] { members.map(\.record) }
    public var partitions: [Int: PartitionRef] { partitionTable }
    public func rowOffsets() -> [Int] { members.map(\.rowOffset) }

    /// The context lines a generation with these per-Thread contexts logs: one per attached Thread
    /// (never the commons) that has a context, by its strand index now.
    public func contextRefs(_ contexts: [String: NodeContext]) -> [ContextRef] {
        members.enumerated().compactMap { t, member in
            guard !member.descriptor.isCommons, let context = contexts[member.descriptor.name] else { return nil }
            return ContextRef(strand: t, tokens: context.tokens, score: context.score, documentID: context.documentID,
                              row: context.position.row, offset: context.position.offset)
        }
    }

    /// The members as slots, now.
    public var slots: [StrandSlot] {
        members.map { StrandSlot(name: $0.descriptor.name, rowOffset: $0.rowOffset, rowCount: $0.record.rowCount, tau: $0.tau, commons: $0.descriptor.isCommons) }
    }
    public func taus() -> [Double] { members.map(\.tau) }

    /// Starts writing the session log at `url` (the header names the strands attached now).
    public func startLog(at url: URL) throws {
        let header = SessionHeader(sessionID: sessionID, pack: pack, gate: settings.gate, trace: settings.trace, module: settings.module,
                                   hitsLogged: settings.hitsLogged, threads: strandRecords)
        writer = try SessionWriter(url: url, header: header)
    }

    public func closeLog() {
        writer?.close()
        writer = nil
    }

    // MARK: Membership

    /// Attaches a node now, or at the next token boundary while a generation runs.
    public func attach(_ node: any Node) throws {
        lock.lock()
        let running = generating
        if running { pending.append(.attach(node)) }
        lock.unlock()
        if !running { try admit(node, position: 0, tokens: nil) }
    }

    public func detach(_ name: String) throws {
        lock.lock()
        let running = generating
        if running { pending.append(.detach(name)) }
        lock.unlock()
        if !running { try dismiss(name, position: 0, session: nil) }
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        for member in members { member.node.cancel() }
    }

    private var generating = false

    private func admit(_ node: any Node, position: Int, tokens: [Int32]?, into gate: inout GateState? , module: inout LiveModule?, trackers: inout [TraceTracker?], emissions: inout [NodeStep?]) throws {
        let descriptor = node.descriptor
        guard !members.contains(where: { $0.descriptor.name == descriptor.name }) else { throw ClusterError.duplicate(descriptor.name) }
        if descriptor.isCommons, commonsIndex != nil { throw ClusterError.commonsTwice }
        try Conformance.check(descriptor, vocabularySHA256: reed.vocabularySHA256, packSHA256: pack.sha256, hiddenSize: reed.hiddenSize, tokenizerSHA256: tokenizer.sha256,
                              seamSHA256: pack.seamSHA256)
        let layout = try node.layout()
        let rowOffset = nextRow
        if let layout {
            for partition in layout.partitions {
                var global = partition
                global.row = rowOffset + partition.row
                global.threadID = partition.threadID ?? descriptor.threadID ?? descriptor.name
                partitionTable[global.row] = global
            }
            nextRow += (layout.partitions.map(\.row).max() ?? -1) + 1
            sharedNgrams.formUnion(layout.sharedNgrams)
        }
        let lambdaScale = Double(descriptor.lambdaScale)
        let record = SessionThread(descriptor: descriptor, lambda: Float(lambdaScale * Double(currentLambda)), rowOffset: rowOffset, rowCount: layout?.partitions.count ?? 0)
        let member = Member(node: node, descriptor: descriptor, layout: layout, corpus: layout?.corpus, rowOffset: rowOffset, tau: Double(descriptor.tau),
                            lambdaScale: lambdaScale, record: record)
        members.append(member)
        var caughtUp = 0
        var catchUpHits: [[Hit]]? = nil
        let started = Date()
        if let tokens {
            // Mid-session: one forward over the prefix brings the newcomer level.
            let steps = try node.open(session: sessionID, tokens: tokens, k: settings.k)
            emissions.append(steps.last)
            caughtUp = tokens.count
            catchUpHits = steps.map { Array($0.hits.prefix(settings.hitsLogged)) }
            var tracker = layout.map { TraceTracker(corpus: $0.corpus, rule: settings.trace) }
            if var t = tracker {
                for (j, step) in steps.enumerated() where j + 1 < tokens.count { _ = t.step(token: tokens[j], hits: step.hits) }
                tracker = t
            }
            trackers.append(tracker)
            gate?.commons = commonsIndex
            if gate != nil { Gate.attach(&gate!) }
            module?.attach()
        }
        let seconds = Date().timeIntervalSince(started)
        if tokens != nil {
            try writer?.membership(MembershipLine(kind: "attach", strand: members.count - 1, thread: record, position: position, caughtUp: caughtUp,
                                                 seconds: seconds, memory: gate?.memory.map(Float.init) ?? [], catchUpHits: catchUpHits))
        }
        onEvent?(.attached(name: descriptor.name, position: position, caughtUp: caughtUp, seconds: seconds))
    }

    private func admit(_ node: any Node, position: Int, tokens: [Int32]?) throws {
        var gate: GateState? = nil
        var module: LiveModule? = nil
        var trackers: [TraceTracker?] = []
        var emissions: [NodeStep?] = []
        try admit(node, position: position, tokens: tokens, into: &gate, module: &module, trackers: &trackers, emissions: &emissions)
    }

    private func dismiss(_ name: String, position: Int, session: SessionID?, gate: inout GateState?, module: inout LiveModule?, trackers: inout [TraceTracker?], emissions: inout [NodeStep?]) throws {
        guard let index = members.firstIndex(where: { $0.descriptor.name == name }) else { throw ClusterError.unknown(name) }
        let member = members.remove(at: index)
        if let session { member.node.close(session: session) }
        if trackers.indices.contains(index) { trackers.remove(at: index) }
        if emissions.indices.contains(index) { emissions.remove(at: index) }
        if gate != nil { Gate.detach(&gate!, at: index) }
        module?.detach(at: index)
        if session != nil {
            try writer?.membership(MembershipLine(kind: "detach", strand: index, thread: member.record, position: position, caughtUp: 0, seconds: 0,
                                                 memory: gate?.memory.map(Float.init) ?? []))
        }
        onEvent?(.detached(name: name, position: position))
    }

    private func dismiss(_ name: String, position: Int, session: SessionID?) throws {
        var gate: GateState? = nil
        var module: LiveModule? = nil
        var trackers: [TraceTracker?] = []
        var emissions: [NodeStep?] = []
        try dismiss(name, position: position, session: session, gate: &gate, module: &module, trackers: &trackers, emissions: &emissions)
    }

    private var currentLambda: Float = 0.5

    // MARK: Generation

    /// Runs one generation: scores the prompt, generates up to `params.maxTokens`, logs every
    /// position, advances every node, applies attach/detach at token boundaries.
    public func generate(prompt: GenerationPrompt, contexts: [String: NodeContext] = [:], params: GenerationParameters = GenerationParameters(),
                         onStep: ((Step) -> Void)? = nil) throws -> Generation {
        guard !members.isEmpty else { throw ClusterError.noStrands }
        lock.lock()
        generating = true
        cancelled = false
        lock.unlock()
        defer {
            lock.lock()
            generating = false
            lock.unlock()
        }
        currentLambda = params.lambda
        for i in members.indices { members[i].record.lambda = Float(members[i].lambdaScale * Double(params.lambda)) }
        let eos = tokenizer.eos
        var tokens: [Int32] = [eos] + prompt.tokens
        let promptCount = tokens.count
        let strands = strandRecords
        let generationID = SessionLog.generationID(pack: pack, threads: strands, gateFingerprint: settings.gate.fingerprint, prompt: prompt, params: params)
        let contextRefs = self.contextRefs(contexts)
        var contextTokens: [[Int32]] = members.map { _ in [] }
        for ref in contextRefs { contextTokens[ref.strand] = ref.tokens }
        let gen = GenerationLine(generationID: generationID, prompt: prompt, context: contextRefs.isEmpty ? nil : contextRefs, params: params, strands: strandNames)
        try writer?.begin(gen)
        var steps: [Step] = []
        var stepSlots: [[StrandSlot]] = []
        var touched = Set<Int>()
        var rng = SplitMix64(seed: params.seed)

        // Open every strand on eos ‖ its context ‖ prompt.
        var emissions: [NodeStep?] = []
        var trackers: [TraceTracker?] = []
        var promptEmissions: [[NodeStep]] = []
        for (t, member) in members.enumerated() {
            let own = [eos] + contextTokens[t] + prompt.tokens
            let opened = try member.node.open(session: sessionID, tokens: own, k: settings.k)
            promptEmissions.append(opened)
            emissions.append(opened.last)
            trackers.append(member.corpus.map { TraceTracker(corpus: $0, rule: settings.trace) })
        }
        var gate = GateState(strands: members.count, commons: commonsIndex, prior: settings.gate.commonsPrior)
        var module = settings.module.map { LiveModule(strands: members.count, commons: commonsIndex, settings: $0) }
        var moduleEvidence: [Double]? = nil

        // Context positions: each strand's own words before the stem, logged as ctx lines and run
        // through its tracker so a chain is live when the stem begins. The module reads them too (the
        // runway before a short stem): each ctx line logs the e_t the strand's next observation would
        // carry. The gate observes nothing here.
        for t in members.indices where !contextTokens[t].isEmpty {
            let own = contextTokens[t]
            let logits = try reed.logits(promptEmissions[t].prefix(own.count).map(\.state))
            for c in 1...own.count {
                let emission = promptEmissions[t][c - 1]
                let expert = Expert(hits: emission.hits, tau: members[t].tau, logits: logits[c - 1], lambda: members[t].lambdaScale * Double(params.lambda))
                let state = trackers[t]?.step(token: c == 1 ? eos : own[c - 2], hits: promptEmissions[t][c - 1].hits)
                let record = ThreadRecord(memory: Float(gate.memory[t]), weight: 1, open: true, plm: expert.plm.map { Float($0[Int(own[c - 1])]) },
                                          pknn: Float(expert.knn[Int(own[c - 1])] ?? 0), share: 1, hlm: expert.lmEntropy.map(Float.init), hknn: Float(expert.knnEntropy),
                                          module: module.map { Float($0.evidence(strand: t)) }, shadowGate: 1, shadowShare: 1,
                                          hits: Array(emission.hits.prefix(settings.hitsLogged)), trace: state)
                let step = Step(index: c, token: own[c - 1], text: tokenizer.text(own[c - 1]), source: .ctx, owner: t, prob: expert.probability(of: Int(own[c - 1])).map(Float.init) ?? 0,
                                lambda: Float(expert.lambda), threads: [record])
                try writer?.append(step)
                steps.append(step)
                stepSlots.append([slots[t]])
                module?.pushContext(record, strand: t)
            }
        }
        // Every strand's e_t for the first prompt observation (0 before any reading).
        moduleEvidence = module?.evidence()

        func record(position j: Int, token: Int32, source: StepSource, memory: [Double], expertsAt: [Expert], mixture: Mixture, traces: [TraceState?], evidence: [Double]?,
                    candidates: [(token: Int, prob: Double, parts: [Double])], stop: StopReason?) -> Step {
            let y = Int(token)
            let shares = Mixer.shares(mixture, experts: expertsAt, token: y)
            let traceValues = traces.map { Double($0?.trace ?? 0) }
            let shadowGates = Gate.shadowWeights(GateState(memoryOnly: memory, commons: commonsIndex), traces: traceValues, beta: settings.gate.shadowBeta)
            let shadowWeights = Gate.renormalised(shadowGates, open: mixture.open)
            let shadowP = expertsAt.indices.reduce(0.0) { $0 + (mixture.open[$1] ? shadowWeights[$1] * (expertsAt[$1].probability(of: y) ?? 0) : 0) }
            let records = expertsAt.indices.map { t -> ThreadRecord in
                let expert = expertsAt[t]
                for hit in expert.hits { touched.insert(members[t].rowOffset + Int(hit.row)) }
                if let row = traces[t]?.row { touched.insert(members[t].rowOffset + Int(row)) }
                let shadowShare = shadowP > 0 && mixture.open[t] ? shadowWeights[t] * (expert.probability(of: y) ?? 0) / shadowP : 0
                return ThreadRecord(memory: Float(memory[t]), weight: Float(mixture.weights[t]), open: mixture.open[t],
                                    plm: expert.plm.map { Float(y < $0.count ? $0[y] : 0) }, pknn: Float(expert.knn[y] ?? 0), share: Float(shares[t]),
                                    hlm: expert.lmEntropy.map(Float.init), hknn: Float(expert.knnEntropy), evidence: evidence.map { Float($0[t]) },
                                    module: moduleEvidence.map { Float($0[t]) }, shadowGate: Float(shadowGates[t]), shadowShare: Float(shadowShare),
                                    hits: Array(expert.hits.prefix(settings.hitsLogged)), trace: traces[t])
            }
            return Step(index: j, token: token, text: tokenizer.text(token), source: source, prob: Float(y < mixture.mixed.count ? mixture.mixed[y] : 0),
                        lambda: Float(mixture.lambda), threads: records,
                        candidates: candidates.map { Candidate(token: Int32($0.token), text: tokenizer.text(Int32($0.token)), prob: Float($0.prob), parts: $0.parts.map(Float.init)) },
                        stop: stop)
        }

        // The eos opener: no strands predicted it.
        let opener = Step(index: 0, token: eos, text: tokenizer.text(eos), source: .prompt, prob: 1, lambda: params.lambda, threads: nil)
        try writer?.append(opener)
        steps.append(opener)
        stepSlots.append(slots)
        onStep?(opener)

        // Prompt positions: every strand asked, evidence observed.
        var promptLogits: [[[Float]]] = []
        for t in members.indices {
            let states = promptEmissions[t].dropFirst(contextTokens[t].count).map(\.state)
            promptLogits.append(try reed.logits(Array(states)))
        }
        for j in 1..<promptCount {
            let experts = members.indices.map { t -> Expert in
                let local = contextTokens[t].count + j - 1
                return Expert(hits: promptEmissions[t][local].hits, tau: members[t].tau, logits: promptLogits[t][j - 1], lambda: members[t].lambdaScale * Double(params.lambda))
            }
            let traces: [TraceState?] = members.indices.map { t in
                let local = contextTokens[t].count + j - 1
                return trackers[t]?.step(token: tokens[j - 1], hits: promptEmissions[t][local].hits)
            }
            let gates = Gate.weights(gate)
            let open = members.map { _ in true }
            let mixture = Mixer.mix(experts: experts, gates: gates, open: open, vocabulary: reed.vocabulary)
            let y = Int(tokens[j])
            let likelihoods = experts.indices.map { t in experts[t].probability(of: y) ?? experts[t].lowerBound(of: y) }
            let memory = gate.memory
            let evidence = Gate.observe(&gate, likelihoods: likelihoods, module: moduleEvidence, settings: settings.gate)
            let step = record(position: j, token: tokens[j], source: .prompt, memory: memory, expertsAt: experts, mixture: mixture, traces: traces,
                              evidence: evidence, candidates: Mixer.candidates(mixture, experts: experts, count: settings.candidates), stop: nil)
            try writer?.append(step)
            steps.append(step)
            stepSlots.append(slots)
            onStep?(step)
            onEvent?(.step(step))
            if var m = module { moduleEvidence = m.push(step); module = m }
        }

        // Generation.
        var generatedText = ""
        var stopped: StopReason? = nil
        var position = promptCount
        while position - promptCount < params.maxTokens {
            try applyPending(position: position, tokens: tokens, gate: &gate, module: &module, trackers: &trackers, emissions: &emissions)
            // Attach and detach move strands: each strand's e_t follows it (a newcomer starts at 0).
            if let m = module { moduleEvidence = m.evidence() }
            lock.lock()
            let stop = cancelled
            lock.unlock()
            if stop { stopped = .max; break }
            guard !members.isEmpty else { throw ClusterError.noStrands }
            let states = emissions.map { $0?.state ?? [] }
            let logits = try reed.logits(states)
            let experts = members.indices.map { t in
                Expert(hits: emissions[t]?.hits ?? [], tau: members[t].tau, logits: logits[t], lambda: members[t].lambdaScale * Double(params.lambda))
            }
            let traces: [TraceState?] = members.indices.map { t in trackers[t]?.step(token: tokens[position - 1], hits: emissions[t]?.hits ?? []) }
            let gates = Gate.weights(gate)
            let open = Gate.open(gates, commons: commonsIndex, floor: Gate.floor(settings.gate.openFloor, strands: members.count))
            let mixture = Mixer.mix(experts: experts, gates: gates, open: open, vocabulary: reed.vocabulary)
            let token: Int
            if params.temperature > 0 {
                var tempered = [Double](repeating: 0, count: reed.vocabulary)
                for t in experts.indices where mixture.reedWeights[t] > 0 && mixture.weights[t] > 0 {
                    let p = Mixer.softmax(logits[t], temperature: Double(params.temperature))
                    for i in 0..<min(p.count, tempered.count) { tempered[i] += mixture.reedWeights[t] * (1 - mixture.lambda) * p[i] }
                }
                for t in experts.indices where mixture.knnWeights[t] > 0 && mixture.weights[t] > 0 {
                    for (tok, v) in experts[t].knn where tok >= 0 && tok < tempered.count { tempered[tok] += mixture.knnWeights[t] * mixture.lambda * v }
                }
                token = Mixer.sample(tempered, topK: params.topK, rng: &rng)
            } else {
                token = Mixer.choose(mixture.mixed) { candidate in
                    Mixer.citedAge(candidate, experts: experts, mixture: mixture) { t, row in self.partitionTable[self.members[t].rowOffset + Int(row)]?.createdAt }
                }
            }
            let text = tokenizer.text(Int32(token))
            var reason: StopReason? = nil
            if Int32(token) == eos { reason = .eos }
            else if params.stopAtSentenceEnd, !generatedText.isEmpty, AnswerStop.sentenceEnded(previous: generatedText, next: text) { reason = .sentence }
            if reason == .sentence { stopped = .sentence; break }
            let last = position - promptCount + 1 == params.maxTokens
            let step = record(position: position, token: Int32(token), source: .gen, memory: gate.memory, expertsAt: experts, mixture: mixture, traces: traces,
                              evidence: nil, candidates: Mixer.candidates(mixture, experts: experts, count: settings.candidates),
                              stop: reason ?? (last ? .max : nil))
            try writer?.append(step)
            steps.append(step)
            stepSlots.append(slots)
            onStep?(step)
            onEvent?(.step(step))
            if var m = module { moduleEvidence = m.push(step); module = m }
            if reason == .eos { stopped = .eos; break }
            tokens.append(Int32(token))
            generatedText += text
            position += 1
            if last { stopped = .max; break }
            for t in members.indices { emissions[t] = try members[t].node.advance(session: sessionID, token: Int32(token), k: settings.k) }
        }
        for member in members { member.node.close(session: sessionID) }

        let touchedPartitions = touched.sorted().compactMap { partitionTable[$0] }
        let end = try writer?.end(generationID: generationID, tokens: tokens.count, generated: tokens.count - promptCount, stoppedOn: stopped, text: generatedText,
                                  partitions: touchedPartitions)
            ?? EndLine(generationID: generationID, tokens: tokens.count, generated: tokens.count - promptCount, stoppedOn: stopped, text: generatedText,
                       partitions: touchedPartitions, bodySHA256: "")
        // The derived views, each step read through the strands it was recorded with.
        let sharedIndices = steps.indices.filter { steps[$0].source != .ctx }
        let shared = sharedIndices.map { steps[$0] }
        let sharedSlots = sharedIndices.map { stepSlots[$0] }
        let (annotations, spans) = Spans.annotate(steps: shared, slots: sharedSlots, partitions: partitionTable, sharedNgrams: sharedNgrams, settings: settings.spans)
        var credits = Credit.assign(shared, slots: sharedSlots)
        let decisions = FollowedCredit.apply(&credits, steps: shared, slots: sharedSlots, partitions: partitionTable)
        let royalties = Royalties.view(steps: shared, credits: credits, slots: sharedSlots, partitions: partitionTable)
        return Generation(gen: gen, steps: steps, end: end, strands: strands, annotations: annotations, spans: spans, credits: credits, decisions: decisions,
                          royalties: royalties, slots: stepSlots)
    }

    private func applyPending(position: Int, tokens: [Int32], gate: inout GateState, module: inout LiveModule?, trackers: inout [TraceTracker?], emissions: inout [NodeStep?]) throws {
        lock.lock()
        let queued = pending
        pending = []
        lock.unlock()
        for op in queued {
            var g: GateState? = gate
            switch op {
            case .attach(let node):
                try admit(node, position: position, tokens: tokens, into: &g, module: &module, trackers: &trackers, emissions: &emissions)
            case .detach(let name):
                try dismiss(name, position: position, session: sessionID, gate: &g, module: &module, trackers: &trackers, emissions: &emissions)
            }
            if let g { gate = g }
        }
    }
}
