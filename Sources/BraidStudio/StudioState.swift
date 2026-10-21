//
//  StudioState.swift
//  BraidStudio
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Everything the studio shows, as one value: the screen and any overlay, the status bar,
//        the braid (its Threads, the generation on the screen and the cursor in it), the AII and
//        the doctor readings.
//

import BraidKit
import BraidTerminal
import Foundation

public enum Screen: Int, CaseIterable, Sendable {
    case braid = 1, aii, doctor

    public var title: String {
        switch self {
        case .braid: return "Braid"
        case .aii: return "AII"
        case .doctor: return "Doctor"
        }
    }

    /// The screen a job's progress shows on.
    public static func owner(of kind: JobKind) -> Screen {
        switch kind {
        case .aii: return .aii
        case .doctor: return .doctor
        default: return .braid
        }
    }
}

public struct Picker: Sendable {
    public var title: String
    public var items: [String]
    public var values: [URL]
    public var table: TableState

    public init(title: String, items: [String], values: [URL], table: TableState = TableState(selected: 0)) {
        self.title = title
        self.items = items
        self.values = values
        self.table = table
    }
}

/// The new-Thread dialog: a name and a corpus source, ⏎ creates it, esc leaves.
public struct NewThreadForm: Sendable {
    public var name = TextFieldState("")
    public var corpus = TextFieldState("dataset:")
    /// 0 the name, 1 the source.
    public var field = 0
    public var error: String?

    public init() {}
}

public enum Overlay: Sendable {
    case help
    case picker(Picker)
    case newThread(NewThreadForm)
    case confirmQuit
    case cancelling(since: Date)
}

public struct JobStatus: Sendable, Equatable {
    public var kind: JobKind
    public var label: String
    public var since: Date
}

public struct StatusState: Sendable {
    public var jobs: [JobKind: JobStatus] = [:]
    public var message: String?
    public var error: BraidFailure?

    /// The job the status bar shows: the MLX job first, then any visible one.
    public var headline: JobStatus? {
        jobs.values.filter { $0.kind.isMLX }.sorted { $0.since < $1.since }.first
            ?? jobs.values.filter { $0.kind.isVisible }.sorted { $0.since < $1.since }.first
    }

    public var mlxJob: JobStatus? { jobs.values.first { $0.kind.isMLX } }
}

public enum RoyaltiesPane: Sendable, Equatable { case shares, credit }

/// The braid screen: the Threads, the generation shown (streaming or done) and the cursor in it.
public struct BraidScreenState: Sendable {
    public var status: BraidStatus?
    public var header: SessionHeader?
    public var threads: [ThreadSummary] = []
    /// Into `threads`.
    public var focus = 0
    /// Threads with an attach or detach in flight.
    public var pending: Set<String> = []
    /// The table the next `gen` line is logged against.
    public var pendingStrands: [SessionThread] = []
    public var pendingPartitions: [PartitionRef] = []
    public var current: GenerationView?
    public var generating = false
    /// Into `current.walkable`.
    public var cursor = 0
    public var prompt = TextFieldState("")
    public var editingPrompt = false
    public var examples: [ExamplePrompt] = []
    public var exampleIndex = -1
    public var royalties: RoyaltiesPane = .shares
    public var lambda: Float = 0.5
    public var temperature: Float = 0
    /// A typed prompt ending in "?" goes through the stem adapter (r toggles; a flag until the question path lands).
    public var questions = true
    public var events = LogState(capacity: 400)
    /// The log the generation shown is written to or was read from.
    public var sessionURL: URL?
    public var sessions: [URL] = []
    public var verify: VerifyReport?

    public init() {}

    public var focusedThread: ThreadSummary? { focus < threads.count ? threads[focus] : nil }

    /// Whether the braid has strands to ask.
    public var ready: Bool { !(status?.strands.isEmpty ?? true) }

    /// The example whose prompt the field holds, if the text is still its own.
    public var example: ExamplePrompt? {
        guard exampleIndex >= 0, exampleIndex < examples.count, examples[exampleIndex].prompt == prompt.text else { return nil }
        return examples[exampleIndex]
    }
}

public struct AIIScreenState: Sendable {
    public var status: AIIStatus?
    public init() {}
}

public struct DoctorScreenState: Sendable {
    public var checks: [DoctorCheck] = []
    public var ran = false
    public init() {}
}

public struct StudioState: Sendable {
    public var fixtures: Bool
    public var version: String
    public var screen: Screen = .braid
    public var overlay: Overlay?
    public var status = StatusState()
    public var braid = BraidScreenState()
    public var aii = AIIScreenState()
    public var doctor = DoctorScreenState()
    public var size = Size(width: 120, height: 40)
    public var now = Date()
    public var spinner = 0
    public var quitCode: Int32?
    public var quitAfterJobs = false
    public var redraw = false

    public init(fixtures: Bool = false, version: String = BraidVersion.string) {
        self.fixtures = fixtures
        self.version = version
    }

    /// A text field is taking keystrokes: global keys are off.
    public var editing: Bool {
        if case .newThread = overlay { return true }
        return screen == .braid && braid.editingPrompt
    }
}
