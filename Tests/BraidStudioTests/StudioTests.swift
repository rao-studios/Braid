//
//  StudioTests.swift
//  BraidStudioTests
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The studio driven by the fixture backend (a recorded session, no MLX, no work area): the
//        Braid screen renders deterministically at 120×40 and 80×24, the per-token block for a
//        chosen token reads as pinned, R switches the Royalties pane, ←→ move the cursor, o opens
//        and replays the saved session, space detaches and re-attaches a Thread, v verifies the
//        spans against the fixture's snapshots.
//

import BraidKit
import BraidTerminal
import Foundation
import Testing

@testable import BraidStudio

final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [StudioEvent] = []

    func post(_ event: StudioEvent) { lock.withLock { events.append(event) } }

    func drain() -> [StudioEvent] {
        lock.withLock {
            defer { events.removeAll() }
            return events
        }
    }
}

/// The fixture backend's jobs, folded through the studio's reducer, rendered into a canvas.
struct Harness {
    static var fixtures: URL {
        Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("demo")
    }

    static let prompt = "The article says Tillyburn was founded in"

    var backend: FixtureBackend
    let collector = Collector()
    var state: StudioState

    init() throws {
        let collector = self.collector
        backend = try FixtureBackend(directory: Self.fixtures, post: { collector.post($0) })
        backend.replayDelay = .zero
        state = StudioState(fixtures: true)
        state.size = Size(width: 120, height: 40)
    }

    mutating func fold() -> [StudioJob] {
        var followUps: [StudioJob] = []
        for event in collector.drain() { followUps += StudioApp.reduce(event, state: &state) }
        return followUps
    }

    mutating func run(_ job: StudioJob) async throws {
        try await backend.perform(job)
        for followUp in fold() {
            try? await backend.perform(followUp)
            _ = fold()
        }
    }

    mutating func key(_ key: KeyEvent) async throws {
        let jobs = StudioApp.handle(.key(key), state: &state)
        for job in jobs { try await run(job) }
    }

    /// The braid up and the recorded session replayed: the screen as it stands after an ask.
    mutating func open() async throws {
        try await run(.start)
        try await run(.generate(GenerateRequest(prompt: Self.prompt)))
    }

    func render(_ size: Size = Size(width: 120, height: 40), depth: ColorDepth = .ansi256) -> Canvas {
        let capabilities = Capabilities(isTTY: true, colorDepth: depth)
        var frame = Frame(canvas: Canvas(size: size), palette: Palette(for: capabilities, environment: [:]), glyphs: .unicode)
        StudioApp.render(state, &frame)
        return frame.canvas
    }
}

@Suite("Studio", .serialized)
struct StudioTests {
    @Test("the Braid screen renders deterministically at 120×40 and 80×24")
    func deterministic() async throws {
        var h = try Harness()
        try await h.open()
        #expect(h.state.braid.status?.strands == ["commons", "ambient-t", "craft"])
        #expect(h.state.braid.threads.map(\.name) == ["ambient-t", "craft"])
        let view = try #require(h.state.braid.current)
        #expect(view.isComplete)
        #expect(view.generated.count == 10)
        for size in [Size(width: 120, height: 40), Size(width: 80, height: 24)] {
            let first = h.render(size)
            let second = h.render(size)
            #expect(first == second, "\(size)")
            #expect(first.line(0).hasPrefix("Braid"), "\(size)")
            #expect(first.snapshot.contains("1 Braid"), "\(size)")
        }
        let text = h.render().snapshot
        #expect(text.contains(Harness.prompt))
        #expect(text.contains("▸"))
        #expect(text.contains("Threads ·"))
        #expect(text.contains("Royalties · shares"))
        #expect(text.contains("token \""))
        #expect(text.contains("Commons"))
        #expect(text.contains("Ambient-t"))
        #expect(text.contains("fixtures"))
        #expect(text.contains("Craft"), "every strand has a row in the Threads pane")
        let narrow = h.render(Size(width: 80, height: 24)).snapshot
        print(text)
        print(narrow)
        // BRAID_DUMP_SCREEN=<file> keeps both frames (the report's screenshot).
        if let path = ProcessInfo.processInfo.environment["BRAID_DUMP_SCREEN"] {
            try (text + "\n\n" + narrow + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    @Test("the per-token block for the token under the cursor reads as pinned")
    func tokenBlock() async throws {
        var h = try Harness()
        try await h.open()
        let view = try #require(h.state.braid.current)
        // After the answer the cursor rests on the first generated token.
        #expect(h.state.braid.cursor == view.firstGenerated)
        let k = view.walkable[h.state.braid.cursor]
        let lines = TokenDetail.plain(view, shared: k)
        #expect(lines.count == 3)
        for line in lines { print(line) }
        // The handoff's three lines for the recorded session's first answer token, " 1" of " 1128".
        #expect(lines[0] == "token \" 1\"  ← thread: ambient-t  share 1.00  (commons 0.00, craft 0.00)     p 0.37  H_gate 0.00")
        #expect(lines[1] == TokenDetail.indent + "trace: off-trace L=6  H_knn 0.42→1.82  H_lm 1.99→2.21   (shadow β4: ambient-t 1.00)")
        #expect(lines[2] == TokenDetail.indent + "cited: ambient-t/…37a6d5ba2cf9/partition-1/rows 6–12   conf 0.68   span 1 · v verifies")
        // The screen shows the same lines.
        let text = h.render().snapshot
        #expect(text.contains(lines[0]))
        #expect(text.contains("trace: off-trace L=6  H_knn 0.42→1.82  H_lm 1.99→2.21   (shadow β4: ambient-t 1.00)"))
        // The last token: the commons leads an uncited token.
        h.state.braid.cursor = view.walkable.count - 1
        let last = TokenDetail.plain(view, shared: view.walkable[view.walkable.count - 1])
        print(last.joined(separator: "\n"))
        #expect(last[0].hasPrefix("token \" T\"  ← "))
        // A prompt token's block says so.
        h.state.braid.cursor = 0
        let promptLines = TokenDetail.plain(view, shared: view.walkable[0])
        #expect(promptLines[0].hasPrefix("token \"The\"  ← "))
        #expect(promptLines[2].hasPrefix(TokenDetail.indent + "prompt token · evidence"))
    }

    @Test("R switches the Royalties pane between shares and credit")
    func royalties() async throws {
        var h = try Harness()
        try await h.open()
        #expect(h.state.braid.royalties == .shares)
        #expect(h.render().snapshot.contains("Royalties · shares (R: credit)"))
        try await h.key(KeyEvent(.char("R")))
        #expect(h.state.braid.royalties == .credit)
        let text = h.render().snapshot
        #expect(text.contains("Royalties · credit (R: shares)"))
        #expect(text.contains("credit·bits"))
        try await h.key(KeyEvent(.char("R")))
        #expect(h.state.braid.royalties == .shares)
    }

    @Test("←→ walk the tokens and stop at the ends")
    func cursor() async throws {
        var h = try Harness()
        try await h.open()
        let view = try #require(h.state.braid.current)
        let start = h.state.braid.cursor
        try await h.key(KeyEvent(.right))
        #expect(h.state.braid.cursor == start + 1)
        try await h.key(KeyEvent(.left))
        try await h.key(KeyEvent(.left))
        #expect(h.state.braid.cursor == start - 1)
        try await h.key(KeyEvent(.end))
        #expect(h.state.braid.cursor == view.walkable.count - 1)
        try await h.key(KeyEvent(.right))
        #expect(h.state.braid.cursor == view.walkable.count - 1)
        try await h.key(KeyEvent(.home))
        #expect(h.state.braid.cursor == 0)
        try await h.key(KeyEvent(.left))
        #expect(h.state.braid.cursor == 0)
        // The cursor's token is drawn in reverse video.
        let canvas = h.render()
        var reversed = 0
        for y in 0..<canvas.size.height { for x in 0..<canvas.size.width where canvas[x, y].style.attributes.contains(.reverse) { reversed += 1 } }
        #expect(reversed >= 3)
    }

    @Test("o lists the saved sessions and ⏎ replays the chosen one")
    func openSession() async throws {
        var h = try Harness()
        try await h.run(.start)
        #expect(h.state.braid.current == nil)
        try await h.key(KeyEvent(.char("o")))
        guard case .picker(let picker)? = h.state.overlay else {
            Issue.record("o should open the sessions picker")
            return
        }
        #expect(picker.items == ["20261015-171022-6986b466"])
        try await h.key(KeyEvent(.enter))
        #expect(h.state.overlay == nil)
        let view = try #require(h.state.braid.current)
        #expect(view.isComplete)
        #expect(view.gen.prompt.text == Harness.prompt)
        #expect(view.text == " 1128. I read that the mayor of T")
        #expect(h.state.braid.sessionURL?.lastPathComponent == "20261015-171022-6986b466.jsonl")
        #expect(h.state.braid.cursor == view.firstGenerated)
        #expect(h.render().snapshot.contains("1128"))
    }

    @Test("tab focuses a Thread; space detaches it and attaches it again")
    func membership() async throws {
        var h = try Harness()
        try await h.open()
        #expect(h.state.braid.focus == 0)
        try await h.key(KeyEvent(.tab))
        #expect(h.state.braid.focusedThread?.name == "craft")
        try await h.key(KeyEvent(.char(" ")))
        #expect(h.state.braid.threads.first { $0.name == "craft" }?.attached == false)
        #expect(h.state.braid.status?.strands == ["commons", "ambient-t"])
        #expect(h.render().snapshot.contains("○ detached"))
        try await h.key(KeyEvent(.char(" ")))
        #expect(h.state.braid.threads.first { $0.name == "craft" }?.attached == true)
        #expect(h.state.braid.status?.strands == ["commons", "ambient-t", "craft"])
        try await h.key(KeyEvent(.backTab))
        #expect(h.state.braid.focusedThread?.name == "ambient-t")
    }

    @Test("v verifies the spans against the fixture's snapshots and marks them")
    func verify() async throws {
        var h = try Harness()
        try await h.open()
        try await h.key(KeyEvent(.char("v")))
        let report = try #require(h.state.braid.verify)
        #expect(report.status == .ok)
        #expect(report.spans.count == 2)
        #expect(report.spansVerified == 2)
        let view = try #require(h.state.braid.current)
        #expect(view.verification.count == 2)
        let text = h.render().snapshot
        #expect(text.contains("◉ 2/2 spans verified"))
        #expect(text.contains("◉ verified"))
    }

    @Test("x takes the next example prompt; the first fills an empty prompt")
    func examples() async throws {
        var h = try Harness()
        try await h.run(.start)
        #expect(h.state.braid.examples.count == 4)
        #expect(h.state.braid.prompt.text == Harness.prompt)
        #expect(h.state.braid.exampleIndex == 0)
        try await h.key(KeyEvent(.char("x")))
        #expect(h.state.braid.exampleIndex == 1)
        #expect(h.state.braid.prompt.text == "I noted that Tillyburn is home to")
        #expect(h.render().snapshot.contains("expects 51861"))
    }

    @Test("the prompt line, λ, sampling and Q/A keys")
    func controls() async throws {
        var h = try Harness()
        try await h.run(.start)
        try await h.key(KeyEvent(.char("/")))
        #expect(h.state.braid.editingPrompt)
        try await h.key(KeyEvent(.ctrl("u")))
        for c in "Hello" { try await h.key(KeyEvent(.char(c))) }
        #expect(h.state.braid.prompt.text == "Hello")
        try await h.key(KeyEvent(.escape))
        #expect(!h.state.braid.editingPrompt)
        try await h.key(KeyEvent(.char("+")))
        #expect(abs(h.state.braid.lambda - 0.55) < 1e-6)
        try await h.key(KeyEvent(.char("-")))
        #expect(abs(h.state.braid.lambda - 0.5) < 1e-6)
        try await h.key(KeyEvent(.char("t")))
        #expect(h.state.braid.temperature > 0)
        try await h.key(KeyEvent(.char("r")))
        #expect(!h.state.braid.questions)
        #expect(h.render().snapshot.contains("sampled · Q/A off"))
    }

    @Test("every screen renders at 80×24 and 120×40; ? opens the help")
    func screens() async throws {
        var h = try Harness()
        try await h.open()
        for screen in Screen.allCases {
            h.state.screen = screen
            for size in [Size(width: 120, height: 40), Size(width: 80, height: 24)] {
                let canvas = h.render(size)
                #expect(canvas.line(0).hasPrefix("Braid"), "\(screen) \(size)")
                #expect(canvas.snapshot.contains("\(screen.rawValue) \(screen.title)"), "\(screen) \(size)")
            }
        }
        h.state.screen = .braid
        try await h.key(KeyEvent(.char("?")))
        #expect(h.render().snapshot.contains("Help"))
        try await h.key(KeyEvent(.escape))
        #expect(h.state.overlay == nil)
        try await h.key(KeyEvent(.char("2")))
        #expect(h.state.screen == .aii)
        try await h.key(KeyEvent(.char("1")))
        #expect(h.state.screen == .braid)
    }

    @Test("the fixture backend refuses what needs a model, with the exit code the CLI uses")
    func refusals() async throws {
        var h = try Harness()
        try await h.run(.start)
        await #expect(throws: BraidFailure.self) {
            try await h.backend.perform(.createThread(NewThreadRequest(name: "x", corpus: "dataset:braid-n3#veil")))
        }
    }
}

// MARK: - Live (MLX): the worker against the work area's Threads

/// Events from the live backend, waited on with a deadline.
final class LiveCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [StudioEvent] = []

    func post(_ event: StudioEvent) { lock.withLock { events.append(event) } }
    var all: [StudioEvent] { lock.withLock { events } }

    /// Waits until an event satisfies `predicate` (returning it), or the deadline passes.
    func wait(seconds: Double, for predicate: @escaping (StudioEvent) -> Bool) async -> StudioEvent? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let found = all.first(where: predicate) { return found }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    func clear() { lock.withLock { events.removeAll() } }
}

@Suite("Live studio (BRAID_MLX_TESTS=1 and a work area with the ambient-t and craft Threads)", .serialized)
struct LiveStudioTests {
    static var enabled: Bool {
        guard ProcessInfo.processInfo.environment["BRAID_MLX_TESTS"] == "1", let area = WorkArea.resolve() else { return false }
        return FileManager.default.fileExists(atPath: area.thread("ambient-t").record.path) && FileManager.default.fileExists(atPath: area.thread("craft").record.path)
    }

    @Test("start, ask, detach and re-attach a Thread mid-answer, verify the logs")
    func liveBraid() async throws {
        guard Self.enabled, let shared = WorkArea.resolve() else { return }
        // A temporary work area over the shared one's packs and Threads, with its own sessions/: the
        // shared area is read, never written.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("braid-live-studio-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let area = WorkArea(root: root)
        try FileManager.default.copyItem(at: shared.configFile, to: area.configFile)
        // Real packs/ and threads/ directories holding a symlink per entry (Foundation's directory
        // listing does not follow a symlinked directory itself).
        for (mine, theirs) in [(area.packs, shared.packs), (area.threads, shared.threads)] {
            try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
            for entry in try FileManager.default.contentsOfDirectory(atPath: theirs.path) where !entry.hasPrefix("._") {
                try FileManager.default.createSymbolicLink(atPath: mine.appendingPathComponent(entry).path, withDestinationPath: theirs.appendingPathComponent(entry).path)
            }
        }
        let collector = LiveCollector()
        var options = StudioOptions()
        options.workArea = area
        let backend = LiveBackend(options: options, post: { collector.post($0) })
        var state = StudioState()
        func fold() { for event in collector.all { _ = StudioApp.reduce(event, state: &state) }; collector.clear() }

        backend.submit(.start)
        let started = await collector.wait(seconds: 300) { if case .jobFinished(.start) = $0 { return true }; if case .jobFailed(.start, _) = $0 { return true }; return false }
        if case .jobFailed(_, let failure)? = started { Issue.record("start failed: \(failure)") }
        fold()
        let status = try #require(state.braid.status)
        #expect(status.commons)
        #expect(status.strands.contains("craft") && status.strands.contains("ambient-t"))
        print("live braid: \(status.strands)")

        // One answer, every strand asked.
        backend.submit(.generate(GenerateRequest(prompt: Harness.prompt, maxTokens: 8)))
        let ended = await collector.wait(seconds: 300) { if case .session(.end) = $0 { return true }; if case .jobFailed(.generate, _) = $0 { return true }; return false }
        #expect(ended != nil)
        fold()
        let first = try #require(state.braid.current)
        #expect(first.isComplete)
        #expect(first.generated.count >= 1)
        #expect(first.strands.map(\.name) == status.strands)
        let firstURL = try #require(state.braid.sessionURL)
        #expect(firstURL.path.hasPrefix(root.path), "sessions land in the work area the studio was given")
        print("live answer: \(first.text.debugDescription)")

        // Detach craft at a token boundary of the next answer, then attach it again: the cluster
        // logs both inside the generation (the same lines reach the screen) and the newcomer catches
        // up on the prefix.
        backend.submit(.generate(GenerateRequest(prompt: "I noted that Tillyburn is home to", maxTokens: 24)))
        _ = await collector.wait(seconds: 120) { if case .session(.step(let step)) = $0 { return step.source == .gen }; return false }
        backend.submit(.detach("craft"))
        let detached = await collector.wait(seconds: 120) { if case .session(.membership(let line)) = $0 { return line.kind == "detach" }; if case .session(.end) = $0 { return true }; return false }
        if case .session(.membership(let line))? = detached {
            #expect(line.thread.name == "craft")
            #expect(line.position > 0)
        } else {
            Issue.record("craft did not detach mid-answer: \(detached.map { "\($0)" } ?? "timeout")")
        }
        backend.submit(.attach("craft"))
        let attached = await collector.wait(seconds: 120) { if case .session(.membership(let line)) = $0 { return line.kind == "attach" }; if case .session(.end) = $0 { return true }; return false }
        if case .session(.membership(let line))? = attached {
            #expect(line.thread.name == "craft")
            #expect(line.caughtUp > 0, "the newcomer catches up on the prefix")
        } else {
            Issue.record("craft did not re-attach mid-answer: \(attached.map { "\($0)" } ?? "timeout")")
        }
        let endedAgain = await collector.wait(seconds: 300) { if case .session(.end) = $0 { return true }; if case .jobFailed(.generate, _) = $0 { return true }; return false }
        #expect(endedAgain != nil)
        fold()
        let second = try #require(state.braid.current)
        #expect(second.isComplete)
        #expect(second.strands.map(\.name).contains("craft"))
        #expect(state.braid.threads.first { $0.name == "craft" }?.attached == true)
        let url = try #require(state.braid.sessionURL)
        print("live session: \(url.path) · \(second.text.debugDescription)")
        for line in state.braid.events.lines.elements.map(\.plain) where line.contains("craft") { print("live event: \(line)") }

        // The first log, whose strands never changed, replays clean: arithmetic, traces over the
        // layouts, every span re-read from the snapshots with the tokenizer.
        backend.submit(.verify(firstURL))
        let verifiedFirst = await collector.wait(seconds: 120) { if case .verified = $0 { return true }; if case .jobFailed(.verify, _) = $0 { return true }; return false }
        guard case .verified(let clean)? = verifiedFirst else {
            Issue.record("verify of the first session did not report: \(verifiedFirst.map { "\($0)" } ?? "timeout")")
            return
        }
        print("live verify (unchanged strands): \(clean.status) · \(clean.spansVerified)/\(clean.spans.count) spans · issues \(clean.issues.map(\.description))")
        #expect(clean.status == .ok)
        #expect(clean.issues.isEmpty)
        #expect(clean.spansFailed == 0)
        collector.clear()

        // The second log, with a detach and an attach inside the answer, verifies whole: the arithmetic
        // and the memory recursion, every strand's trace, every span (each step read through its own strands).
        backend.submit(.verify(url))
        let verified = await collector.wait(seconds: 120) { if case .verified = $0 { return true }; if case .jobFailed(.verify, _) = $0 { return true }; return false }
        fold()
        let report = try #require(state.braid.verify, "\(verified.map { "\($0)" } ?? "timeout")")
        print("live verify (strands changed mid-answer): \(report.status) · \(report.spansVerified)/\(report.spans.count) spans · issues \(report.issues.map(\.description))")
        #expect(report.status == .ok, "\(report.issues.map(\.description)) \(report.spans.filter { $0.status != .verified }.map(\.text))")
        collector.clear()

        // A question, Q/A on: the commons' stem, each Thread's context, one sentence; the log verifies.
        backend.submit(.generate(GenerateRequest(prompt: "When was Tillyburn founded?", maxTokens: 24, question: true)))
        let answered = await collector.wait(seconds: 300) { if case .session(.end) = $0 { return true }; if case .jobFailed(.generate, _) = $0 { return true }; return false }
        #expect(answered != nil)
        fold()
        let question = try #require(state.braid.current)
        #expect(question.gen.prompt.question != nil, "the commons' rewrite is logged on the gen line")
        #expect(question.end?.stoppedOn == .sentence || question.end?.stoppedOn == .max || question.end?.stoppedOn == .eos)
        print("live question: \(question.gen.prompt.text.debugDescription) ▸ \(question.text.debugDescription) · contexts \(question.gen.context?.count ?? 0)")
        let questionURL = try #require(state.braid.sessionURL)
        backend.submit(.verify(questionURL))
        _ = await collector.wait(seconds: 120) { if case .verified = $0 { return true }; if case .jobFailed(.verify, _) = $0 { return true }; return false }
        fold()
        let questionReport = try #require(state.braid.verify)
        print("live verify (question): \(questionReport.status) · \(questionReport.spansVerified)/\(questionReport.spans.count) spans")
        #expect(questionReport.status == .ok, "\(questionReport.issues.map(\.description))")
        await backend.shutdown()
    }
}
