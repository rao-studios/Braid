//
//  AIIDetect.swift
//  BraidThread
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: What Braid knows about an AII on this machine: its home, whether it is provisioned (layout
//        v1, secrets), which lanes have secrets, the Thread's ports and health (stack mode, contract,
//        embedder phase). The machine's AII is `~/.rao` (or AII_HOME); demo AIIs live under the
//        repo's aii/ folder.
//

import AII
import BraidCore
import Foundation

public struct AIIStatusReport: Sendable, Equatable {
    public var name: String
    public var home: URL
    public var provisioned: Bool
    public var layoutVersion: Int?
    public var lanes: [String]
    public var httpPort: Int
    public var grpcPort: Int
    public var health: LaneHealth?
    public var problem: String?

    public var up: Bool { health?.status == "healthy" }
}

public enum AIIDetect {
    /// The root demo AIIs live under: BRAID_DEMO_HOMES, else `<repo>/aii` found by walking up from the
    /// executable to the folder holding Package.swift, else `./aii`.
    public static func demoRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["BRAID_DEMO_HOMES"], !override.isEmpty { return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true) }
        var directory = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) {
                return directory.appendingPathComponent("aii", isDirectory: true)
            }
            directory.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true).appendingPathComponent("aii", isDirectory: true)
    }

    public static func status(aii name: String, demoRoot: URL) async -> AIIStatusReport {
        let home = LaneHomes.home(for: name, demoRoot: demoRoot)
        var report = AIIStatusReport(name: name, home: home.root, provisioned: false, layoutVersion: nil, lanes: [], httpPort: AIIPortPlan.thread.http, grpcPort: AIIPortPlan.thread.grpc, health: nil, problem: nil)
        guard FileManager.default.fileExists(atPath: home.layoutFile.path) else {
            report.problem = "not provisioned (no layout.json)"
            return report
        }
        report.provisioned = true
        if let data = FileManager.default.contents(atPath: home.layoutFile.path), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            report.layoutVersion = object["version"] as? Int
        }
        report.lanes = AIIApp.allCases.map(\.rawValue).filter { FileManager.default.fileExists(atPath: home.secretFile(for: .app(AIIApp(rawValue: $0)!)).path) }
        let ports = AIIConfig.load(home: home).threadPorts
        report.httpPort = ports.http
        report.grpcPort = ports.grpc
        let endpoint = LaneEndpoint(address: LaneAddress(aii: name, lane: .ambient), home: home.root, httpPort: ports.http, grpcPort: ports.grpc)
        do {
            report.health = try await LaneClient(endpoint: endpoint, secret: "").health()
        } catch let error as URLError where error.code == .cannotConnectToHost || error.code == .cannotFindHost {
            report.problem = "stopped (nothing answers on \(ports.http))"
        } catch let error as URLError {
            report.problem = "Thread not answering on \(ports.http): \(error.localizedDescription)"
        } catch {
            report.problem = "Thread not answering on \(ports.http): \(error)"
        }
        return report
    }

    /// The AII contract as this build links it, as install.json records it, and as the Thread serves it.
    public static func contract(home: AIIHome = AIIHome.resolved(), serving: Int?) throws -> String {
        guard let record = AIIInstallRecord.load(home: home) else { throw BraidFailure.missing("no install.json under \(home.root.path)/aii") }
        let linked = AIIContract.version
        guard record.contract == linked else {
            throw BraidFailure.configuration("the installed AIIServer speaks contract \(record.contract); this build links \(linked)", hint: "update the AII package or reinstall the app")
        }
        if let serving, serving != linked { throw BraidFailure.configuration("the Thread serves contract \(serving); this build links \(linked)") }
        return "linked \(linked) · installed \(record.contract) (\(record.appVersion), by \(record.installedBy.rawValue)) · serving \(serving.map(String.init) ?? "?")"
    }

    /// The installed AIIServer is the binary install.json names, by SHA-256.
    public static func server(home: AIIHome = AIIHome.resolved()) throws -> String {
        guard let record = AIIInstallRecord.load(home: home) else { throw BraidFailure.missing("no install.json under \(home.root.path)/aii") }
        let binary = home.serverBinary
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw BraidFailure.missing("no AIIServer at \(binary.path)") }
        let found = try ContentHash.sha256Hex(fileAt: binary)
        guard found == record.sha256 else { throw BraidFailure.data("AIIServer \(found.prefix(12)) is not the one install.json names (\(record.sha256.prefix(12)))") }
        return "\(binary.path) is install.json's (\(found.prefix(12)))"
    }

    /// One phrase per demo AII: its ports and whether its Thread answers. A stopped demo is not a fault.
    public static func demoSummary(demoRoot: URL) async -> String {
        let names = demos(demoRoot: demoRoot)
        guard !names.isEmpty else { return "none under \(demoRoot.path) (braid aii create demo-a)" }
        var parts: [String] = []
        for name in names {
            let report = await status(aii: name, demoRoot: demoRoot)
            parts.append("\(name) \(report.httpPort)/\(report.grpcPort) \(report.up ? "up" : "stopped")")
        }
        return parts.joined(separator: " · ")
    }

    /// The demo AIIs under the root (folders holding braid-demo.json).
    public static func demos(demoRoot: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(at: demoRoot, includingPropertiesForKeys: nil)) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent(DemoAII.recordFile).path) }
            .map(\.lastPathComponent).sorted()
    }
}
