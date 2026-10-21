//
//  MLXWorker.swift
//  BraidStudio
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The one thread that runs MLX for the studio: loading the pack, the commons (whose trunk every
//        Thread runs behind its own head) and the Threads braid.toml attaches; generation; attaching a Thread (loading it first) and
//        detaching one; creating a Thread. One job at a time, in order. Attach, detach and cancel
//        requests are taken at token boundaries while a generation runs, so a Thread joins (and
//        catches up on the session so far) or leaves mid-answer, as the cluster applies them.
//  PIN:  A Foundation Thread with a 64 MB stack, never the cooperative pool — a generation blocks
//        for seconds and training for minutes. The pack, the nodes and the cluster live here and
//        never cross to the UI; only Sendable values do. One session log per answer: its header
//        names the strands attached at the ask, and the attach/detach lines inside it mark where a
//        strand joined or left.
//

import BraidKit
import BraidTerminal
import Foundation

enum MembershipRequest: Sendable {
    case attach(String)
    case detach(String)
    case cancel
}

final class MLXWorker: @unchecked Sendable {
    private let options: StudioOptions
    private let shared: SharedBraid
    private let post: @Sendable (StudioEvent) -> Void
    private let condition = NSCondition()
    private var queue: [StudioJob] = []
    private var requests: [MembershipRequest] = []
    private var stopping = false

    // Touched only on the worker thread.
    private var area: WorkArea?
    private var config: BraidConfig?
    private var pack: Pack?
    private var tokenizer: BraidTokenizer?
    private var cluster: Cluster?
    private var nodes: [String: LocalNode] = [:]
    /// The commons node and the reed, for the question path's stem rewrite.
    private var commonsNode: LocalNode?
    private var reed: MLXReed?
    private var loadFailures: [String: String] = [:]
    /// Inside `cluster.generate`: membership changes are logged lines then, and posted as such.
    private var generating = false
    /// The strands as they stood before the last membership change (a detach names an index into them).
    private var lastStrands: [SessionThread] = []

    init(options: StudioOptions, shared: SharedBraid, post: @escaping @Sendable (StudioEvent) -> Void) {
        self.options = options
        self.shared = shared
        self.post = post
        let thread = Thread { [weak self] in self?.loop() }
        thread.name = "braid.studio.mlx"
        thread.stackSize = 64 << 20
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func enqueue(_ job: StudioJob) {
        condition.lock()
        queue.append(job)
        condition.signal()
        condition.unlock()
    }

    /// Attach, detach or cancel: applied now when the worker is idle, at the next token boundary otherwise.
    func request(_ request: MembershipRequest) {
        condition.lock()
        requests.append(request)
        condition.signal()
        condition.unlock()
    }

    func stop() {
        condition.lock()
        stopping = true
        queue.removeAll()
        condition.signal()
        condition.unlock()
    }

    private func loop() {
        while true {
            condition.lock()
            while queue.isEmpty, requests.isEmpty, !stopping { condition.wait() }
            if stopping {
                condition.unlock()
                return
            }
            let pending = requests
            requests.removeAll()
            let job = queue.isEmpty ? nil : queue.removeFirst()
            condition.unlock()
            if !pending.isEmpty { apply(pending, generating: false) }
            guard let job, let kind = job.kind else { continue }
            post(.jobStarted(kind, LiveBackend.label(job)))
            do {
                try autoreleasepool { try run(job) }
                post(.jobFinished(kind))
            } catch {
                post(.jobFailed(kind, StudioFailure.describe(error)))
            }
        }
    }

    /// Takes the membership requests that arrived; the cluster queues them while it generates.
    private func drain(generating: Bool) {
        condition.lock()
        let pending = requests
        requests.removeAll()
        condition.unlock()
        if !pending.isEmpty { apply(pending, generating: generating) }
    }

    private func apply(_ pending: [MembershipRequest], generating: Bool) {
        for request in pending {
            switch request {
            case .cancel:
                guard generating, let cluster else { continue }
                cluster.cancel()
                post(.log("cancelling at the next token boundary"))
            case .attach(let name):
                guard let cluster else {
                    post(.jobFailed(.membership, BraidFailure.unavailable("the braid is not up", hint: "see the Events pane for why the start failed")))
                    continue
                }
                post(.jobStarted(.membership, "attaching \(name)"))
                do {
                    let node = try loadNode(name)
                    try cluster.attach(node)
                    if generating { post(.log("\(name) joins at the next token boundary, catching up on the session so far")) }
                    post(.jobFinished(.membership))
                } catch {
                    post(.jobFailed(.membership, StudioFailure.describe(error)))
                    postThreads()
                }
            case .detach(let name):
                guard let cluster else { continue }
                post(.jobStarted(.membership, "detaching \(name)"))
                do {
                    try cluster.detach(name)
                    if generating { post(.log("\(name) leaves at the next token boundary")) }
                    post(.jobFinished(.membership))
                } catch {
                    post(.jobFailed(.membership, StudioFailure.describe(error)))
                    postThreads()
                }
            }
        }
    }

    /// The cluster's own report of a strand joining or leaving (now, or at the boundary it chose).
    /// Mid-generation the cluster logged an attach/detach line; the same line goes to the screen.
    private func clusterEvent(_ event: ClusterEvent) {
        switch event {
        case .attached(let name, let position, let caughtUp, let seconds):
            let records = cluster?.strandRecords ?? []
            if generating, let thread = records.last, thread.name == name,
               let line = Self.membershipLine(kind: "attach", strand: records.count - 1, thread: thread, position: position, caughtUp: caughtUp, seconds: seconds) {
                post(.session(.membership(line)))
            }
            lastStrands = records
            post(.log(position > 0 ? String(format: "%@ attached at position %d: caught up %d tokens in %.1f s", name, position, caughtUp, seconds) : "\(name) attached"))
            postThreads()
        case .detached(let name, let position):
            if generating, let index = lastStrands.firstIndex(where: { $0.name == name }),
               let line = Self.membershipLine(kind: "detach", strand: index, thread: lastStrands[index], position: position, caughtUp: 0, seconds: 0) {
                post(.session(.membership(line)))
            }
            lastStrands = cluster?.strandRecords ?? []
            post(.log(position > 0 ? "\(name) detached at position \(position)" : "\(name) detached"))
            postThreads()
        case .step:
            break
        }
    }

    /// The attach/detach line as the cluster logs it (built through its coding keys; the record type has no public initialiser).
    private struct MembershipFields: Encodable {
        var kind: String
        var t: Int
        var thread: SessionThread
        var position: Int
        var caughtUp: Int
        var seconds: Double
        var memory: [Float]
    }

    static func membershipLine(kind: String, strand: Int, thread: SessionThread, position: Int, caughtUp: Int, seconds: Double) -> MembershipLine? {
        let fields = MembershipFields(kind: kind, t: strand, thread: thread, position: position, caughtUp: caughtUp, seconds: seconds, memory: [])
        guard let data = try? JSONCoding.lineEncoder().encode(fields) else { return nil }
        return try? JSONCoding.decoder().decode(MembershipLine.self, from: data)
    }

    private func run(_ job: StudioJob) throws {
        switch job {
        case .start: try start()
        case .generate(let request): try generate(request)
        case .createThread(let request): try createThread(request)
        default: break
        }
    }

    // MARK: - Start

    private func start() throws {
        guard let area = options.workArea else {
            throw BraidFailure.configuration(options.workAreaProblem ?? "no work area: the T9 is not mounted",
                                             hint: "set BRAID_WORK_AREA or pass --work-area; braid ui --fixtures <dir> replays a recording with no work area")
        }
        guard FileManager.default.fileExists(atPath: area.configFile.path) else {
            throw BraidFailure.missing("no braid.toml in \(area.root.path)", hint: "run braid init --base <pack or hf-id> first")
        }
        let config = try BraidConfig.load(from: area.configFile)
        guard let packRecord = config.pack else { throw BraidFailure.missing("braid.toml names no pack", hint: "run braid init --base <pack or hf-id>") }
        post(.jobProgress(.start, "loading the pack \(packRecord.name)"))
        guard let pack = try DoctorChecks.findPack(packRecord.sha256, in: area) else {
            throw BraidFailure.missing("braid.toml names a pack that is not on disk (\(packRecord.sha256.prefix(12)))", hint: "run braid import \(packRecord.name)")
        }
        let tokenizer = try BraidTokenizer(folder: pack.tokenizerFolder)
        let reed = pack.reed(tokens: tokenizer.vocabSize)
        var settings = ClusterSettings()
        settings.gate = config.gate
        settings.k = config.index.k
        let cluster = Cluster(reed: reed, tokenizer: tokenizer, pack: pack.identity, settings: settings)
        cluster.onEvent = { [weak self] event in self?.clusterEvent(event) }
        let scheme = KeyScheme(parsing: packRecord.keyScheme) ?? .residual(afterBlocks: pack.config.tapAfterBlocks)
        self.area = area
        self.config = config
        self.pack = pack
        self.tokenizer = tokenizer
        self.cluster = cluster
        shared.tokenizerFolder = pack.tokenizerFolder
        post(.jobProgress(.start, "loading the commons"))
        let commons = try ThreadStore.commons(pack: pack, scheme: scheme)
        commonsNode = commons
        self.reed = reed
        post(.jobProgress(.start, "the commons' trunk \(commons.trunk.seamSHA256.prefix(12)) serves every Thread"))
        try cluster.attach(commons)
        for name in config.attach {
            post(.jobProgress(.start, "loading \(name)"))
            do {
                try cluster.attach(try loadNode(name))
            } catch {
                let failure = StudioFailure.describe(error)
                loadFailures[name] = failure.message
                post(.log("\(name) did not attach: \(failure.message)"))
            }
        }
        post(.braid(status()))
        postThreads()
    }

    private func status() -> BraidStatus {
        BraidStatus(fixtures: false, workArea: area?.root.path, packName: pack?.info.name, packSHA256: pack?.sha256,
                    strands: cluster?.strandNames ?? [], commons: cluster?.commonsIndex != nil, sessionsDirectory: area?.sessions,
                    seamSHA256: commonsNode?.trunk.seamSHA256)
    }

    private func postThreads() {
        guard let area else { return }
        let attached = cluster?.strandRecords.filter { !$0.commons }.map(\.name) ?? []
        shared.attached = attached
        let infos = (try? ThreadStore.list(in: area)) ?? []
        let summaries = infos.map { info -> ThreadSummary in
            let live = try? ThreadStore.live(area.thread(info.name))
            let version = live.map { "v\($0.version) \($0.trained ? "trained" : "base") · index \($0.indexSHA256.prefix(12))" } ?? "no live version"
            return ThreadSummary(name: info.name, label: info.label, source: info.source, version: version, attached: attached.contains(info.name),
                                 error: loadFailures[info.name])
        }
        post(.threads(summaries))
    }

    /// The Thread's live version as a node, loaded once and kept (a detached Thread re-attaches without reloading).
    private func loadNode(_ name: String) throws -> LocalNode {
        if let node = nodes[name] { return node }
        guard let area, let pack, let config, let commonsNode else { throw BraidFailure.unavailable("the braid is not up") }
        let loaded = try ThreadStore.load(name, in: area, pack: pack, commons: commonsNode, tau: Float(config.index.tau))
        nodes[name] = loaded.node
        loadFailures[name] = nil
        shared.setLayout(try loaded.node.layout(), for: name)
        return loaded.node
    }

    // MARK: - Generate

    private func generate(_ request: GenerateRequest) throws {
        guard let cluster, let tokenizer, let area, let config else {
            throw BraidFailure.unavailable("the braid is not up", hint: "see the Events pane for why the start failed")
        }
        drain(generating: false)
        guard !cluster.strandNames.isEmpty else { throw BraidFailure.unavailable("no strands attached", hint: "space attaches the focused Thread") }
        cluster.closeLog()
        try FileManager.default.createDirectory(at: area.sessions, withIntermediateDirectories: true)
        let url = area.sessions.appendingPathComponent(SessionLog.fileName(sessionID: cluster.sessionID))
        try cluster.startLog(at: url)
        var params = GenerationParameters()
        params.lambda = request.lambda
        params.temperature = request.temperature
        params.maxTokens = request.maxTokens
        params.tau = Float(config.index.tau)
        params.k = config.index.k
        // A question (Q/A on, a trailing "?") goes through the path `braid chat` and `bench question`
        // use: the commons rewrites it into a stem, each attached Thread finds its own context, and the
        // answer stops at the end of the sentence.
        var prompt = GenerationPrompt(text: request.prompt, tokens: tokenizer.encode(request.prompt))
        var contexts: [String: NodeContext] = [:]
        if request.question, let commonsNode, let reed {
            let attached = cluster.strandNames.compactMap { name in nodes[name].map { (name: name, node: $0) } }
            let turn = try QuestionPath.prepare(question: request.prompt, adapter: QuestionAdapter(trunk: commonsNode.trunk, reed: reed, tokenizer: tokenizer),
                                                nodes: attached, tokenizer: tokenizer, k: config.index.k, rewriteTokens: request.maxTokens)
            prompt = turn.prompt
            contexts = turn.contexts
            params = QuestionPath.parameters(params)
            post(.log("question ▸ \(turn.stem.debugDescription) (\(turn.rewrite?.rewriter ?? "as written"))"))
            for name in attached.map(\.name) {
                if let found = turn.contexts[name] {
                    post(.log("  \(name): context \(tokenizer.decode(found.tokens).debugDescription) (cos \(String(format: "%.2f", found.score)))"))
                } else {
                    post(.log("  \(name): no context; it completes the bare stem"))
                }
            }
        }
        let strands = cluster.strandRecords
        let header = SessionHeader(sessionID: cluster.sessionID, pack: cluster.pack, gate: cluster.settings.gate, trace: cluster.settings.trace,
                                   module: cluster.settings.module, hitsLogged: cluster.settings.hitsLogged, threads: strands)
        let generationID = SessionLog.generationID(pack: cluster.pack, threads: strands, gateFingerprint: cluster.settings.gate.fingerprint, prompt: prompt, params: params)
        post(.table(strands: strands, partitions: Array(cluster.partitions.values), session: url))
        post(.session(.header(header)))
        let contextRefs = cluster.contextRefs(contexts)
        post(.session(.gen(GenerationLine(generationID: generationID, prompt: prompt, context: contextRefs.isEmpty ? nil : contextRefs, params: params,
                                          strands: cluster.strandNames))))
        let post = self.post
        generating = true
        lastStrands = strands
        defer { generating = false }
        let generation = try cluster.generate(prompt: prompt, contexts: contexts, params: params) { [weak self] step in
            post(.session(.step(step)))
            self?.drain(generating: true)
        }
        cluster.closeLog()
        post(.session(.end(generation.end)))
        post(.log("\(generation.generated.count) tokens · \(url.lastPathComponent)"))
    }

    // MARK: - New Thread

    private func createThread(_ request: NewThreadRequest) throws {
        guard let area, let pack, let config else { throw BraidFailure.unavailable("the braid is not up", hint: "see the Events pane for why the start failed") }
        let recipe = try ThreadRecipe(request.name, corpus: request.corpus)
        let post = self.post
        let engine = BraidEngine(area: area, config: config, pack: pack, tokenizer: tokenizer, reed: reed, commons: commonsNode) { event in
            guard let note = event.line else { return }
            post(.jobProgress(.createThread, note))
            post(.log(note))
        }
        let outcome = try engine.create(recipe)
        self.config = engine.config
        post(.log(outcome.summary))
        if let cluster { try cluster.attach(try loadNode(request.name)) }
        postThreads()
    }
}
