//
//  BraidCommand.swift
//  BraidCLI
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The `braid` root command. Bare `braid` in a terminal opens the studio on the Braid
//        screen (BRAID_NO_UI=1 prints help instead); everywhere else it prints help. Subcommands
//        are the training and testing tools.
//

import ArgumentParser
import BraidKit
import BraidStudio
import Foundation

@main
struct BraidCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "braid",
        abstract: "The Braid Transformer: a braid of per-Thread Mamba2 strands under one reed, every token split exactly by the Thread that supplied it.",
        discussion: "Bare `braid` in a terminal opens the studio (braid ui); BRAID_NO_UI=1 prints this help instead.",
        version: BraidVersion.string,
        subcommands: [UICommand.self, DoctorCommand.self, InitCommand.self, ImportCommand.self, PackCommand.self, ThreadCommand.self, ClusterCommand.self, ChatCommand.self, VerifyCommand.self, CreditCommand.self, BenchCommand.self, ImportRaoLMCommand.self, AIICommand.self]
    )

    func run() async throws {
        if Studio.isInteractive, ProcessInfo.processInfo.environment["BRAID_NO_UI"] == nil {
            let ui = try UICommand.parse([])
            try await ui.run()
            return
        }
        print(BraidCommand.helpMessage())
    }
}
