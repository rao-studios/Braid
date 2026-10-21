//
//  WorkArea.swift
//  BraidCore
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Where Braid's data lives: `BRAID_WORK_AREA`, else the T9 work area
//        `/Volumes/T9/rao/projects/braid` when the drive is mounted, else nowhere — Braid refuses
//        to write to the internal disk unless told where (the braid runs that filled it are why).
//        Demo AII homes are the exception: they need hard links, which the exFAT T9 has not, so
//        they live under the repo (`DemoHomes`).
//  OUT:  The layout under the work area: braid.toml, packs/<sha12>/, models/huggingface/,
//        threads/<name>/, sessions/, bench/, datasets/, logs/.
//

import Foundation

public struct WorkArea: Sendable, Equatable {
    public static let environmentKey = "BRAID_WORK_AREA"
    public static let t9Projects = URL(fileURLWithPath: "/Volumes/T9/rao/projects", isDirectory: true)
    public static let t9 = t9Projects.appendingPathComponent("braid", isDirectory: true)

    public var root: URL

    public init(root: URL) { self.root = root }

    /// The work area named by the environment or the mounted T9; nil when neither is there.
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment,
                               exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> WorkArea? {
        if let override = environment[environmentKey], !override.isEmpty {
            return WorkArea(root: URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true))
        }
        return exists(t9Projects) ? WorkArea(root: t9) : nil
    }

    public var configFile: URL { root.appendingPathComponent("braid.toml") }
    public var packs: URL { root.appendingPathComponent("packs", isDirectory: true) }
    public var modelsHome: URL { root.appendingPathComponent("models", isDirectory: true).appendingPathComponent("huggingface", isDirectory: true) }
    public var threads: URL { root.appendingPathComponent("threads", isDirectory: true) }
    public var sessions: URL { root.appendingPathComponent("sessions", isDirectory: true) }
    public var bench: URL { root.appendingPathComponent("bench", isDirectory: true) }
    public var datasets: URL { root.appendingPathComponent("datasets", isDirectory: true) }
    public var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }

    public func pack(sha256: String) -> URL { packs.appendingPathComponent(String(sha256.prefix(12)), isDirectory: true) }
    public func thread(_ name: String) -> ThreadLayout { ThreadLayout(root: threads.appendingPathComponent(name, isDirectory: true), name: name) }

    /// Creates the directories a fresh work area needs (idempotent).
    public func prepare() throws {
        for directory in [packs, modelsHome, threads, sessions, bench, logs] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}

/// `threads/<name>/`: the record, the snapshots by hash, the versions, the pointer to the live one.
public struct ThreadLayout: Sendable, Equatable {
    public var root: URL
    public var name: String

    public var record: URL { root.appendingPathComponent("thread.json") }
    public var live: URL { root.appendingPathComponent("live.json") }
    public var snapshots: URL { root.appendingPathComponent("snapshots", isDirectory: true) }
    public var versions: URL { root.appendingPathComponent("versions", isDirectory: true) }
    public var checkpoints: URL { root.appendingPathComponent("checkpoints", isDirectory: true) }

    public func snapshot(hash: String) -> URL { snapshots.appendingPathComponent(String(hash.prefix(12)), isDirectory: true) }
    public func version(_ number: Int) -> URL { versions.appendingPathComponent(String(format: "v%04d", number), isDirectory: true) }
}

/// Where `braid aii create` puts demo AII homes: `<repo or cwd>/aii/<name>` on APFS.
public enum DemoHomes {
    public static func root(repository: URL) -> URL { repository.appendingPathComponent("aii", isDirectory: true) }
}
