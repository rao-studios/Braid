//
//  UI.swift
//  BraidCLI
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: `braid ui [--fixtures <dir>]`: the studio — the braid on one full-screen terminal screen,
//        the Threads braid.toml attaches attached and the commons present, every token split by the
//        strand that supplied it; 2 AII and 3 Doctor beside it. Bare `braid` in a terminal opens it
//        too (BRAID_NO_UI=1 prints help instead). --fixtures (or BRAID_UI_FIXTURES) replays a
//        recorded session with no MLX and no work area.
//

import ArgumentParser
import BraidKit
import BraidStudio
import Foundation

struct UICommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ui",
        abstract: "Open the studio: the braid on one full-screen screen, its Threads attached, every token split by the strand that supplied it.",
        discussion: """
            Keys: ⏎ asks, / types a prompt, tab focuses a Thread and space attaches or detaches it, n makes a new Thread, R shows royalties or shares, ←→ walk the tokens, v verifies the spans, o replays a saved session, x takes a fact prompt, ? lists every key, q quits. 1–3 switch screens (Braid, AII, Doctor).
            --fixtures (or BRAID_UI_FIXTURES) replays a recorded session with no MLX and no work area: Tests/BraidStudioTests/Fixtures/demo.
            BRAID_COLOR=truecolor|256|16|none forces the colour depth; BRAID_ASCII=1 draws ASCII glyphs; BRAID_UI_THEME=terminal keeps the terminal's own background. What libraries print goes to <work area>/logs/studio.log.
            """)

    @OptionGroup var workArea: WorkAreaOptions

    @Option(help: "Replay a recorded session instead of using MLX (default: $BRAID_UI_FIXTURES).")
    var fixtures: String?

    func run() async throws {
        guard Studio.isInteractive else {
            FileHandle.standardError.write(Data("braid: braid ui needs an interactive terminal\n  run it directly, not through a pipe; BRAID_NO_UI=1 makes bare braid print help\n".utf8))
            throw ArgumentParser.ExitCode(ExitCode.usage.rawValue)
        }
        var options = StudioOptions()
        let fixturePath = fixtures ?? ProcessInfo.processInfo.environment["BRAID_UI_FIXTURES"]
        if let fixturePath, !fixturePath.isEmpty {
            options.fixtures = URL(fileURLWithPath: (fixturePath as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            do {
                options.workArea = try workArea.resolve()
            } catch {
                options.workAreaProblem = "\(error)"
            }
        }
        do {
            let code = try await Studio.launch(options)
            if code != 0 { throw ArgumentParser.ExitCode(code) }
        } catch let failure as BraidFailure {
            FileHandle.standardError.write(Data("braid: \(failure.description)\n".utf8))
            throw ArgumentParser.ExitCode(failure.code.rawValue)
        }
    }
}
