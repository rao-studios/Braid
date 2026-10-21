//
//  StudioEvents.swift
//  BraidStudio
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: What the UI asks the backend to do (jobs) and what the backend reports back (events).
//        Both are Sendable values; the UI never touches a model, a file or a socket. A session
//        reaches the screen as its log lines (`StudioEvent.session`), so a live generation and a
//        replayed one render through one path.
//  PIN:  MLX jobs (start, generate, attach/detach, create a Thread) run one at a time on the MLX
//        worker's thread; the rest (AII, doctor, sessions, verify, examples) run as detached tasks.
//

import BraidKit
import Foundation

public enum JobKind: String, Sendable, CaseIterable {
    case start, generate, membership, createThread, examples, verify, sessions, openSession, aii, doctor

    /// Runs on the MLX worker, one at a time.
    public var isMLX: Bool {
        switch self {
        case .start, .generate, .membership, .createThread: return true
        default: return false
        }
    }

    /// Worth a spinner in the status bar.
    public var isVisible: Bool {
        switch self {
        case .sessions, .examples, .aii: return false
        default: return true
        }
    }
}

public struct GenerateRequest: Sendable, Equatable {
    public var prompt: String
    public var lambda: Float
    public var temperature: Float
    public var maxTokens: Int
    /// The prompt is a question (ends in "?" while Q/A is on): the commons rewrites it into a stem, each
    /// Thread completes it behind its own context, and the answer is one sentence.
    public var question: Bool

    public init(prompt: String, lambda: Float = 0.5, temperature: Float = 0, maxTokens: Int = 24, question: Bool = false) {
        self.prompt = prompt
        self.lambda = lambda
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.question = question
    }
}

public struct NewThreadRequest: Sendable, Equatable {
    public var name: String
    /// `dataset:<name>#<node>` (or `dir:<path>`), the grammar `braid thread create --corpus` takes.
    public var corpus: String

    public init(name: String, corpus: String) {
        self.name = name
        self.corpus = corpus
    }
}

public enum StudioJob: Sendable {
    /// Load the pack, the commons and the Threads braid.toml attaches; build the cluster.
    case start
    case generate(GenerateRequest)
    /// Attach or detach a Thread at the next token boundary (now, when no generation runs).
    case attach(String)
    case detach(String)
    case createThread(NewThreadRequest)
    /// Fact prompts from the attached Threads' dataset nodes.
    case examples
    /// Replay a session log against the Threads' snapshots and index layouts.
    case verify(URL)
    /// List `sessions/*.jsonl`.
    case sessions
    /// Replay a saved session into the screen.
    case openSession(URL)
    case aii
    case doctor
    /// Stop the running generation at the next token boundary.
    case cancel

    public var kind: JobKind? {
        switch self {
        case .start: return .start
        case .generate: return .generate
        case .attach, .detach: return .membership
        case .createThread: return .createThread
        case .examples: return .examples
        case .verify: return .verify
        case .sessions: return .sessions
        case .openSession: return .openSession
        case .aii: return .aii
        case .doctor: return .doctor
        case .cancel: return nil
        }
    }
}

/// The braid as the worker assembled it.
public struct BraidStatus: Sendable, Equatable {
    public var fixtures: Bool
    public var workArea: String?
    public var packName: String?
    public var packSHA256: String?
    /// The strands attached, in the cluster's order (the commons first when present).
    public var strands: [String]
    public var commons: Bool
    public var sessionsDirectory: URL?
    /// The seam of the commons' trunk, the one every Thread runs; nil in fixture mode.
    public var seamSHA256: String?

    public init(fixtures: Bool, workArea: String?, packName: String?, packSHA256: String?, strands: [String], commons: Bool, sessionsDirectory: URL?, seamSHA256: String? = nil) {
        self.fixtures = fixtures
        self.workArea = workArea
        self.packName = packName
        self.packSHA256 = packSHA256
        self.strands = strands
        self.commons = commons
        self.sessionsDirectory = sessionsDirectory
        self.seamSHA256 = seamSHA256
    }
}

/// One Thread in the work area, attached or not.
public struct ThreadSummary: Sendable, Equatable {
    public var name: String
    public var label: String
    public var source: String
    public var version: String?
    public var attached: Bool
    public var error: String?

    public init(name: String, label: String, source: String, version: String?, attached: Bool, error: String? = nil) {
        self.name = name
        self.label = label
        self.source = source
        self.version = version
        self.attached = attached
        self.error = error
    }
}

/// A fact prompt from a Thread's dataset node: the prompt, and the answer its document holds.
public struct ExamplePrompt: Sendable, Equatable {
    public var thread: String
    public var label: String
    public var prompt: String
    public var expected: String

    public init(thread: String, label: String, prompt: String, expected: String) {
        self.thread = thread
        self.label = label
        self.prompt = prompt
        self.expected = expected
    }
}

/// One AII home as detected: the machine's (`home`) or a demo under <repo>/aii.
public struct AIIHomeStatus: Sendable, Equatable {
    public var name: String
    public var path: String
    public var layout: Bool
    public var lanes: [String]
    public var stackSecret: Bool
    public var httpPort: Int?
    public var grpcPort: Int?
    /// "healthy · stack proof · contract 1" when the Thread answered.
    public var health: String?
    public var healthProblem: String?

    public init(name: String, path: String, layout: Bool, lanes: [String], stackSecret: Bool, httpPort: Int?, grpcPort: Int?, health: String?, healthProblem: String?) {
        self.name = name
        self.path = path
        self.layout = layout
        self.lanes = lanes
        self.stackSecret = stackSecret
        self.httpPort = httpPort
        self.grpcPort = grpcPort
        self.health = health
        self.healthProblem = healthProblem
    }
}

public struct AIIStatus: Sendable, Equatable {
    public var machine: AIIHomeStatus
    public var demoRoot: String
    public var demos: [AIIHomeStatus]

    public init(machine: AIIHomeStatus, demoRoot: String, demos: [AIIHomeStatus]) {
        self.machine = machine
        self.demoRoot = demoRoot
        self.demos = demos
    }
}

/// A session log line, as written (live) or as read back (replay).
public enum SessionLine: Sendable {
    case header(SessionHeader)
    case gen(GenerationLine)
    case step(Step)
    case end(EndLine)
    case membership(MembershipLine)
}

public enum StudioEvent: Sendable {
    case jobStarted(JobKind, String)
    case jobProgress(JobKind, String)
    case jobFinished(JobKind)
    case jobFailed(JobKind, BraidFailure)
    /// A line for the Events pane and the status bar.
    case log(String)
    case braid(BraidStatus)
    case threads([ThreadSummary])
    /// The strands and the braid's partition table a generation is logged against (live: the
    /// cluster's; replay: the end line's), and the file the session is written to or read from.
    case table(strands: [SessionThread], partitions: [PartitionRef], session: URL?)
    case session(SessionLine)
    case verified(VerifyReport)
    case examples([ExamplePrompt])
    case sessions([URL])
    case aii(AIIStatus)
    case doctor([DoctorCheck])
}
