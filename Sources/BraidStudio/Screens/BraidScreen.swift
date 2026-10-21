//
//  BraidScreen.swift
//  BraidStudio
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: 1 Braid, the main screen: the answer strip (the prompt dim, ▸, every generated token
//        coloured by the strand that supplied it), the detail block for the token under the cursor
//        (who supplied it and every share, its trace and both entropies with their deltas, the
//        shadow β4 share, its citation and verification), the Threads pane (attached or detached,
//        live share bars, Σ share), the Royalties pane (shares or credit, per strand and per cited
//        document), the prompt line and the Events pane.
//  PIN:  Everything drawn comes from the session's log lines and the views derived from them; a
//        replayed session looks exactly like the live one did.
//

import BraidKit
import BraidTerminal
import Foundation

enum BraidScreen: StudioScreen {
    // MARK: - Examples

    static func choose(example index: Int, state: inout StudioState) {
        let examples = state.braid.examples
        guard !examples.isEmpty else { return }
        let i = (index % examples.count + examples.count) % examples.count
        state.braid.exampleIndex = i
        state.braid.prompt.set(examples[i].prompt)
        state.status.message = "example \(i + 1)/\(examples.count) · \(examples[i].thread) · \(examples[i].label) · expects \(examples[i].expected.trimmingCharacters(in: .whitespaces))"
    }

    // MARK: - Keys

    static func handle(_ key: KeyEvent, _ state: inout StudioState) -> [StudioJob]? {
        if state.braid.editingPrompt {
            switch key.key {
            case .escape:
                state.braid.editingPrompt = false
            case .enter:
                state.braid.editingPrompt = false
                return ask(&state)
            default:
                if state.braid.prompt.handle(key) { state.braid.exampleIndex = -1 }
            }
            return []
        }
        switch key.key {
        case .char("/"), .char("p"):
            state.braid.editingPrompt = true
        case .enter:
            return ask(&state)
        case .tab, .backTab:
            let count = state.braid.threads.count
            guard count > 0 else { return [] }
            state.braid.focus = (state.braid.focus + (key.key == .tab ? 1 : count - 1)) % count
        case .char(" "):
            return toggleMembership(&state)
        case .char("n"):
            state.overlay = .newThread(NewThreadForm())
        case .char("R"):
            state.braid.royalties = state.braid.royalties == .shares ? .credit : .shares
            state.status.message = state.braid.royalties == .shares
                ? "royalties by share: the tokens each strand led and its summed share"
                : "royalties by credit: form tokens are the commons', content tokens each strand's, weighted by bits; then per cited document"
        case .left, .char("h"):
            state.braid.cursor = max(0, state.braid.cursor - 1)
        case .right, .char("l"):
            state.braid.cursor = min(max(0, (state.braid.current?.walkable.count ?? 1) - 1), state.braid.cursor + 1)
        case .home:
            state.braid.cursor = 0
        case .end:
            state.braid.cursor = max(0, (state.braid.current?.walkable.count ?? 1) - 1)
        case .char("v"):
            guard let url = state.braid.sessionURL, state.braid.current?.isComplete == true, !state.braid.generating else {
                state.status.message = state.braid.current == nil ? "nothing to verify yet: ⏎ asks the braid" : "wait for the answer to finish"
                return []
            }
            return [.verify(url)]
        case .char("o"):
            return [.sessions]
        case .char("x"):
            guard !state.braid.examples.isEmpty else {
                state.status.message = "no example prompts: a Thread from a dataset node (dataset:<name>#<node>) carries facts"
                return []
            }
            choose(example: state.braid.exampleIndex + 1, state: &state)
        case .char("r"):
            state.braid.questions.toggle()
            state.status.message = state.braid.questions
                ? "Q/A on: a prompt ending in \"?\" is rewritten into a stem (the flag is recorded; the stem adapter arrives with the question step)"
                : "Q/A off: every prompt is completed as written, a question too"
        case .char("t"):
            state.braid.temperature = state.braid.temperature > 0 ? 0 : 0.8
            state.status.message = state.braid.temperature > 0
                ? "sampling: each token is drawn from the mixture, so every strand gets chosen in proportion"
                : "the likeliest token each time"
        case .char("-"), .char("_"):
            state.braid.lambda = max(0, (state.braid.lambda * 20 - 1).rounded() / 20)
            state.status.message = String(format: "λ %.2f: the next answer leans %@ on retrieval", state.braid.lambda, state.braid.lambda < 0.5 ? "less" : "more")
        case .char("+"), .char("="):
            state.braid.lambda = min(1, (state.braid.lambda * 20 + 1).rounded() / 20)
            state.status.message = String(format: "λ %.2f: the next answer leans %@ on retrieval", state.braid.lambda, state.braid.lambda < 0.5 ? "less" : "more")
        case .char("c"):
            guard state.braid.generating || state.status.mlxJob != nil else {
                state.status.message = "nothing is running"
                return []
            }
            return [.cancel]
        default:
            return nil
        }
        return []
    }

    static func ask(_ state: inout StudioState) -> [StudioJob] {
        guard state.braid.ready || state.fixtures else {
            state.status.error = BraidFailure.unavailable("the braid is not up", hint: state.braid.status == nil ? "it is still loading, or the start failed (see the Events pane)" : "attach a Thread with space, or create one with n")
            return []
        }
        if let job = state.status.mlxJob {
            state.status.error = BraidFailure.temporary("the MLX worker is busy: \(job.label)", hint: "c cancels a generation")
            return []
        }
        let text = state.braid.prompt.text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            state.status.error = BraidFailure.usage("the prompt is empty", hint: "/ types one, x takes a fact prompt")
            return []
        }
        let question = state.braid.questions && text.hasSuffix("?")
        state.braid.generating = true
        state.status.message = "asking \(state.braid.status?.strands.count ?? 0) strands…"
        return [.generate(GenerateRequest(prompt: text, lambda: state.braid.lambda, temperature: state.braid.temperature, maxTokens: 24, question: question))]
    }

    static func toggleMembership(_ state: inout StudioState) -> [StudioJob] {
        guard let thread = state.braid.focusedThread else {
            state.status.message = "no Threads in the work area: n creates one"
            return []
        }
        guard !state.braid.pending.contains(thread.name) else { return [] }
        if let error = thread.error, !thread.attached {
            state.status.error = BraidFailure.data("\(thread.name) cannot attach: \(error)")
            return []
        }
        state.braid.pending.insert(thread.name)
        state.status.message = thread.attached
            ? "detaching \(thread.name)" + (state.braid.generating ? " at the next token boundary" : "")
            : "attaching \(thread.name)" + (state.braid.generating ? " at the next token boundary (it catches up on the session so far)" : "")
        return [thread.attached ? .detach(thread.name) : .attach(thread.name)]
    }

    static func hints(_ state: StudioState) -> [KeyHint] {
        if state.braid.editingPrompt { return [KeyHint("⏎", "ask"), KeyHint("esc", "done")] }
        var hints = [KeyHint("⏎", "ask"), KeyHint("/", "prompt"), KeyHint("tab", "Thread"), KeyHint("space", "attach/detach"), KeyHint("n", "new Thread"),
                     KeyHint("R", state.braid.royalties == .shares ? "credit" : "shares"), KeyHint("←→", "token")]
        if state.braid.current?.isComplete == true { hints.append(KeyHint("v", "verify")) }
        hints += [KeyHint("o", "open"), KeyHint("x", "example"), KeyHint("r", state.braid.questions ? "Q/A on" : "Q/A off"),
                  KeyHint("t", state.braid.temperature > 0 ? "sampled" : "likeliest"), KeyHint("-+", "λ")]
        if state.braid.generating { hints.append(KeyHint("c", "cancel")) }
        return hints
    }

    // MARK: - Colours

    /// A Thread's strand colour: its place in the Threads pane.
    static func threadColor(_ name: String, _ state: StudioState, _ palette: Palette) -> Color? {
        state.braid.threads.firstIndex { $0.name == name }.map { BraidArt.strandColor($0, palette) }
    }

    /// A strand's colour in the generation shown: gold for the commons, its Thread's otherwise.
    static func colour(_ strand: Int, view: GenerationView, state: StudioState, palette: Palette) -> Color {
        guard strand < view.strands.count else { return palette.line }
        let record = view.strands[strand]
        if record.commons { return palette.goldColor }
        if let colour = threadColor(record.name, state, palette) { return colour }
        let threads = view.strands.indices.filter { !view.strands[$0].commons }
        return BraidArt.strandColor(threads.firstIndex(of: strand) ?? strand, palette)
    }

    static func display(_ text: String, _ glyphs: Glyphs) -> String { text.replacingOccurrences(of: "\n", with: glyphs.newline) }

    // MARK: - Render

    static func render(_ state: StudioState, _ frame: inout Frame, _ rect: Rect) {
        let compact = rect.height < 30
        let (topRect, below) = rect.top(min(compact ? 7 : 9, rect.height))
        renderBraid(state, &frame, topRect, compact: compact)
        let hasCommons = state.braid.status?.commons ?? (state.braid.current?.commons != nil)
        // The panes' tables: a border, a header and its rule, then one row per strand.
        let rows = state.braid.threads.count + (hasCommons ? 1 : 0)
        let middleHeight = min(max(0, below.height - 5), max(5, 4 + rows))
        let (middleRect, bottomRect) = below.top(middleHeight)
        let middle = middleRect.splitHorizontally([.flex(3), .flex(2)])
        renderThreads(state, &frame, middle[0])
        renderRoyalties(state, &frame, middle[1])
        if bottomRect.height >= 3 { renderBottom(state, &frame, bottomRect) }
    }

    // MARK: The braid: the strip and the detail block

    static func renderBraid(_ state: StudioState, _ frame: inout Frame, _ rect: Rect, compact: Bool) {
        let palette = frame.palette
        let glyphs = frame.glyphs
        var title = "Braid"
        if let status = state.braid.status {
            title += " · \(status.packName ?? "no pack")"
        }
        title += String(format: " · λ %.2f · %@ · Q/A %@", state.braid.lambda, state.braid.temperature > 0 ? "sampled" : "likeliest", state.braid.questions ? "on" : "off")
        var footer: Text? = nil
        if let url = state.braid.sessionURL {
            footer = Text("session " + url.deletingPathExtension().lastPathComponent, style: palette.dim)
        } else if state.fixtures {
            footer = Text("fixtures", style: palette.orange)
        }
        let inner = Theme.panel(title, focused: !state.braid.editingPrompt, footer: footer, &frame, rect)
        guard !inner.isEmpty else { return }
        let stripHeight = min(compact ? 2 : 3, inner.height)
        let strip = Rect(x: inner.minX, y: inner.minY, width: inner.width, height: stripHeight)
        renderStrip(state, &frame, strip)
        let detail = inner.inset(top: stripHeight, left: 0, bottom: 0, right: 0)
        guard !detail.isEmpty else { return }
        guard let view = state.braid.current, !view.walkable.isEmpty else {
            if state.braid.generating {
                Theme.rows([Text("\(StudioApp.spinner(state, glyphs)) the braid is asking the strands…", style: palette.orange)], &frame, detail)
            } else if state.braid.status == nil {
                Theme.empty("starting the braid: loading the pack, the commons and the Threads braid.toml attaches…", &frame, detail)
            } else if state.braid.ready {
                Theme.empty("⏎ asks the braid · / types a prompt · x takes a fact prompt from a Thread · o replays a saved session · space attaches or detaches the focused Thread", &frame, detail)
            } else {
                Theme.empty("no strands attached: space attaches the focused Thread, n creates one from a dataset node", &frame, detail)
            }
            return
        }
        let cursor = min(state.braid.cursor, view.walkable.count - 1)
        let k = view.walkable[cursor]
        let styles = DetailStyles(text: palette.text, title: palette.title, dim: palette.dim, muted: palette.muted, gold: palette.gold, red: palette.red,
                                  strand: { Style(foreground: colour($0, view: view, state: state, palette: palette), background: palette.base.background) })
        Theme.rows(TokenDetail.styled(view, shared: k, styles: styles, glyphs: glyphs), &frame, detail)
    }

    static func renderStrip(_ state: StudioState, _ frame: inout Frame, _ rect: Rect) {
        let palette = frame.palette
        let glyphs = frame.glyphs
        guard !rect.isEmpty else { return }
        var pieces: [(String, Style)] = []
        if let view = state.braid.current {
            let shared = view.shared
            let cursor = min(state.braid.cursor, max(0, view.walkable.count - 1))
            var sawGenerated = false
            for (w, k) in view.walkable.enumerated() {
                let step = shared[k]
                var style: Style
                if step.isPrompt {
                    style = palette.dim
                } else {
                    if !sawGenerated {
                        pieces.append((" ", palette.dim))
                        pieces.append((glyphs.prompt, palette.gold))
                        sawGenerated = true
                    }
                    let annotation = view.annotation(shared: k)
                    style = BraidArt.tokenStyle(step: step, uncited: annotation?.uncited ?? true, commons: view.commons,
                                                colour: { colour($0, view: view, state: state, palette: palette) }, palette: palette)
                    if view.isVerified(spanIndex: annotation?.spanIndex) { style = style.underline() }
                }
                if w == cursor { style = style.reverse() }
                pieces.append((display(step.text, glyphs), style))
            }
            if !sawGenerated, state.braid.generating {
                pieces.append((" ", palette.dim))
                pieces.append((glyphs.prompt, palette.gold))
            }
            if state.braid.generating { pieces.append((" " + StudioApp.spinner(state, glyphs), palette.gold)) }
        } else {
            let text = state.braid.prompt.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { pieces.append((text, palette.dim)) }
            if state.braid.generating { pieces.append((" " + glyphs.prompt + " " + StudioApp.spinner(state, glyphs), palette.gold)) }
        }
        // Wrap, keeping the cursor's line in view; a token that fits on a line is not split across two.
        var lines: [[(String, Style)]] = [[]]
        var width = 0
        var cursorLine = 0
        for (text, style) in pieces {
            let tokenWidth = TerminalWidth.of(text)
            if style != palette.dim, tokenWidth <= rect.width, width + tokenWidth > rect.width {
                lines.append([])
                width = 0
            }
            for scalar in text.unicodeScalars {
                let w = TerminalWidth.of(scalar)
                if width + w > rect.width {
                    lines.append([])
                    width = 0
                }
                lines[lines.count - 1].append((String(Character(scalar)), style))
                width += w
            }
            if style.attributes.contains(.reverse) { cursorLine = lines.count - 1 }
        }
        let first = max(0, min(max(cursorLine - rect.height + 1, lines.count - rect.height), lines.count - rect.height))
        for (row, line) in lines.dropFirst(first).prefix(rect.height).enumerated() {
            var x = rect.minX
            for (piece, style) in line { x += frame.canvas.put(piece, x: x, y: rect.minY + row, style: style, clip: rect) }
        }
    }

    // MARK: The Threads pane

    static func shareCell(_ strand: Int?, view: GenerationView?, colour: Color, palette: Palette, glyphs: Glyphs, width: Int) -> Text {
        guard let strand, let view, strand < view.strands.count, let royalties = view.royalties, royalties.generated > 0,
              let line = royalties.strands.first(where: { $0.name == view.strands[strand].name }) else { return Text("—", style: palette.muted) }
        let mean = line.share / Double(royalties.generated)
        var text = ShareBar(segments: [(mean, colour)], track: palette.muted, glyphs: glyphs).text(width: max(4, width - 8))
        text.append(" Σ " + Theme.f(line.share), palette.text)
        return text
    }

    static func renderThreads(_ state: StudioState, _ frame: inout Frame, _ rect: Rect) {
        let palette = frame.palette
        let glyphs = frame.glyphs
        let inner = Theme.panel("Threads · tab focuses · space attaches/detaches · n new", &frame, rect)
        guard !inner.isEmpty else { return }
        let view = state.braid.current
        let hasCommons = state.braid.status?.commons ?? (view?.commons != nil)
        let wide = inner.width >= 60
        let shareWidth = 16
        var rows: [[Text]] = []
        if hasCommons {
            rows.append([
                Text("Commons", style: Style(foreground: palette.goldColor, background: palette.base.background, attributes: .bold)),
                Text((state.braid.status?.packName ?? "the pack") + (state.braid.status?.seamSHA256.map { " · trunk \($0.prefix(12)), every Thread's" } ?? ""), style: palette.dim),
                Text("\(glyphs.live) commons", style: palette.gold),
                shareCell(view?.commons, view: view, colour: palette.goldColor, palette: palette, glyphs: glyphs, width: shareWidth),
            ])
        }
        for (index, thread) in state.braid.threads.enumerated() {
            let colour = BraidArt.strandColor(index, palette)
            let tint = Style(foreground: colour, background: palette.base.background)
            let strand = view?.strands.firstIndex { $0.name == thread.name && !$0.commons }
            let status: Text
            if state.braid.pending.contains(thread.name) {
                status = Text("\(StudioApp.spinner(state, glyphs)) \(thread.attached ? "detaching" : "attaching")", style: palette.orange)
            } else if let error = thread.error, !thread.attached {
                status = Text("\(glyphs.cross) \(error)", style: palette.red)
            } else if thread.attached {
                status = Text("\(glyphs.live) attached", style: tint)
            } else {
                status = Text("\(glyphs.idle) detached", style: palette.muted)
            }
            var source = thread.source
            if source.hasPrefix("dataset:") { source = String(source.dropFirst(8)) }
            rows.append([
                Text(thread.label, style: thread.attached ? tint.bold() : palette.muted),
                Text(source + (thread.version.map { " · " + $0 } ?? ""), style: palette.dim),
                status,
                shareCell(strand, view: view, colour: colour, palette: palette, glyphs: glyphs, width: shareWidth),
            ])
        }
        guard !rows.isEmpty else {
            Theme.empty(state.braid.status == nil ? "loading…" : "no Threads in the work area: n creates one from a dataset node", &frame, inner)
            return
        }
        // Narrow panes keep the Thread, its source and its state; the shares are in the Royalties pane.
        let columns = wide
            ? [Column("Thread", .fixed(11)), Column("source", .flex(1)), Column("state", .fixed(11)), Column("share", .fixed(shareWidth))]
            : [Column("Thread", .fixed(11)), Column("source", .flex(1)), Column("state", .fixed(11))]
        if !wide { rows = rows.map { Array($0.prefix(3)) } }
        var table = TableState(selected: state.braid.threads.isEmpty ? nil : state.braid.focus + (hasCommons ? 1 : 0))
        table.clamp(rowCount: rows.count, visible: Table.visibleRows(in: inner, showHeader: true))
        Table.styled(columns: columns, rows: rows, state: table, palette: palette, glyphs: glyphs).render(in: inner, on: &frame.canvas)
    }

    // MARK: The Royalties pane

    static func renderRoyalties(_ state: StudioState, _ frame: inout Frame, _ rect: Rect) {
        let palette = frame.palette
        let glyphs = frame.glyphs
        let shares = state.braid.royalties == .shares
        let inner = Theme.panel(shares ? "Royalties · shares (R: credit)" : "Royalties · credit (R: shares)", &frame, rect)
        guard !inner.isEmpty else { return }
        guard let view = state.braid.current, let royalties = view.royalties, royalties.generated > 0 else {
            Theme.empty("⏎ asks the braid; royalties are derived from the log as the tokens arrive", &frame, inner)
            return
        }
        func name(_ thread: String) -> Text {
            // A Thread detached since keeps its line, muted.
            guard let t = view.currentIndex(of: thread) else { return Text(thread, style: palette.muted) }
            let strand = view.strands[t]
            return Text(strand.commons ? "commons" : strand.name, style: Style(foreground: colour(t, view: view, state: state, palette: palette), background: palette.base.background))
        }
        func tint(_ thread: String) -> Color { view.currentIndex(of: thread).map { colour($0, view: view, state: state, palette: palette) } ?? palette.muted.foreground }
        var rows: [[Text]] = []
        let columns: [Column]
        if shares {
            columns = [Column("strand", .fixed(11)), Column("led", .fixed(6), align: .trailing), Column("Σ share", .fixed(8), align: .trailing), Column("", .flex(1))]
            for line in royalties.strands {
                let mean = line.share / Double(royalties.generated)
                rows.append([name(line.name), Text("\(line.led)/\(royalties.generated)", style: palette.text), Text(Theme.f(line.share), style: palette.text),
                             ShareBar(segments: [(mean, tint(line.name))], track: palette.muted, glyphs: glyphs).text(width: max(4, inner.width - 31))])
            }
        } else {
            columns = [Column("strand · document", .flex(1)), Column("tokens", .fixed(6), align: .trailing), Column("Σ share", .fixed(8), align: .trailing), Column("credit·bits", .fixed(11), align: .trailing)]
            for line in royalties.strands {
                rows.append([name(line.name), Text("", style: palette.dim), Text(Theme.f(line.share), style: palette.dim), Text(Theme.f(line.credit, 1), style: palette.text)])
            }
            for document in royalties.documents.prefix(max(0, inner.height - 2 - rows.count)) {
                rows.append([name(document.name) + Text("/…" + document.documentID.suffix(12), style: palette.dim), Text("\(document.tokens)", style: palette.text),
                             Text(Theme.f(document.share), style: palette.text), Text("", style: palette.dim)])
            }
        }
        Table.styled(columns: columns, rows: rows, state: nil, palette: palette, glyphs: glyphs).render(in: inner, on: &frame.canvas)
    }

    // MARK: The prompt and the events

    static func renderBottom(_ state: StudioState, _ frame: inout Frame, _ rect: Rect) {
        let palette = frame.palette
        let glyphs = frame.glyphs
        let columns = rect.splitHorizontally([.flex(3), .flex(2)])
        let examples = state.braid.examples
        let footer = Text(state.braid.example == nil ? "typed" : "example \(state.braid.exampleIndex + 1)/\(examples.count)", style: palette.dim)
        let prompt = Theme.panel("Prompt", focused: state.braid.editingPrompt, footer: footer, &frame, columns[0])
        if !prompt.isEmpty {
            frame.canvas.put("prompt \(glyphs.prompt)", x: prompt.minX, y: prompt.minY, style: palette.dim, clip: prompt)
            let field = Rect(x: prompt.minX + 9, y: prompt.minY, width: max(0, prompt.width - 9), height: 1)
            if state.braid.editingPrompt {
                if let cursor = TextField(state: state.braid.prompt, placeholder: "type the prompt · ⏎ asks · esc leaves", focused: true,
                                          style: palette.title, placeholderStyle: palette.muted, cursorStyle: palette.cursor).render(in: field, on: &frame.canvas) {
                    frame.cursor = cursor
                }
            } else if state.braid.prompt.text.isEmpty {
                frame.canvas.put(Text("/ types a prompt · x takes a fact prompt · ⏎ asks", style: palette.muted).truncated(to: field.width), x: field.minX, y: field.minY, clip: field)
            } else {
                // Unfocused, the prompt reads from its start.
                frame.canvas.put(Text(state.braid.prompt.text, style: palette.title).truncated(to: field.width), x: field.minX, y: field.minY, clip: field)
            }
            var lines: [Text] = []
            if let example = state.braid.example {
                var line = Text("\(example.thread) · \(example.label)", style: palette.muted)
                line.append("  expects", palette.muted)
                line.append(example.expected, palette.gold)
                if let view = state.braid.current, view.isComplete, view.gen.prompt.text == example.prompt {
                    let right = view.text.hasPrefix(example.expected)
                    line.append(right ? "  \(glyphs.check) the answer matches" : "  \(glyphs.cross) the answer differs", right ? palette.green : palette.red)
                }
                lines.append(line)
            }
            lines.append(Text(String(format: "λ %.2f · %@ · Q/A %@ · 24 tokens", state.braid.lambda, state.braid.temperature > 0 ? "sampled (t)" : "likeliest (t)",
                                     state.braid.questions ? "on (r)" : "off (r)"), style: palette.dim))
            if let report = state.braid.verify {
                let ok = report.status == .ok
                lines.append(Text("\(ok ? glyphs.verified : glyphs.cross) \(report.spansVerified)/\(report.spans.count) spans verified"
                                  + (report.issues.isEmpty ? "" : " · \(report.issues.count) replay issue\(report.issues.count == 1 ? "" : "s")"), style: ok ? palette.gold : palette.red))
            } else if let view = state.braid.current, let end = view.end {
                lines.append(Text("\(end.generated) tokens · stopped on \(end.stoppedOn?.rawValue ?? "?") · \(view.spans.count) span\(view.spans.count == 1 ? "" : "s") · v verifies", style: palette.dim))
            }
            Theme.rows(lines, &frame, prompt.inset(top: 1, left: 0, bottom: 1, right: 0))
            if prompt.height >= 3 {
                var legend = Text("colour ", style: palette.muted)
                for (index, thread) in state.braid.threads.enumerated() {
                    legend.append(thread.label + " ", Style(foreground: BraidArt.strandColor(index, palette), background: palette.base.background))
                }
                legend.append("commons ", palette.gold)
                legend.append("shared ", Style(foreground: palette.line, background: palette.base.background))
                legend.append("· dim = uncited · underline = verified span", palette.muted)
                frame.canvas.put(legend.truncated(to: prompt.width), x: prompt.minX, y: prompt.maxY - 1, clip: prompt)
            }
        }
        let events = Theme.panel("Events", &frame, columns[1])
        LogPane(state: state.braid.events, style: palette.dim).render(in: events, on: &frame.canvas)
    }
}
