//
//  DoctorScreen.swift
//  BraidStudio
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: 3 Doctor: the checks `braid doctor` runs (BraidKit's DoctorChecks), with their verdicts
//        and details; r runs them again.
//

import BraidKit
import BraidTerminal
import Foundation

enum DoctorScreen: StudioScreen {
    static func render(_ state: StudioState, _ frame: inout Frame, _ rect: Rect) {
        let palette = frame.palette
        let glyphs = frame.glyphs
        let checks = state.doctor.checks
        let ok = checks.filter(\.ok).count
        let footer = checks.isEmpty ? nil : Text("\(ok)/\(checks.count) ok", style: ok == checks.count ? palette.green : palette.orange)
        let inner = Theme.panel("Doctor · the checks braid doctor runs", focused: true, footer: footer, &frame, rect)
        guard !inner.isEmpty else { return }
        if checks.isEmpty {
            Theme.empty(state.status.jobs[.doctor] != nil ? "\(StudioApp.spinner(state, glyphs)) running the checks…" : "r runs the checks", &frame, inner)
            return
        }
        var rows: [Text] = []
        for check in checks {
            var line = Text(check.ok ? glyphs.check : glyphs.cross, style: check.ok ? palette.green : palette.red)
            line.append(" " + check.name.padding(toLength: 15, withPad: " ", startingAt: 0), palette.text)
            line.append(check.detail.replacingOccurrences(of: "\n", with: " "), check.ok ? palette.dim : palette.orange)
            rows.append(line)
        }
        rows.append(Text(""))
        rows.append(Text(ok == checks.count ? "all checks passed" : "\(checks.count - ok) check\(checks.count - ok == 1 ? "" : "s") failed · braid doctor exits 1", style: ok == checks.count ? palette.green : palette.orange))
        Theme.rows(rows, &frame, inner)
    }

    static func handle(_ key: KeyEvent, _ state: inout StudioState) -> [StudioJob]? {
        switch key.key {
        case .char("r"):
            guard state.status.jobs[.doctor] == nil else { return [] }
            return [.doctor]
        default:
            return nil
        }
    }

    static func hints(_ state: StudioState) -> [KeyHint] { [KeyHint("r", "re-check")] }
}
