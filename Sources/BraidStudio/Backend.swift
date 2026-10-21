//
//  Backend.swift
//  BraidStudio
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Where the studio's jobs run. `LiveBackend` sends the MLX jobs (start, generate, attach
//        and detach, create a Thread) to the one MLX worker thread and runs everything else — the
//        AII, the doctor, the sessions list, replaying a saved session, verifying one, the example
//        prompts — as detached tasks. Both backends replay a session through `SessionReplayer`,
//        posting its log lines, so a saved session renders exactly as the live one did.
//  PIN:  Every job reports `jobStarted`, then `jobFinished` or `jobFailed`, with the CLI's failure
//        type and exit codes.
//

import BraidKit
import BraidTerminal
import Foundation

public protocol StudioBackend: AnyObject, Sendable {
    func submit(_ job: StudioJob)
    func shutdown() async
}

public struct StudioOptions: Sendable {
    /// The work area, when one resolved; `workAreaProblem` says why it did not.
    public var workArea: WorkArea?
    public var workAreaProblem: String?
    /// Replay a recorded session from this directory instead of running MLX.
    public var fixtures: URL?
    /// Where `braid aii create` puts demo AII homes: `<repo>/aii`.
    public var demoRoot: URL = StudioOptions.defaultDemoRoot()

    public init() {}

    /// The repository root, found from the running binary (`.build/…/braid`); the working directory otherwise.
    public static func defaultDemoRoot(executable: URL = URL(fileURLWithPath: CommandLine.arguments[0])) -> URL {
        var url = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) { return DemoHomes.root(repository: url) }
            url.deleteLastPathComponent()
        }
        return DemoHomes.root(repository: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
    }
}

/// The failure a job reports: BraidFailure as it is, the braid's own errors mapped to data errors.
enum StudioFailure {
    static func describe(_ error: Error) -> BraidFailure {
        if let failure = error as? BraidFailure { return failure }
        if error is CancellationError { return BraidFailure("cancelled", code: .interrupted) }
        if let error = error as? ClusterError { return BraidFailure(error.description, code: .data) }
        if let error = error as? Conformance.Failure { return BraidFailure(error.description, code: .data) }
        if let error = error as? SessionReader.Failure { return BraidFailure(error.description, code: .data) }
        return BraidFailure("\(error)", code: .internalError)
    }
}

/// What the worker loaded that the backend's jobs read: the Threads' index layouts (for verify),
/// the tokenizer folder, the names attached. Touched under its lock.
final class SharedBraid: @unchecked Sendable {
    private let lock = NSLock()
    private var storedLayouts: [String: IndexLayout] = [:]
    private var storedAttached: [String] = []
    private var storedTokenizerFolder: URL?

    var layouts: [String: IndexLayout] { lock.withLock { storedLayouts } }
    func setLayout(_ layout: IndexLayout?, for name: String) { lock.withLock { storedLayouts[name] = layout } }

    var attached: [String] {
        get { lock.withLock { storedAttached } }
        set { lock.withLock { storedAttached = newValue } }
    }

    var tokenizerFolder: URL? {
        get { lock.withLock { storedTokenizerFolder } }
        set { lock.withLock { storedTokenizerFolder = newValue } }
    }
}

public final class LiveBackend: StudioBackend, @unchecked Sendable {
    let options: StudioOptions
    let post: @Sendable (StudioEvent) -> Void
    let shared = SharedBraid()
    let worker: MLXWorker

    public init(options: StudioOptions, post: @escaping @Sendable (StudioEvent) -> Void) {
        self.options = options
        self.post = post
        worker = MLXWorker(options: options, shared: shared, post: post)
    }

    public convenience init(options: StudioOptions, mailbox: Mailbox<StudioEvent>) {
        self.init(options: options, post: { mailbox.post($0) })
    }

    public func submit(_ job: StudioJob) {
        switch job {
        case .cancel:
            worker.request(.cancel)
            return
        case .attach(let name):
            worker.request(.attach(name))
            return
        case .detach(let name):
            worker.request(.detach(name))
            return
        default:
            break
        }
        guard let kind = job.kind else { return }
        if kind.isMLX {
            worker.enqueue(job)
            return
        }
        let post = self.post
        Task.detached { [self] in
            post(.jobStarted(kind, Self.label(job)))
            do {
                try await perform(job)
                post(.jobFinished(kind))
            } catch {
                post(.jobFailed(kind, StudioFailure.describe(error)))
            }
        }
    }

    public func shutdown() async { worker.stop() }

    static func label(_ job: StudioJob) -> String {
        switch job {
        case .start: return "starting the braid"
        case .generate(let request): return "asking: \(request.prompt.prefix(40))"
        case .attach(let name): return "attaching \(name)"
        case .detach(let name): return "detaching \(name)"
        case .createThread(let request): return "creating \(request.name)"
        case .examples: return "reading example prompts"
        case .verify: return "verifying the session"
        case .sessions: return "listing sessions"
        case .openSession(let url): return "replaying \(url.lastPathComponent)"
        case .aii: return "detecting the AII"
        case .doctor: return "running the checks"
        case .cancel: return "cancelling"
        }
    }

    func perform(_ job: StudioJob) async throws {
        switch job {
        case .examples:
            guard let area = options.workArea else {
                post(.examples([]))
                return
            }
            post(.examples(Examples.load(area: area, attached: shared.attached)))
        case .verify(let url):
            try verify(url)
        case .sessions:
            guard let area = options.workArea else { throw BraidFailure.unavailable("no work area: nowhere to read sessions from") }
            post(.sessions(try Sessions.list(in: area.sessions)))
        case .openSession(let url):
            try await SessionReplayer.replay(url, delay: .milliseconds(25), post: post)
        case .aii:
            post(.aii(await AIIProbe.status(demoRoot: options.demoRoot)))
        case .doctor:
            let area: Result<WorkArea, Error> = options.workArea.map { .success($0) }
                ?? .failure(BraidFailure.configuration(options.workAreaProblem ?? "no work area: the T9 is not mounted", hint: "set BRAID_WORK_AREA or pass --work-area"))
            let checks = await DoctorChecks.run(area: area) { area in
                guard FileManager.default.fileExists(atPath: area.configFile.path) else {
                    throw BraidFailure.missing("no braid.toml in \(area.root.path)", hint: "run braid init --base <pack or hf-id> first")
                }
                return try BraidConfig.load(from: area.configFile)
            }
            post(.doctor(checks))
        default:
            break
        }
    }

    /// Replays the log with no model: the arithmetic, the traces over each Thread's index layout,
    /// every verbatim span re-read from the Thread's snapshot.
    func verify(_ url: URL) throws {
        guard let area = options.workArea else { throw BraidFailure.unavailable("no work area: the snapshots to verify against are there") }
        let session = try SessionReader.read(url)
        let tokenizer = shared.tokenizerFolder.flatMap { try? BraidTokenizer(folder: $0) }
        var snapshots: [CorpusSnapshot] = []
        let names = Set(session.header.threads.filter { !$0.commons }.map(\.name) + session.membership.filter { $0.kind == "attach" }.map(\.thread.name))
        for name in names.sorted() {
            let layout = area.thread(name)
            guard let live = try? ThreadStore.live(layout) else { continue }
            if let snapshot = try? CorpusSnapshot.load(from: layout.snapshot(hash: live.snapshotHash)) { snapshots.append(snapshot) }
        }
        let layouts = shared.layouts
        let report = Verifier.verify(session: session, name: url.lastPathComponent, layouts: { layouts[$0] },
                                     reader: SnapshotPartitionReader(snapshots: snapshots), tokenizer: tokenizer)
        post(.verified(report))
    }
}

enum Sessions {
    /// `*.jsonl` in a sessions directory, newest first (the names start with a timestamp).
    static func list(in directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" && !$0.lastPathComponent.hasPrefix("._") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}

/// Posts a saved session's lines in order, as the cluster posted them live.
enum SessionReplayer {
    static func replay(_ url: URL, delay: Duration, post: @Sendable (StudioEvent) -> Void, shouldStop: () -> Bool = { false }) async throws {
        let session = try SessionReader.read(url)
        post(.session(.header(session.header)))
        for generation in session.generations {
            let strands = SessionReplay.strands(for: generation, session: session)
            post(.table(strands: strands, partitions: generation.end?.partitions ?? [], session: url))
            post(.session(.gen(generation.gen)))
            var membership = 0
            for (k, step) in generation.steps.enumerated() {
                while membership < generation.membership.count, generation.membership[membership].before == k {
                    post(.session(.membership(generation.membership[membership].line)))
                    membership += 1
                }
                if shouldStop() { throw CancellationError() }
                post(.session(.step(step)))
                if delay > .zero, !step.isPrompt { try await Task.sleep(for: delay) }
            }
            if let end = generation.end { post(.session(.end(end))) }
        }
    }
}

/// Fact prompts from the attached Threads' dataset nodes: the prompt and the answer the document holds.
enum Examples {
    static func load(area: WorkArea, attached: [String], perThread: Int = 40) -> [ExamplePrompt] {
        let root = DatasetsRoot.resolve(workArea: area.root)
        var examples: [ExamplePrompt] = []
        for name in attached {
            let layout = area.thread(name)
            guard let info = try? ThreadStore.info(layout), let spec = try? CorpusSourceSpec(parsing: info.source),
                  case .dataset(let nameOrPath, let node) = spec, let directory = try? DatasetsRoot.locate(nameOrPath, root: root) else { continue }
            let factsURL = BraidDataset.nodeDirectory(directory, node).appendingPathComponent("facts.jsonl")
            guard let facts = try? JSONCoding.readLines(Fact.self, from: factsURL) else { continue }
            // Only the facts of documents the Thread's snapshot holds (a --limit may have taken fewer).
            var documents: Set<String>?
            if let live = try? ThreadStore.live(layout), let snapshot = try? CorpusSnapshot.load(from: layout.snapshot(hash: live.snapshotHash)) {
                documents = Set(snapshot.documents.map(\.id))
            }
            var count = 0
            for fact in facts where documents?.contains(fact.documentID) ?? true {
                examples.append(ExamplePrompt(thread: name, label: "\(fact.kind) · \(fact.subject)", prompt: fact.prompt, expected: fact.answer))
                count += 1
                if count >= perThread { break }
            }
        }
        return examples
    }
}

/// The machine's AII and the demo AIIs, read-only: the home, its lanes, the Thread's health.
enum AIIProbe {
    static let lanes = ["ambient", "craft", "veil"]

    static func status(demoRoot: URL, environment: [String: String] = ProcessInfo.processInfo.environment) async -> AIIStatus {
        let machinePath = URL(fileURLWithPath: DoctorChecks.aiiHome(environment: environment), isDirectory: true)
        let machine = await home(named: LaneAddress.machine, path: machinePath, demoRoot: demoRoot)
        var demos: [AIIHomeStatus] = []
        if let directories = try? FileManager.default.contentsOfDirectory(at: demoRoot, includingPropertiesForKeys: nil) {
            for directory in directories.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where FileManager.default.fileExists(atPath: directory.appendingPathComponent("layout.json").path) {
                demos.append(await home(named: directory.lastPathComponent, path: directory, demoRoot: demoRoot))
            }
        }
        return AIIStatus(machine: machine, demoRoot: demoRoot.path, demos: demos)
    }

    static func home(named name: String, path: URL, demoRoot: URL) async -> AIIHomeStatus {
        let manager = FileManager.default
        let layout = manager.fileExists(atPath: path.appendingPathComponent("layout.json").path)
        let secrets = path.appendingPathComponent("secrets", isDirectory: true)
        let present = lanes.filter { manager.fileExists(atPath: secrets.appendingPathComponent($0).path) }
        let stack = manager.fileExists(atPath: secrets.appendingPathComponent("aii").path)
        var status = AIIHomeStatus(name: name, path: path.path, layout: layout, lanes: present, stackSecret: stack, httpPort: nil, grpcPort: nil, health: nil, healthProblem: nil)
        guard layout, let address = LaneAddress(parsing: "\(name)/ambient"), let endpoint = try? LaneHomes.endpoint(for: address, demoRoot: demoRoot) else {
            status.healthProblem = layout ? "no Thread ports in aii/config.json" : "no AII home"
            return status
        }
        status.httpPort = endpoint.httpPort
        status.grpcPort = endpoint.grpcPort
        do {
            let (data, _) = try await URLSession.shared.data(for: URLRequest(url: endpoint.healthURL, timeoutInterval: 3))
            let body = String(decoding: data, as: UTF8.self)
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if (object?["status"] as? String) == "healthy" || body.contains("\"healthy\"") {
                var parts = ["healthy on \(endpoint.httpPort)"]
                if let stack = object?["stack"] as? String { parts.append("stack \(stack)") }
                if let contract = object?["contract"] { parts.append("contract \(contract)") }
                status.health = parts.joined(separator: " · ")
            } else {
                status.healthProblem = "not healthy: \(body.prefix(60))"
            }
        } catch {
            status.healthProblem = "unreachable on \(endpoint.httpPort): \(error.localizedDescription)"
        }
        return status
    }
}
