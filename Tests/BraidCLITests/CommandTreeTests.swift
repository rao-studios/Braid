//
//  CommandTreeTests.swift
//  BraidCLITests
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The command tree parses: every command path answers --help, and a representative full
//        invocation of each command parses to that command with its flags.
//

import ArgumentParser
import BraidKit
import Testing
@testable import BraidCLI

@Suite("Command tree")
struct CommandTreeTests {
    @Test func rootParses() throws {
        let root = try BraidCommand.parseAsRoot([])
        #expect(root is BraidCommand)
        #expect(BraidCommand.configuration.commandName == "braid")
    }

    @Test func versionIsTheKit() {
        #expect(BraidCommand.configuration.version == BraidVersion.string)
    }

    /// Every command below the root, with its path of names.
    static func commands(_ command: ParsableCommand.Type, prefix: [String] = []) -> [(path: [String], type: ParsableCommand.Type)] {
        command.configuration.subcommands.flatMap { sub -> [(path: [String], type: ParsableCommand.Type)] in
            let name = sub.configuration.commandName ?? String(describing: sub).lowercased()
            return [(prefix + [name], sub)] + commands(sub, prefix: prefix + [name])
        }
    }

    @Test("every command renders its help, naming its own path")
    func everyCommandHasHelp() throws {
        let all = Self.commands(BraidCommand.self)
        #expect(all.count >= 30, "\(all.count) commands")
        for (path, type) in all {
            let help = BraidCommand.helpMessage(for: type)
            #expect(help.contains("USAGE: braid \(path.joined(separator: " "))"), "\(path.joined(separator: " ")): \(help.prefix(120))")
            #expect(type.configuration.abstract.count > 10, "\(path.joined(separator: " ")) has no abstract")
        }
    }

    @Test("a full invocation of each command parses", arguments: [
        ["doctor"], ["init", "--base", "mamba2-130m-hf", "--measure"], ["init", "--measure"], ["import", "AntonV/mamba2-130m-hf", "--check"],
        ["pack", "show", "d3e4"], ["thread", "create", "a", "--corpus", "dataset:braid-n3#ambient", "--limit", "40", "--no-train"],
        ["thread", "sync", "a", "--no-train"], ["thread", "index", "a", "--scheme", "residual:8", "--checkpoint-every-partition"],
        ["chat", "When was Tillyburn founded?", "--threads", "a,b", "--json"],
        ["cluster", "spawn", "--prompt", "x", "--attach", "a@2", "--detach", "b@5"],
        ["verify", "s.jsonl", "--live", "--keys", "--all-hits", "--no-write"], ["credit", "s.jsonl", "--json"],
        ["bench", "trace", "--per-node", "4"], ["bench", "sweep-key", "--thread", "a", "--arms", "residual:12,pooled-state:12"],
        ["aii", "ingest", "demo-a/ambient", "--from", "dataset:braid-n3#ambient", "--limit", "5"], ["aii", "wipe", "demo-a/ambient", "--yes"],
    ])
    func invocationParses(arguments: [String]) throws {
        _ = try BraidCommand.parseAsRoot(arguments)
    }

    @Test func importRaoLMParses() throws {
        let command = try BraidCommand.parseAsRoot(["import-raolm", "/dump", "--arm", "no agreement", "--out", "/tmp/out", "--check"])
        let parsed = try #require(command as? ImportRaoLMCommand)
        #expect(parsed.dump == "/dump" && parsed.arm == "no agreement" && parsed.out == "/tmp/out" && parsed.check)
        let plain = try #require(try BraidCommand.parseAsRoot(["import-raolm", "/dump"]) as? ImportRaoLMCommand)
        #expect(plain.arm == nil && plain.out == nil && !plain.check)
        #expect(ImportRaoLMCommand.defaultOut.path == "/Volumes/T9/rao/projects/braid/raolm-import")
    }
}
