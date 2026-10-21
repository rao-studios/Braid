//
//  Doctor.swift
//  BraidCLI
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: `braid doctor`: the checks before anything else — the Metal library, the work area and its
//        free space, braid.toml, the pack and its tokenizer, the machine's AII (home, secrets, lanes,
//        Thread health). The checks live in BraidKit (DoctorChecks), shared with the studio's Doctor
//        screen. A failed check says what is missing and the command exits 1.
//

import ArgumentParser
import BraidKit
import Foundation

struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "doctor", abstract: "Check the setup: Metal library, work area, braid.toml, pack, tokenizer, AII.")

    @OptionGroup var workArea: WorkAreaOptions

    func run() throws {
        print("braid doctor")
        let options = workArea
        let checks = try Blocking.run {
            await DoctorChecks.run(area: Result { try options.resolve() }, config: { try options.config(in: $0) })
        }
        for check in checks { print(check.line) }
        let failures = checks.filter { !$0.ok }.count
        print(failures == 0 ? "all checks passed" : "\(failures) check(s) failed")
        if failures > 0 { throw ArgumentParser.ExitCode(ExitCode.doctor.rawValue) }
    }
}
