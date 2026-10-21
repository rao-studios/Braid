//
//  Studio.swift
//  BraidStudio
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Opens the studio: the terminal, the app loop over BraidTerminal, the live or fixture
//        backend, and the job the first screen needs (the braid).
//  PIN:  The UI draws on a duplicate of the terminal's descriptor while standard output and error
//        go to <work area>/logs/studio.log, so a library that prints (a tokenizer warning, MLX,
//        Metal) can never scribble over the screen. Both come back before the function returns,
//        and the terminal is restored on every path out of `App.run`.
//

import BraidKit
import BraidTerminal
import Darwin
import Foundation

@MainActor
final class BackendBox {
    var backend: StudioBackend?
}

/// Points standard output and error at a file until `restore()`.
final class StreamRedirect {
    private var saved: [(Int32, Int32)] = []

    init(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { throw BraidFailure("cannot open \(url.path) for the studio log", code: .exists) }
        fflush(stdout)
        fflush(stderr)
        for target in [STDOUT_FILENO, STDERR_FILENO] {
            saved.append((target, dup(target)))
            dup2(fd, target)
        }
        close(fd)
    }

    func restore() {
        fflush(stdout)
        fflush(stderr)
        for (target, copy) in saved {
            dup2(copy, target)
            close(copy)
        }
        saved.removeAll()
    }
}

public enum Studio {
    public static let name = "Braid studio"

    /// Standard input and output are a terminal (and not a dumb one).
    public static var isInteractive: Bool { Terminal.isInteractive }

    @MainActor
    public static func launch(_ options: StudioOptions) async throws -> Int32 {
        let tty = dup(STDOUT_FILENO)
        guard tty >= 0 else { throw BraidFailure("cannot open the terminal", code: .internalError) }
        defer { close(tty) }
        let terminal = Terminal(input: STDIN_FILENO, output: tty)
        let logs = options.workArea?.logs ?? FileManager.default.temporaryDirectory.appendingPathComponent("braid", isDirectory: true)
        let redirect = try StreamRedirect(to: logs.appendingPathComponent("studio.log"))
        defer { redirect.restore() }

        var state = StudioState(fixtures: options.fixtures != nil)
        state.size = terminal.size
        let box = BackendBox()
        let app = App<StudioState, StudioEvent>(
            display: terminal, initial: state,
            update: { state, event in
                let jobs = StudioApp.handle(event, state: &state)
                for job in jobs { box.backend?.submit(job) }
                if let code = state.quitCode { return .quit(code: code) }
                if state.redraw {
                    state.redraw = false
                    return .redraw
                }
                return .none
            },
            render: { state, frame in StudioApp.render(state, &frame) })
        let backend: StudioBackend
        if let fixtures = options.fixtures {
            backend = try FixtureBackend(directory: fixtures, mailbox: app.mailbox)
        } else {
            backend = LiveBackend(options: options, mailbox: app.mailbox)
        }
        box.backend = backend
        for job in StudioApp.initialJobs(state) { backend.submit(job) }
        let code = try await app.run()
        await backend.shutdown()
        return code
    }
}
