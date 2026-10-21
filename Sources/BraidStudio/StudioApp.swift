//
//  StudioApp.swift
//  BraidStudio
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The studio as three pure functions over `StudioState`: `handle` (a key, tick, resize,
//        signal or backend event in, jobs out), `reduce` (backend events, the session lines among
//        them) and `render` (the header, the three screen tabs, the screen, the key hints, the
//        status bar and any overlay).
//  PIN:  Pure so tests drive it without a terminal or MLX. Keys go to an open overlay first, then
//        to a field being edited, then to the global keys, then to the screen. One shortest path
//        per outcome: no adjacent keys or options.
//

import BraidKit
import BraidTerminal
import Foundation

protocol StudioScreen {
    static func render(_ state: StudioState, _ frame: inout Frame, _ rect: Rect)
    /// Nil when the key means nothing on this screen.
    static func handle(_ key: KeyEvent, _ state: inout StudioState) -> [StudioJob]?
    static func hints(_ state: StudioState) -> [KeyHint]
}

public enum StudioApp {
    static func screen(_ screen: Screen) -> StudioScreen.Type {
        switch screen {
        case .braid: return BraidScreen.self
        case .aii: return AIIScreen.self
        case .doctor: return DoctorScreen.self
        }
    }

    /// What the studio asks for as soon as it opens: the braid.
    public static func initialJobs(_ state: StudioState) -> [StudioJob] { [.start] }

    // MARK: - Handle

    public static func handle(_ event: Event<StudioEvent>, state: inout StudioState) -> [StudioJob] {
        switch event {
        case .message(let message):
            return reduce(message, state: &state)
        case .tick(let date):
            return tick(date, state: &state)
        case .resize(let size):
            state.size = size
            return []
        case .signal(let signal):
            if signal == .interrupt { return requestQuit(&state) }
            state.quitCode = 130
            return [.cancel]
        case .inputClosed:
            state.quitCode = 0
            return [.cancel]
        case .key(let key):
            return handleKey(key, state: &state)
        }
    }

    static func handleKey(_ key: KeyEvent, state: inout StudioState) -> [StudioJob] {
        if key == KeyEvent(.ctrl("c")) { return requestQuit(&state) }
        if state.overlay != nil { return handleOverlay(key, state: &state) }
        if state.editing { return screen(state.screen).handle(key, &state) ?? [] }
        state.status.error = nil
        switch key.key {
        case .char(let c) where ("1"..."3").contains(c) && key.modifiers.isEmpty:
            guard let target = Screen(rawValue: Int(String(c))!) else { return [] }
            return go(to: target, state: &state)
        case .char("?"):
            state.overlay = .help
            return []
        case .char("q"):
            return requestQuit(&state)
        case .char("Q"):
            state.quitCode = 130
            return [.cancel]
        case .ctrl("l"):
            state.redraw = true
            return []
        default:
            return screen(state.screen).handle(key, &state) ?? []
        }
    }

    /// Switches screens and asks for whatever the new one shows and has not loaded yet.
    public static func go(to target: Screen, state: inout StudioState) -> [StudioJob] {
        guard target != state.screen else { return [] }
        state.screen = target
        switch target {
        case .braid: return []
        case .aii: return state.aii.status == nil && state.status.jobs[.aii] == nil ? [.aii] : []
        case .doctor: return !state.doctor.ran && state.status.jobs[.doctor] == nil ? [.doctor] : []
        }
    }

    static func requestQuit(_ state: inout StudioState) -> [StudioJob] {
        if state.fixtures || state.status.mlxJob == nil {
            state.quitCode = 0
            return [.cancel]
        }
        state.overlay = .confirmQuit
        return []
    }

    static func handleOverlay(_ key: KeyEvent, state: inout StudioState) -> [StudioJob] {
        guard let overlay = state.overlay else { return [] }
        switch overlay {
        case .help:
            state.overlay = nil
            return []
        case .confirmQuit:
            switch key.key {
            case .char("y"), .enter:
                state.overlay = .cancelling(since: state.now)
                state.quitAfterJobs = true
                return [.cancel]
            case .char("Q"):
                state.quitCode = 130
                return [.cancel]
            default:
                state.overlay = nil
                return []
            }
        case .cancelling:
            if key.key == .char("Q") { state.quitCode = 130 }
            return []
        case .picker(var picker):
            let visible = max(1, min(picker.items.count, state.size.height - 10))
            switch key.key {
            case .up, .char("k"): picker.table.move(by: -1, rowCount: picker.items.count, visible: visible)
            case .down, .char("j"): picker.table.move(by: 1, rowCount: picker.items.count, visible: visible)
            case .pageUp: picker.table.page(by: -1, rowCount: picker.items.count, visible: visible)
            case .pageDown: picker.table.page(by: 1, rowCount: picker.items.count, visible: visible)
            case .escape, .char("q"):
                state.overlay = nil
                return []
            case .enter:
                state.overlay = nil
                guard let index = picker.table.selected, index < picker.values.count else { return [] }
                return [.openSession(picker.values[index])]
            default: break
            }
            state.overlay = .picker(picker)
            return []
        case .newThread(var form):
            switch key.key {
            case .escape:
                state.overlay = nil
                return []
            case .tab, .backTab, .up, .down:
                form.field = 1 - form.field
            case .enter:
                let name = form.name.text.trimmingCharacters(in: .whitespaces)
                let corpus = form.corpus.text.trimmingCharacters(in: .whitespaces)
                if name.isEmpty || !DocumentID.isValidHandle(name) {
                    form.error = "the name is a lowercase handle (letters, digits, dashes)"
                } else if !(corpus.hasPrefix("dataset:") && corpus.contains("#")) && !corpus.hasPrefix("dir:") {
                    form.error = "the source is dataset:<name>#<node> or dir:<path>"
                } else if state.braid.threads.contains(where: { $0.name == name }) {
                    form.error = "a Thread named \(name) exists"
                } else {
                    state.overlay = nil
                    state.status.message = "creating \(name) from \(corpus): snapshot, training, index"
                    return [.createThread(NewThreadRequest(name: name, corpus: corpus))]
                }
            default:
                if form.field == 0 ? form.name.handle(key) : form.corpus.handle(key) { form.error = nil }
            }
            state.overlay = .newThread(form)
            return []
        }
    }

    static func tick(_ date: Date, state: inout StudioState) -> [StudioJob] {
        state.now = date
        state.spinner &+= 1
        if case .cancelling(let since) = state.overlay {
            if state.status.mlxJob == nil {
                state.quitCode = 0
            } else if date.timeIntervalSince(since) > 15 {
                state.quitCode = 130
            }
        }
        return []
    }

    // MARK: - Reduce

    public static func reduce(_ event: StudioEvent, state: inout StudioState) -> [StudioJob] {
        switch event {
        case .jobStarted(let kind, let label):
            state.status.jobs[kind] = JobStatus(kind: kind, label: label, since: state.now)
        case .jobProgress(let kind, let label):
            state.status.jobs[kind]?.label = label
        case .jobFinished(let kind):
            state.status.jobs[kind] = nil
            if kind == .generate { state.braid.generating = false }
        case .jobFailed(let kind, let failure):
            state.status.jobs[kind] = nil
            if failure.code == .interrupted {
                state.status.message = "\(kind.rawValue) cancelled"
            } else {
                state.status.error = failure
            }
            state.braid.events.append("\(kind.rawValue): \(failure.message)")
            if kind == .generate { state.braid.generating = false }
            if kind == .membership || kind == .createThread { state.braid.pending = [] }
        case .log(let message):
            state.status.message = message
            state.braid.events.append(message)
        case .braid(let status):
            state.braid.status = status
            let strands = status.strands.isEmpty ? "no strands" : status.strands.joined(separator: ", ")
            state.braid.events.append("braid: \(status.packName ?? "no pack") · \(strands)" + (status.seamSHA256.map { " · trunk \($0.prefix(12))" } ?? "") + (status.fixtures ? " · fixtures" : ""))
            return [.examples]
        case .threads(let threads):
            state.braid.threads = threads
            state.braid.pending = []
            state.braid.focus = min(state.braid.focus, max(0, threads.count - 1))
            if var status = state.braid.status {
                status.strands = (status.commons ? ["commons"] : []) + threads.filter(\.attached).map(\.name)
                state.braid.status = status
            }
        case .table(let strands, let partitions, let session):
            state.braid.pendingStrands = strands
            state.braid.pendingPartitions = partitions
            if let session { state.braid.sessionURL = session }
        case .session(let line):
            return applySession(line, state: &state)
        case .verified(let report):
            state.braid.verify = report
            if var current = state.braid.current {
                current.verification = Dictionary(report.spans.filter { $0.generationID == current.gen.generationID }.map { ($0.span, $0) },
                                                  uniquingKeysWith: { first, _ in first })
                state.braid.current = current
            }
            let issues = report.issues.count
            let message = "\(report.spansVerified)/\(report.spans.count) spans verified" + (issues > 0 ? " · \(issues) issue\(issues == 1 ? "" : "s")" : "")
                + (report.status == .ok ? "" : " · FAILED")
            state.status.message = message
            state.braid.events.append("verify: " + message)
            for note in report.notes { state.braid.events.append("verify: " + note) }
        case .examples(let examples):
            state.braid.examples = examples
            state.braid.exampleIndex = -1
            if !examples.isEmpty, state.braid.prompt.text.isEmpty, !state.braid.editingPrompt { BraidScreen.choose(example: 0, state: &state) }
        case .sessions(let urls):
            state.braid.sessions = urls
            if urls.isEmpty {
                state.status.message = "no saved sessions yet: ⏎ asks the braid and writes one"
            } else {
                state.overlay = .picker(Picker(title: "Saved sessions · \(urls.count)", items: urls.map { $0.deletingPathExtension().lastPathComponent }, values: urls))
            }
        case .aii(let status):
            state.aii.status = status
        case .doctor(let checks):
            state.doctor.checks = checks
            state.doctor.ran = true
        }
        return []
    }

    /// A session line, live or replayed: the one path a generation renders through.
    static func applySession(_ line: SessionLine, state: inout StudioState) -> [StudioJob] {
        switch line {
        case .header(let header):
            state.braid.header = header
            if state.braid.pendingStrands.isEmpty { state.braid.pendingStrands = header.threads }
        case .gen(let gen):
            let strands = state.braid.pendingStrands.isEmpty ? (state.braid.header?.threads ?? []) : state.braid.pendingStrands
            state.braid.current = GenerationView(gen: gen, strands: strands, partitions: state.braid.pendingPartitions)
            state.braid.generating = true
            state.braid.cursor = 0
            state.braid.verify = nil
            state.braid.events.append("asked \(gen.prompt.text.debugDescription) · λ \(Theme.f(gen.params.lambda)) · \(gen.strands.joined(separator: ", "))")
        case .step(let step):
            guard var current = state.braid.current else { return [] }
            current.append(step)
            state.braid.current = current
            if state.braid.generating { state.braid.cursor = max(0, current.walkable.count - 1) }
        case .membership(let membership):
            // Only a running generation's strands move; a change between answers shows in the next header.
            if state.braid.current?.isComplete == false { state.braid.current?.apply(membership) }
            let detail = membership.kind == "attach" ? " (caught up \(membership.caughtUp) tokens in \(Theme.f(membership.seconds, 1)) s)" : ""
            state.braid.events.append("\(membership.kind) \(membership.thread.name) at position \(membership.position)\(detail)")
        case .end(let end):
            guard var current = state.braid.current else { return [] }
            current.end = end
            current.derive()
            state.braid.current = current
            state.braid.generating = false
            state.braid.cursor = current.firstGenerated
            state.braid.events.append("\(end.generated) tokens · stopped on \(end.stoppedOn?.rawValue ?? "?") · \(end.generationID)")
            state.status.message = "←→ walk the tokens · v verifies the spans · R royalties"
        }
        return []
    }

    // MARK: - Render

    public static func render(_ state: StudioState, _ frame: inout Frame) {
        let palette = frame.palette
        let glyphs = frame.glyphs
        let (top, afterHeader) = frame.bounds.top(1)
        CompactHeader(title: headerTitle(state, palette: palette), status: headerStatus(state, palette: palette, glyphs: glyphs),
                      palette: palette, glyphs: glyphs).render(in: top, on: &frame.canvas)
        let (tabsRow, afterTabs) = afterHeader.top(1)
        renderTabs(state, &frame, tabsRow)
        let (statusRow, aboveStatus) = afterTabs.bottom(1)
        let (hintsRow, screenRect) = aboveStatus.bottom(1)
        screen(state.screen).render(state, &frame, screenRect)
        KeyHintBar(screen(state.screen).hints(state) + globalHints(state), keyStyle: palette.hintKey, labelStyle: palette.hintLabel)
            .render(in: hintsRow, on: &frame.canvas)
        renderStatus(state, &frame, statusRow)
        if let overlay = state.overlay { renderOverlay(overlay, state, &frame) }
    }

    static func globalHints(_ state: StudioState) -> [KeyHint] {
        state.editing ? [] : [KeyHint("1-3", "screens"), KeyHint("?", "help"), KeyHint("q", "quit")]
    }

    static func headerTitle(_ state: StudioState, palette: Palette) -> Text {
        var text = Text("\(state.screen.rawValue) \(state.screen.title)", style: palette.title)
        let detail: String?
        switch state.screen {
        case .braid:
            if let status = state.braid.status {
                detail = "\(status.packName ?? "no pack") · \(status.strands.count) strand\(status.strands.count == 1 ? "" : "s") · λ \(Theme.f(state.braid.lambda))"
            } else {
                detail = nil
            }
        case .aii: detail = state.aii.status.map { Theme.abbreviate($0.machine.path) }
        case .doctor: detail = state.doctor.ran ? "\(state.doctor.checks.filter(\.ok).count)/\(state.doctor.checks.count) ok" : nil
        }
        if let detail { text.append(" · " + detail, palette.dim) }
        return text
    }

    static func headerStatus(_ state: StudioState, palette: Palette, glyphs: Glyphs) -> Text {
        if let job = state.status.headline {
            return Text(spinner(state, glyphs) + " ", style: palette.orange) + Text(job.label, style: palette.dim)
        }
        return state.fixtures ? Text("fixtures", style: palette.orange) : Text("v" + state.version, style: palette.dim)
    }

    static func spinner(_ state: StudioState, _ glyphs: Glyphs) -> String {
        glyphs.spinner[state.spinner % glyphs.spinner.count]
    }

    static func renderTabs(_ state: StudioState, _ frame: inout Frame, _ rect: Rect) {
        let palette = frame.palette
        let busy = Set(state.status.jobs.values.filter(\.kind.isVisible).map { Screen.owner(of: $0.kind) })
        let titles: [Text] = Screen.allCases.map { screen in
            let chosen = screen == state.screen
            var text = Text("\(screen.rawValue) ", style: chosen ? palette.gold : palette.muted)
            text.append(screen.title, chosen ? palette.blue.bold() : palette.dim)
            if busy.contains(screen) { text.append(" " + spinner(state, frame.glyphs), palette.orange) }
            return text
        }
        Tabs(titles, selected: state.screen.rawValue - 1, style: palette.dim, selectedStyle: palette.blue.bold(),
             separator: Text("   ", style: palette.dim)).render(in: rect, on: &frame.canvas)
    }

    static func renderStatus(_ state: StudioState, _ frame: inout Frame, _ rect: Rect) {
        let palette = frame.palette
        let glyphs = frame.glyphs
        frame.canvas.fill(rect, style: palette.selection.removing([.bold, .reverse]).fg(palette.dim.foreground))
        let band = palette.selection.background
        func on(_ style: Style) -> Style { band == .default ? style : style.bg(band) }
        var left = Text(" ", style: on(palette.dim))
        if state.fixtures { left.append("fixtures  ", on(palette.orange)) }
        if let status = state.braid.status {
            left.append("braid ", on(palette.dim))
            left.append(status.strands.isEmpty ? glyphs.idle : glyphs.live, on(status.strands.isEmpty ? palette.muted : palette.green))
            left.append(" \(status.strands.count)", on(palette.dim))
        } else {
            left.append("braid \(glyphs.idle)", on(palette.dim))
        }
        if let job = state.status.headline {
            left.append("  ", on(palette.dim))
            left.append(spinner(state, glyphs) + " ", on(palette.orange))
            left.append(job.label, on(palette.text))
        } else if let area = state.braid.status?.workArea {
            left.append("  " + Theme.abbreviate(area), on(palette.muted))
        }
        var right = Text()
        if let error = state.status.error {
            right.append("braid: " + error.message, on(palette.error))
            if let hint = error.hint { right.append(" — " + hint, on(palette.dim)) }
        } else if let message = state.status.message {
            right.append(message, on(palette.dim))
        }
        let leftWidth = min(left.width, rect.width * 3 / 5)
        frame.canvas.put(left.truncated(to: leftWidth), x: rect.minX, y: rect.minY, clip: rect)
        let rightRoom = max(0, rect.width - leftWidth - 3)
        let shown = right.truncated(to: rightRoom)
        frame.canvas.put(shown, x: rect.maxX - shown.width - 1, y: rect.minY, clip: rect)
    }

    // MARK: - Overlays

    static func renderOverlay(_ overlay: Overlay, _ state: StudioState, _ frame: inout Frame) {
        let palette = frame.palette
        let glyphs = frame.glyphs
        frame.canvas.restyle(frame.bounds) { $0.adding(.dim) }
        switch overlay {
        case .help:
            let width = min(frame.size.width - 4, 104)
            let lines = helpLines(glyphs, width: width - 5)
            let rect = frame.bounds.centered(width: width, height: min(frame.size.height - 2, lines.count + 2))
            frame.canvas.fill(rect, style: palette.base)
            let inner = Box(title: Text("Help", style: palette.title), footer: Text("any key closes", style: palette.dim),
                            style: palette.focusBorder, glyphs: glyphs).render(in: rect, on: &frame.canvas)
            for (row, line) in lines.prefix(inner.height).enumerated() {
                frame.canvas.put(line.truncated(to: inner.width - 1), x: inner.minX + 1, y: inner.minY + row, clip: inner)
            }
        case .confirmQuit:
            let label = state.status.headline?.label ?? "a job"
            dialog("Quit", [
                Text("\(label) is still running on the MLX worker.", style: palette.text),
                Text(""),
                Text("[y] cancel it and quit    [Q] quit now    [esc] stay", style: palette.dim),
            ], &frame)
        case .cancelling:
            dialog("Quitting", [
                Text(spinner(state, glyphs) + " waiting for the running work to stop…", style: palette.orange),
                Text(""),
                Text("[Q] quit now", style: palette.dim),
            ], &frame)
        case .picker(let picker):
            let width = min(frame.size.width - 8, max(50, (picker.items.map(\.count).max() ?? 20) + 10))
            let height = min(frame.size.height - 6, picker.items.count + 2)
            let rect = frame.bounds.centered(width: width, height: max(3, height))
            frame.canvas.fill(rect, style: palette.base)
            let inner = Box(title: Text(picker.title, style: palette.title), footer: Text("⏎ replay  esc close", style: palette.dim),
                            style: palette.focusBorder, glyphs: glyphs).render(in: rect, on: &frame.canvas)
            Table.styled(columns: [Column("", .flex(1))], rows: picker.items.map { [Text($0)] }, state: picker.table,
                         palette: palette, glyphs: glyphs, showHeader: false).render(in: inner, on: &frame.canvas)
        case .newThread(let form):
            let notes = [
                Text("The source is a dataset node, dataset:<name>#<node> (braid-n3#ambient), or a folder of .txt files, dir:<path>.", style: palette.dim),
                Text("The Thread is snapshotted, its own blocks 0–11 trained behind the commons' trunk, indexed, made live and attached — the braid thread create path.", style: palette.dim),
            ] + (form.error.map { [Text("\(glyphs.cross) \($0)", style: palette.red)] } ?? [])
            let rect = frame.bounds.centered(width: min(frame.size.width - 4, 100), height: notes.count + 7)
            frame.canvas.fill(rect, style: palette.base)
            let inner = Box(title: Text("New Thread", style: palette.title), footer: Text("tab next field  ⏎ create  esc cancel", style: palette.dim),
                            style: palette.focusBorder, glyphs: glyphs).render(in: rect, on: &frame.canvas)
            frame.cursor = nil
            for (row, (label, field, focused)) in [("name", form.name, form.field == 0), ("source", form.corpus, form.field == 1)].enumerated() {
                let y = inner.minY + 1 + row
                frame.canvas.put(label, x: inner.minX + 2, y: y, style: focused ? palette.title : palette.dim, clip: inner)
                let fieldRect = Rect(x: inner.minX + 10, y: y, width: max(0, inner.width - 12), height: 1)
                TextField(state: field, placeholder: row == 0 ? "a lowercase handle" : "dataset:<name>#<node>", focused: focused, style: palette.title,
                          placeholderStyle: palette.muted, cursorStyle: palette.cursor).render(in: fieldRect, on: &frame.canvas)
            }
            for (row, note) in notes.enumerated() {
                frame.canvas.put(note.truncated(to: inner.width - 4), x: inner.minX + 2, y: inner.minY + 4 + row, clip: inner)
            }
        }
    }

    static func dialog(_ title: String, _ lines: [Text], _ frame: inout Frame) {
        let palette = frame.palette
        let width = min(frame.size.width - 4, max(40, (lines.map(\.width).max() ?? 30) + 6))
        let rect = frame.bounds.centered(width: width, height: lines.count + 4)
        frame.canvas.fill(rect, style: palette.base)
        let inner = Box(title: Text(title, style: palette.title), style: palette.focusBorder, glyphs: frame.glyphs)
            .render(in: rect, on: &frame.canvas)
        for (row, line) in lines.enumerated() {
            frame.canvas.put(line, x: inner.minX + 2, y: inner.minY + 1 + row, clip: inner)
        }
    }

    static func helpLines(_ glyphs: Glyphs, width: Int = 94) -> [Text] {
        let sections: [(String, [(String, String)])] = [
            ("screens", [("1 Braid", "the braid: ask, walk the tokens, attach and detach Threads"), ("2 AII", "the machine's AII and the demo AIIs"), ("3 Doctor", "the checks braid doctor runs")]),
            ("braid", [("/ p", "type a prompt"), ("⏎", "ask"), ("tab ⇧tab", "focus a Thread"), ("space", "attach or detach it"), ("n", "new Thread"),
                       ("R", "royalties: shares or credit"), ("←→", "walk the tokens"), ("v", "verify the spans"), ("o", "open a saved session"),
                       ("x", "next example prompt"), ("r", "Q/A on or off"), ("t", "likeliest or sampled"), ("- +", "λ"), ("c", "cancel")]),
            ("aii", [("r", "refresh")]),
            ("doctor", [("r", "run the checks again")]),
            ("global", [("1-3", "screens"), ("?", "this help"), ("^L", "redraw"), ("q", "quit"), ("Q", "quit now")]),
        ]
        var lines: [Text] = []
        for (title, entries) in sections {
            var line = Text(title.padding(toLength: 10, withPad: " ", startingAt: 0), style: .plain)
            for (key, label) in entries {
                line.append("[" + key + "] ", .plain)
                line.append(label + "   ", .plain)
            }
            lines.append(contentsOf: hanging(line, width: width))
        }
        lines.append(Text(""))
        for line in [
            "tokens    coloured by the strand that supplied ≥ 0.6 of them · gold = the commons · off-white = shared · dim = uncited · underlined = verified span · reverse = cursor",
            "detail    token «…» ← who supplied it, every share, p, H_gate · trace in-doc/off-trace, H_knn and H_lm with their one-step deltas, the shadow β4 share (never applied) · the citation",
            "legend    \(glyphs.check) ok  \(glyphs.cross) fail  \(glyphs.live) attached  \(glyphs.idle) detached  \(glyphs.spinner[0]) busy  \(glyphs.verified) verified  \(glyphs.select) focused",
            "",
            "cli       braid doctor · init · import · pack · thread create|list|show · cluster spawn · verify · ui --fixtures <dir>",
        ] { lines.append(contentsOf: hanging(Text(line), width: width)) }
        return lines
    }

    /// Wraps with a 10-column hanging indent under the section label.
    static func hanging(_ line: Text, width: Int) -> [Text] {
        guard !line.isEmpty else { return [line] }
        let first = Paragraph.wrap(line, width: max(20, width))
        guard first.count > 1 else { return first }
        var result = [first[0]]
        let remainder = first.dropFirst().reduce(Text()) { $0 + Text(" ") + $1 }
        for piece in Paragraph.wrap(remainder, width: max(10, width - 10)) {
            result.append(Text("          ") + piece)
        }
        return result
    }
}
