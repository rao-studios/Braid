//
//  ReadmeAssetsExport.swift
//  BraidStudioTests
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Exports the studio's frames for the README's images (BRAID_README_ASSETS=<dir> only): the
//        README fixtures' four sessions replayed through the studio exactly as `braid ui --fixtures`
//        shows them, one HTML frame per generated token, and a still of the Braid screen with the
//        spans verified and the cursor on a cited token. Docs/README_Assets/src/build.py turns them into
//        the GIF, the screenshot and the legend. No MLX, no work area.
//

import BraidKit
import BraidTerminal
import Foundation
import Testing
@testable import BraidStudio

private let exportDirectory = ProcessInfo.processInfo.environment["BRAID_README_ASSETS"]

@Suite("README assets", .enabled(if: exportDirectory != nil), .serialized)
struct ReadmeAssetsExport {
    static let size = Size(width: 120, height: 34)

    static var repo: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

    static var fixtures: URL {
        if let override = ProcessInfo.processInfo.environment["BRAID_README_FIXTURES"] { return URL(fileURLWithPath: override, isDirectory: true) }
        return repo.appendingPathComponent("Docs/README_Assets/src/fixtures", isDirectory: true)
    }

    /// One frame for the GIF: its HTML file and how long it shows.
    struct FrameRecord: Codable {
        var file: String
        var milliseconds: Int
    }

    @Test("the frames and the still")
    func export() async throws {
        let out = URL(fileURLWithPath: try #require(exportDirectory), isDirectory: true)
        let frames = out.appendingPathComponent("frames", isDirectory: true)
        try? FileManager.default.removeItem(at: frames)
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        let collector = Collector()
        let backend = try FixtureBackend(directory: Self.fixtures, post: { collector.post($0) })
        backend.replayDelay = .zero
        var state = StudioState(fixtures: true)
        state.size = Self.size
        let palette = Palette(for: Capabilities(isTTY: true, colorDepth: .trueColor), environment: [:])

        func render() -> Canvas {
            var frame = Frame(canvas: Canvas(size: Self.size), palette: palette, glyphs: .unicode)
            StudioApp.render(state, &frame)
            return frame.canvas
        }
        func perform(_ job: StudioJob) async throws {
            try await backend.perform(job)
            for event in collector.drain() {
                for followUp in StudioApp.reduce(event, state: &state) {
                    try? await backend.perform(followUp)
                    for later in collector.drain() { _ = StudioApp.reduce(later, state: &state) }
                }
            }
        }
        var records: [FrameRecord] = []
        func write(_ canvas: Canvas, milliseconds: Int) throws {
            let name = String(format: "%04d.html", records.count + 1)
            try CanvasHTML.page(canvas, palette: palette).write(to: frames.appendingPathComponent(name), atomically: true, encoding: .utf8)
            records.append(FrameRecord(file: "frames/" + name, milliseconds: milliseconds))
        }

        try await perform(.start)
        try await perform(.examples)
        // Each session, oldest first: the prompt, then one frame per generated token, then a hold.
        let sessions = try backend.sessionURLs().sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(sessions.count == 4)
        /// The prompt a session asked, from its gen line.
        func prompt(of url: URL) throws -> String { try SessionReader.read(url).generations.first?.gen.prompt.text ?? "" }
        for url in sessions {
            state.braid.prompt.set(try prompt(of: url))
            try await backend.perform(.openSession(url))
            var shownPrompt = false
            for event in collector.drain() {
                _ = StudioApp.reduce(event, state: &state)
                guard case .session(let line) = event else { continue }
                switch line {
                case .step(let step) where step.source == .gen:
                    if !shownPrompt { shownPrompt = true }
                    try write(render(), milliseconds: 110)
                case .step(let step) where step.source == .prompt && !shownPrompt && step.index == 1:
                    shownPrompt = true
                    try write(render(), milliseconds: 650)
                case .end:
                    try write(render(), milliseconds: 1900)
                default:
                    break
                }
            }
        }
        try JSONEncoder().encode(records).write(to: out.appendingPathComponent("frames.json"))

        // The still: the Craft answer, its spans verified, the cursor on a cited token.
        let craft = try #require(sessions.first { (try? prompt(of: $0))?.contains("Joltvault") == true })
        state.braid.prompt.set(try prompt(of: craft))
        try await perform(.openSession(craft))
        try await perform(.verify(craft))
        // The cursor on the answer's first token ("410" of 41027), which a verified span covers.
        state.braid.cursor = state.braid.current?.firstGenerated ?? 0
        let still = render()
        try CanvasHTML.page(still, palette: palette).write(to: out.appendingPathComponent("braid-screen.html"), atomically: true, encoding: .utf8)
        try still.lines.joined(separator: "\n").write(to: out.appendingPathComponent("braid-screen.txt"), atomically: true, encoding: .utf8)
        print("README ASSETS: \(records.count) frames, still at \(Self.size.width)×\(Self.size.height) → \(out.path)")
    }
}

/// A canvas as HTML: one row per line, runs of one style as spans, colours as the palette resolves them.
enum CanvasHTML {
    static func hex(_ color: Color, fallback: (UInt8, UInt8, UInt8)) -> String {
        let (r, g, b) = color.rgbComponents.map { ($0.r, $0.g, $0.b) } ?? fallback
        return String(format: "#%02x%02x%02x", r, g, b)
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    static func css(_ style: Style, foreground: (UInt8, UInt8, UInt8), background: (UInt8, UInt8, UInt8)) -> String {
        var fg = hex(style.foreground, fallback: foreground)
        var bg = hex(style.background, fallback: background)
        if style.attributes.contains(.reverse) { swap(&fg, &bg) }
        var parts = ["color:\(fg)", "background:\(bg)"]
        if style.attributes.contains(.bold) { parts.append("font-weight:700") }
        if style.attributes.contains(.italic) { parts.append("font-style:italic") }
        if style.attributes.contains(.underline) { parts.append("text-decoration:underline;text-underline-offset:3px") }
        if style.attributes.contains(.dim) { parts.append("opacity:0.62") }
        return parts.joined(separator: ";")
    }

    static func rows(_ canvas: Canvas, palette: Palette) -> [String] {
        let foreground = palette.base.foreground.rgbComponents.map { ($0.r, $0.g, $0.b) } ?? (0xE6, 0xE1, 0xD6)
        let background = palette.base.background.rgbComponents.map { ($0.r, $0.g, $0.b) } ?? (0x16, 0x16, 0x16)
        return (0 ..< canvas.size.height).map { y in
            var html = ""
            var run = ""
            var runStyle: Style? = nil
            func flush() {
                guard let style = runStyle, !run.isEmpty else { return }
                html += "<span style=\"\(css(style, foreground: foreground, background: background))\">\(escape(run))</span>"
                run = ""
            }
            for x in 0 ..< canvas.size.width {
                let cell = canvas[x, y]
                if cell.isContinuation { continue }
                if cell.style != runStyle { flush(); runStyle = cell.style }
                run.unicodeScalars.append(cell.scalar)
            }
            flush()
            return "<div class=\"row\">\(html)</div>"
        }
    }

    static func page(_ canvas: Canvas, palette: Palette) -> String {
        let background = palette.base.background.rgbComponents.map { String(format: "#%02x%02x%02x", $0.r, $0.g, $0.b) } ?? "#161616"
        return """
        <!doctype html><html><head><meta charset="utf-8"><style>
        html,body{margin:0;background:\(background)}
        .term{display:inline-block;padding:14px 16px;background:\(background);font-family:Menlo,monospace;font-size:15px;line-height:19px;letter-spacing:0}
        .row{white-space:pre;height:19px}
        </style></head><body><div class="term" id="term" data-cols="\(canvas.size.width)" data-rows="\(canvas.size.height)">
        \(rows(canvas, palette: palette).joined(separator: "\n"))
        </div></body></html>
        """
    }
}
