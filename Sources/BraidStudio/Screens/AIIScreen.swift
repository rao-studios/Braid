//
//  AIIScreen.swift
//  BraidStudio
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: 2 AII, read-only: the machine's Ambient Intelligence Index home (~/.rao, or AII_HOME) —
//        layout.json, the lanes with a secret, the Thread's health on its HTTP port — and the demo
//        AII homes under <repo>/aii, each the same way.
//

import BraidKit
import BraidTerminal
import Foundation

enum AIIScreen: StudioScreen {
    static func render(_ state: StudioState, _ frame: inout Frame, _ rect: Rect) {
        let palette = frame.palette
        let glyphs = frame.glyphs
        guard let status = state.aii.status else {
            let inner = Theme.panel("Machine AII", &frame, rect)
            Theme.empty(state.status.jobs[.aii] != nil ? "\(StudioApp.spinner(state, glyphs)) detecting the AII…" : "r detects the machine's AII", &frame, inner)
            return
        }
        let machineHeight = min(rect.height, 9)
        let (machineRect, demosRect) = rect.top(machineHeight)
        let inner = Theme.panel("Machine AII · \(Theme.abbreviate(status.machine.path))", focused: true, &frame, machineRect)
        Theme.rows(lines(for: status.machine, palette: palette, glyphs: glyphs), &frame, inner)
        guard demosRect.height >= 3 else { return }
        let demos = Theme.panel("Demo AIIs · \(Theme.abbreviate(status.demoRoot))", &frame, demosRect)
        if status.demos.isEmpty {
            Theme.empty("none · braid aii create <name> provisions one under \(Theme.abbreviate(status.demoRoot)) (two demos ⇒ two Threads to attach and detach)", &frame, demos)
            return
        }
        var rows: [Text] = []
        for demo in status.demos {
            rows.append(Text(demo.name, style: palette.title) + Text("  " + Theme.abbreviate(demo.path), style: palette.dim))
            rows += lines(for: demo, palette: palette, glyphs: glyphs).map { Text("  ") + $0 }
            rows.append(Text(""))
        }
        Theme.rows(rows, &frame, demos)
    }

    static func lines(for home: AIIHomeStatus, palette: Palette, glyphs: Glyphs) -> [Text] {
        func mark(_ ok: Bool) -> Text { Text(ok ? glyphs.check : glyphs.cross, style: ok ? palette.green : palette.red) }
        var lines: [Text] = []
        lines.append(mark(home.layout) + Text(" layout.json ", style: palette.text) + Text(home.layout ? "present" : "missing", style: palette.dim))
        var lanes = mark(!home.lanes.isEmpty) + Text(" lanes       ", style: palette.text)
        for lane in ["ambient", "craft", "veil"] {
            let has = home.lanes.contains(lane)
            lanes.append(lane + " ", has ? palette.text : palette.muted)
            lanes.append((has ? glyphs.live : glyphs.idle) + "  ", has ? palette.green : palette.muted)
        }
        lanes.append("stack secret " + (home.stackSecret ? glyphs.live : glyphs.idle), palette.dim)
        lines.append(lanes)
        var thread = Text("", style: palette.text)
        if let health = home.health {
            thread = mark(true) + Text(" Thread      ", style: palette.text) + Text(health, style: palette.green)
        } else {
            thread = mark(false) + Text(" Thread      ", style: palette.text) + Text(home.healthProblem ?? "unreachable", style: palette.orange)
        }
        if let http = home.httpPort, let grpc = home.grpcPort { thread.append("  · http \(http) · grpc \(grpc)", palette.dim) }
        lines.append(thread)
        return lines
    }

    static func handle(_ key: KeyEvent, _ state: inout StudioState) -> [StudioJob]? {
        switch key.key {
        case .char("r"):
            guard state.status.jobs[.aii] == nil else { return [] }
            return [.aii]
        default:
            return nil
        }
    }

    static func hints(_ state: StudioState) -> [KeyHint] { [KeyHint("r", "refresh")] }
}
