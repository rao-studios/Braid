//
//  DoctorChecks.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The checks `braid doctor` runs and the studio's Doctor screen shows, from one place: the
//        Metal library beside the binary, the work area and its free space, braid.toml, the pack
//        and its tokenizer round trip, the trunk (the commons' seam, which every Thread's live
//        version must name), the machine's AII (home, lanes, Thread health). Each check is a name,
//        a verdict and a detail, so the CLI prints the list and the studio draws it.
//  PIN:  A failed check says what is missing and how to fix it; nothing here writes anything.
//

import BraidCore
import BraidThread
import Foundation

public struct DoctorCheck: Sendable, Equatable {
    public var name: String
    public var ok: Bool
    public var detail: String

    public init(name: String, ok: Bool, detail: String) {
        self.name = name
        self.ok = ok
        self.detail = detail
    }

    /// `  ✓ name: detail`, as `braid doctor` prints it.
    public var line: String { "  \(ok ? "✓" : "✗") \(name): \(detail)" }
}

public enum DoctorChecks {
    /// The pack `braid.toml` names (by sha256, a prefix of it, or its name) among `packs/*/pack.json`; nil when none matches.
    public static func findPack(_ reference: String, in area: WorkArea) throws -> Pack? {
        guard FileManager.default.fileExists(atPath: area.packs.path) else { return nil }
        let directories = try FileManager.default.contentsOfDirectory(at: area.packs, includingPropertiesForKeys: nil)
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent(Pack.infoFile).path) }
        let packs = try directories.map { ($0, try JSONCoding.read(PackInfo.self, from: $0.appendingPathComponent(Pack.infoFile))) }
            .sorted { $0.1.createdAt < $1.1.createdAt }
        for (directory, info) in packs where info.sha256.hasPrefix(reference.lowercased()) || info.name == reference {
            return try Pack.load(from: directory)
        }
        return nil
    }

    /// The commons' trunk from the pack's record alone, no weights loaded: its seam, its size, and whether every
    /// Thread's live version names that seam and cut, which `ThreadStore.load` will insist on.
    public static func trunk(pack: Pack, in area: WorkArea) throws -> String {
        let config = pack.config
        var named = 0
        var wrong: [String] = []
        for info in try ThreadStore.list(in: area) {
            guard let live = try ThreadStore.live(area.thread(info.name)) else { continue }
            if live.seamSHA256 != pack.info.seamSHA256 {
                wrong.append("\(info.name) v\(live.version) names seam \(live.seamSHA256.prefix(12))")
            } else if live.cut != config.cut {
                wrong.append("\(info.name) v\(live.version) is cut at \(live.cut)")
            } else {
                named += 1
            }
        }
        let trunk = "seam \(pack.info.seamSHA256.prefix(12)): the commons' blocks \(config.cut)–\(config.numHiddenLayers - 1), the embedding and norm_f, "
            + String(format: "%.0f MB", Double(StorageMath(config: config).trunkBytes) / 1_000_000)
        guard wrong.isEmpty else { throw BraidFailure.data("\(trunk); not every Thread runs it: \(wrong.joined(separator: "; "))") }
        return trunk + (named == 0 ? "; no Thread yet" : "; \(named) Thread version\(named == 1 ? " names" : "s name") it")
    }

    /// The Metal library beside the running binary (build-metallib.sh puts it there).
    public static func metallib(besideExecutable executable: URL = URL(fileURLWithPath: CommandLine.arguments[0])) throws -> String {
        let binary = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        for name in ["mlx.metallib", "default.metallib"] where FileManager.default.fileExists(atPath: binary.appendingPathComponent(name).path) {
            return binary.appendingPathComponent(name).path
        }
        throw BraidFailure.configuration("no mlx.metallib beside \(binary.path)", hint: "run ./build-metallib.sh (Scripts/cli.sh does it)")
    }

    public static func freeGB(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        let bytes = values?.volumeAvailableCapacityForImportantUsage.flatMap { $0 > 0 ? $0 : nil } ?? values?.volumeAvailableCapacity.map(Int64.init)
        return bytes.map { String(format: "%.0f", Double($0) / 1_073_741_824) } ?? "?"
    }

    /// The machine's AII home: AII_HOME, else ~/.rao.
    public static func aiiHome(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        ((environment["AII_HOME"] ?? "~/.rao") as NSString).expandingTildeInPath
    }

    /// The machine's AII: its home, the lanes with a secret, and the Thread's health on its HTTP port.
    public static func aii(environment: [String: String] = ProcessInfo.processInfo.environment, httpPort: Int = 47081) async throws -> String {
        let home = aiiHome(environment: environment)
        guard FileManager.default.fileExists(atPath: home + "/layout.json") else { throw BraidFailure.unavailable("no AII home at \(home)") }
        let lanes = ["ambient", "craft", "veil"].filter { FileManager.default.fileExists(atPath: home + "/secrets/\($0)") }
        let request = URLRequest(url: URL(string: "http://127.0.0.1:\(httpPort)/health")!, timeoutInterval: 3)
        let (data, _) = try await URLSession.shared.data(for: request)
        let health = String(decoding: data, as: UTF8.self)
        guard health.contains("\"healthy\"") else { throw BraidFailure.unavailable("Thread on \(httpPort) is not healthy: \(health.prefix(80))") }
        let stack = health.contains("\"stack\":\"proof\"") ? "proof" : (health.contains("\"stack\":\"open\"") ? "open" : "?")
        return "home \(home), lanes \(lanes.joined(separator: "/")), Thread healthy on \(httpPort) (stack \(stack))"
    }

    /// `aii()` for synchronous callers (the CLI).
    public static func aiiBlocking(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
        try Blocking.run { try await aii(environment: environment) }
    }

    /// Every check, in the order `braid doctor` prints them. `area` is how the work area resolved
    /// (or why it did not); `config` loads braid.toml from it.
    public static func run(area: Result<WorkArea, Error>, config: (WorkArea) throws -> BraidConfig,
                           environment: [String: String] = ProcessInfo.processInfo.environment) async -> [DoctorCheck] {
        var checks: [DoctorCheck] = []
        func report(_ name: String, _ outcome: Result<String, Error>) {
            switch outcome {
            case .success(let detail): checks.append(DoctorCheck(name: name, ok: true, detail: detail))
            case .failure(let error): checks.append(DoctorCheck(name: name, ok: false, detail: "\(error)"))
            }
        }
        report("metal library", Result { try metallib() })
        report("work area", area.map { "\($0.root.path) (\(freeGB($0.root)) GB free)" })
        if case .success(let area) = area {
            let loaded = Result { try config(area) }
            report("braid.toml", loaded.map { "pack \($0.pack?.name ?? "none") \($0.pack?.sha256.prefix(12) ?? "")" + ($0.attach.isEmpty ? " · no Thread attached" : " · attach \($0.attach.joined(separator: ", "))") })
            if case .success(let config) = loaded, let packRecord = config.pack {
                switch Result(catching: { try findPack(packRecord.sha256, in: area) }) {
                case .success(let pack?):
                    report("pack", .success("\(pack.info.name) loads; hashes re-derived"))
                    report("tokenizer", Result {
                        let tokenizer = try BraidTokenizer(folder: pack.tokenizerFolder)
                        guard tokenizer.eos == 0 else { throw BraidFailure.data("eos is \(tokenizer.eos)") }
                        guard tokenizer.decode(tokenizer.encode("Hello, braid.")) == "Hello, braid." else { throw BraidFailure.data("does not round-trip") }
                        return "\(tokenizer.vocabSize) tokens in \(pack.config.vocabSize) rows, eos 0, break \(tokenizer.paragraphBreak)"
                    })
                    report("trunk", Result { try trunk(pack: pack, in: area) })
                case .success(nil): report("pack", .failure(BraidFailure.missing("not in \(area.packs.path)")))
                case .failure(let error): report("pack", .failure(error))
                }
            }
        }
        do {
            report("AII", .success(try await aii(environment: environment)))
        } catch {
            report("AII", .failure(error))
        }
        let demoRoot = AIIDetect.demoRoot(environment: environment)
        let machine = await AIIDetect.status(aii: LaneAddress.machine, demoRoot: demoRoot)
        report("AII contract", Result { try AIIDetect.contract(serving: machine.health?.contract) })
        report("AIIServer", Result { try AIIDetect.server() })
        report("demo AIIs", .success(await AIIDetect.demoSummary(demoRoot: demoRoot)))
        return checks
    }
}
