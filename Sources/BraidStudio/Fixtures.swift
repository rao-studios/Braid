//
//  Fixtures.swift
//  BraidStudio
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: A backend that answers every job from a recorded session instead of MLX, so the studio
//        can be demonstrated and tested anywhere: `braid ui --fixtures <dir>`.
//  IN:   <dir>/sessions/*.jsonl (session logs as the cluster wrote them), <dir>/threads/<name>/
//        snapshot.json (the Threads' snapshots, for verify), and an optional <dir>/fixtures.json
//        naming the Threads (label, source, version) and a few example prompts.
//  PIN:  Asking replays the newest recorded session, whatever the prompt; attach and detach change
//        the Threads pane and nothing else; verification is real (it needs no model: spans are
//        re-read from the snapshots by text hash).
//

import BraidKit
import BraidTerminal
import Foundation

public struct FixtureManifest: Codable, Sendable {
    public struct ThreadSpec: Codable, Sendable {
        public var name: String
        public var label: String
        public var source: String
        public var version: String?

        public init(name: String, label: String, source: String, version: String?) {
            self.name = name
            self.label = label
            self.source = source
            self.version = version
        }
    }

    public struct ExampleSpec: Codable, Sendable {
        public var thread: String
        public var label: String
        public var prompt: String
        public var expected: String
    }

    public var threads: [ThreadSpec]?
    public var examples: [ExampleSpec]?

    public init(threads: [ThreadSpec]? = nil, examples: [ExampleSpec]? = nil) {
        self.threads = threads
        self.examples = examples
    }
}

public final class FixtureBackend: StudioBackend, @unchecked Sendable {
    public let directory: URL
    let manifest: FixtureManifest
    let post: @Sendable (StudioEvent) -> Void
    /// The pause between replayed tokens (tests set zero).
    public var replayDelay: Duration = .milliseconds(40)
    private let lock = NSLock()
    private var detached: Set<String> = []
    private var cancelled = false

    public init(directory: URL, post: @escaping @Sendable (StudioEvent) -> Void) throws {
        self.directory = directory
        self.post = post
        let manifestURL = directory.appendingPathComponent("fixtures.json")
        manifest = FileManager.default.fileExists(atPath: manifestURL.path) ? try JSONCoding.read(FixtureManifest.self, from: manifestURL) : FixtureManifest()
    }

    public convenience init(directory: URL, mailbox: Mailbox<StudioEvent>) throws {
        try self.init(directory: directory, post: { mailbox.post($0) })
    }

    public var sessionsDirectory: URL { directory.appendingPathComponent("sessions", isDirectory: true) }

    public func sessionURLs() throws -> [URL] { try Sessions.list(in: sessionsDirectory) }

    /// The newest recorded session: what an ask replays.
    public func recordedSession() throws -> URL {
        guard let url = try sessionURLs().first else {
            throw BraidFailure.missing("the fixtures hold no session", hint: "copy a sessions/*.jsonl into \(sessionsDirectory.path)")
        }
        return url
    }

    public func submit(_ job: StudioJob) {
        if case .cancel = job {
            lock.withLock { cancelled = true }
            return
        }
        guard let kind = job.kind else { return }
        let post = self.post
        Task.detached { [self] in
            if kind == .generate || kind == .openSession { lock.withLock { cancelled = false } }
            post(.jobStarted(kind, LiveBackend.label(job)))
            do {
                try await perform(job)
                post(.jobFinished(kind))
            } catch {
                post(.jobFailed(kind, StudioFailure.describe(error)))
            }
        }
    }

    public func shutdown() async {}

    public func perform(_ job: StudioJob) async throws {
        switch job {
        case .start:
            let header = try SessionReader.read(try recordedSession()).header
            post(.braid(BraidStatus(fixtures: true, workArea: directory.path, packName: header.pack.name, packSHA256: header.pack.sha256,
                                    strands: strandNames(header), commons: header.threads.contains(where: \.commons), sessionsDirectory: sessionsDirectory)))
            post(.threads(threads(header)))
        case .generate:
            post(.log("fixture mode replays the recorded session; the prompt is not sent to a model"))
            try await replay(try recordedSession())
        case .attach(let name):
            lock.withLock { _ = detached.remove(name) }
            post(.log("\(name) attached (fixture mode: the recording is unchanged)"))
            try postThreads()
        case .detach(let name):
            lock.withLock { _ = detached.insert(name) }
            post(.log("\(name) detached (fixture mode: the recording is unchanged)"))
            try postThreads()
        case .createThread:
            throw BraidFailure.unavailable("fixture mode has no model to train a Thread", hint: "run braid ui without --fixtures")
        case .examples:
            post(.examples((manifest.examples ?? []).map { ExamplePrompt(thread: $0.thread, label: $0.label, prompt: $0.prompt, expected: $0.expected) }))
        case .verify(let url):
            try verify(url)
        case .sessions:
            post(.sessions(try sessionURLs()))
        case .openSession(let url):
            try await replay(url)
        case .aii:
            post(.aii(await AIIProbe.status(demoRoot: StudioOptions.defaultDemoRoot())))
        case .doctor:
            let area: Result<WorkArea, Error> = .failure(BraidFailure.unavailable("fixture mode has no work area", hint: "run braid ui without --fixtures"))
            post(.doctor(await DoctorChecks.run(area: area) { _ in throw BraidFailure.unavailable("fixture mode") }))
        case .cancel:
            break
        }
    }

    func replay(_ url: URL) async throws {
        try await SessionReplayer.replay(url, delay: replayDelay, post: post) { [self] in lock.withLock { cancelled } }
    }

    func strandNames(_ header: SessionHeader) -> [String] {
        let detached = lock.withLock { self.detached }
        return header.threads.map(\.name).filter { !detached.contains($0) }
    }

    func threads(_ header: SessionHeader) -> [ThreadSummary] {
        let detached = lock.withLock { self.detached }
        let specs = manifest.threads ?? header.threads.filter { !$0.commons }.map {
            FixtureManifest.ThreadSpec(name: $0.name, label: $0.label, source: "recording", version: $0.indexSHA256.map { "index " + String($0.prefix(12)) })
        }
        return specs.map { ThreadSummary(name: $0.name, label: $0.label, source: $0.source, version: $0.version, attached: !detached.contains($0.name)) }
    }

    func postThreads() throws {
        post(.threads(threads(try SessionReader.read(try recordedSession()).header)))
    }

    /// Verification with no model: the arithmetic and every span re-read from the fixture's snapshots by text hash.
    func verify(_ url: URL) throws {
        let session = try SessionReader.read(url)
        let threadsRoot = directory.appendingPathComponent("threads", isDirectory: true)
        var snapshots: [CorpusSnapshot] = []
        if let folders = try? FileManager.default.contentsOfDirectory(at: threadsRoot, includingPropertiesForKeys: nil) {
            for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if let snapshot = try? CorpusSnapshot.load(from: folder) { snapshots.append(snapshot) }
            }
        }
        let report = Verifier.verify(session: session, name: url.lastPathComponent, layouts: { _ in nil }, reader: SnapshotPartitionReader(snapshots: snapshots), tokenizer: nil)
        post(.verified(report))
    }
}
