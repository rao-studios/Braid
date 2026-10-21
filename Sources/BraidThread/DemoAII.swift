//
//  DemoAII.swift
//  BraidThread
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: A second (or third) AII on one machine, for testing Threads that attach and detach: a home
//        provisioned the way AII provisions one (layout.json, the four secrets), the embedder's
//        snapshot shared with the machine's models folder by symlink so nothing re-downloads, free
//        ports chosen from a plan, and `AIIServer thread` launched through AII's own LaunchSpecs and
//        ManagedServer (no Developer-ID check: the installed binary is a dev build).
//  PIN:  AII provisioning publishes secrets with link(), which exFAT cannot do, so a demo home must
//        sit on APFS — the repo's aii/ folder by default; a target that cannot hard-link is refused.
//

import AII
import BraidCore
import Foundation

public struct DemoRecord: Codable, Sendable, Equatable {
    public var name: String
    public var root: String
    public var httpPort: Int
    public var grpcPort: Int
    public var server: String
    public var createdAt: Date
}

public enum DemoAII {
    public static let recordFile = "braid-demo.json"
    /// Port pairs tried in order, skipping any in use.
    public static let portPlan: [(http: Int, grpc: Int)] = [(47181, 47190), (47281, 47290), (47381, 47390), (47481, 47490), (47581, 47590)]

    public static func defaultServer() -> URL { AIIHome.resolved().serverBinary }

    /// Whether `directory` (which must exist) supports hard links.
    public static func supportsHardLinks(_ directory: URL) -> Bool {
        let a = directory.appendingPathComponent(".braid-link-\(UUID().uuidString)")
        let b = directory.appendingPathComponent(".braid-link-\(UUID().uuidString)")
        defer { unlink(a.path); unlink(b.path) }
        guard FileManager.default.createFile(atPath: a.path, contents: Data()) else { return false }
        return link(a.path, b.path) == 0
    }

    public static func isListening(port: Int) -> Bool {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return false }
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return result == 0
    }

    public static func freePorts() throws -> (http: Int, grpc: Int) {
        for pair in portPlan where !isListening(port: pair.http) && !isListening(port: pair.grpc) { return pair }
        throw BraidFailure.unavailable("every port pair in the demo plan is in use")
    }

    public static func record(name: String, demoRoot: URL) throws -> DemoRecord {
        let url = demoRoot.appendingPathComponent(name, isDirectory: true).appendingPathComponent(recordFile)
        guard FileManager.default.fileExists(atPath: url.path) else { throw BraidFailure.missing("no demo AII named \(name) under \(demoRoot.path)", hint: "braid aii create \(name)") }
        return try JSONCoding.read(DemoRecord.self, from: url)
    }

    /// Provisions the home, shares the models folder, writes the ports, and starts the Thread.
    public static func create(name: String, demoRoot: URL, at target: URL? = nil, ports: (http: Int, grpc: Int)? = nil, server: URL? = nil,
                              progress: (String) -> Void = { _ in }) throws -> DemoRecord {
        guard DocumentID.isValidHandle(name) else { throw BraidFailure.usage("demo names are lowercase handles: \(name)") }
        let root = target ?? demoRoot.appendingPathComponent(name, isDirectory: true)
        if FileManager.default.fileExists(atPath: root.appendingPathComponent(recordFile).path) { throw BraidFailure.exists("demo AII \(name) exists at \(root.path)") }
        let parent = root.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        guard supportsHardLinks(parent) else {
            throw BraidFailure.configuration("\(parent.path) cannot hard-link; AII homes need APFS", hint: "the T9 is exFAT — leave demo homes under the repo's aii/ folder")
        }
        let serverURL = server ?? defaultServer()
        guard FileManager.default.isExecutableFile(atPath: serverURL.path) else {
            throw BraidFailure.missing("no AIIServer at \(serverURL.path)", hint: "install an AII app, or pass --server / BRAID_AII_SERVER")
        }
        progress("provisioning \(root.path)")
        let home = AIIHome(root: root)
        _ = try home.provision(by: .ambient)
        // The embedder's snapshot: the machine's models folder, shared.
        let machineModels = AIIHome.resolved().root.appendingPathComponent("models", isDirectory: true).appendingPathComponent("huggingface", isDirectory: true)
        let models = root.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        let link = models.appendingPathComponent("huggingface")
        if FileManager.default.fileExists(atPath: machineModels.path), !FileManager.default.fileExists(atPath: link.path) {
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: machineModels)
            progress("sharing the embedder snapshots from \(machineModels.path)")
        }
        let chosen = try ports ?? freePorts()
        var config = AIIConfig()
        config.thread = AIIConfig.Server(httpPort: chosen.http, grpcPort: chosen.grpc, dataDir: nil, graphBackend: "keyword")
        try config.write(home: home)
        let record = DemoRecord(name: name, root: root.path, httpPort: chosen.http, grpcPort: chosen.grpc, server: serverURL.path,
                                createdAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)))
        try JSONCoding.write(record, to: root.appendingPathComponent(recordFile))
        progress("starting AIIServer thread on \(chosen.http)/\(chosen.grpc)")
        try start(record: record, progress: progress)
        return record
    }

    static func spec(for record: DemoRecord) -> LaunchSpec {
        let home = AIIHome(root: URL(fileURLWithPath: record.root, isDirectory: true))
        let options = ThreadLaunchOptions(useMLX: true, graphBackend: "keyword", mlxModel: AIIModels.embedding.id, ports: AIIPorts(http: record.httpPort, grpc: record.grpcPort),
                                          mothership: false, extraArguments: ["--no-graph-extraction"])
        return LaunchSpecs.thread(home: home, executable: URL(fileURLWithPath: record.server), options: options, challengeApp: .ambient, inherited: ProcessInfo.processInfo.environment)
    }

    /// Starts (or adopts) the demo's Thread and waits for its embedder.
    public static func start(record: DemoRecord, timeout: TimeInterval = 180, progress: (String) -> Void = { _ in }) throws {
        let home = AIIHome(root: URL(fileURLWithPath: record.root, isDirectory: true))
        guard let secret = try home.readSecret(for: .ambient) else { throw BraidFailure.data("the demo home has no ambient secret") }
        let spec = spec(for: record)
        let handle = try Blocking.run {
            let server = ManagedServer(spec: spec, secret: secret, launcherApp: .ambient, policy: nil)
            return try await server.ensureRunning(timeout: 120)
        }
        progress("Thread pid \(handle.pid) \(handle.adopted ? "adopted" : "started"), contract \(handle.contract)")
        let endpoint = LaneEndpoint(address: LaneAddress(aii: record.name, lane: .ambient), home: home.root, httpPort: record.httpPort, grpcPort: record.grpcPort)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let health = try? Blocking.run({ try await LaneClient(endpoint: endpoint, secret: "").health() }), health.embedderPhase == "ready" || health.embedderPhase == nil {
                progress("embedder \(health.embedderPhase ?? "?")")
                return
            }
            Thread.sleep(forTimeInterval: 2)
        }
        progress("embedder still loading after \(Int(timeout)) s; Index calls will wait")
    }

    public static func stop(record: DemoRecord) throws {
        let home = AIIHome(root: URL(fileURLWithPath: record.root, isDirectory: true))
        guard let secret = try home.readSecret(for: .ambient) else { throw BraidFailure.data("the demo home has no ambient secret") }
        let spec = spec(for: record)
        try Blocking.run {
            let server = ManagedServer(spec: spec, secret: secret, launcherApp: .ambient, policy: nil)
            _ = try? await server.ensureRunning(timeout: 5)
            await server.stop()
        }
    }
}

/// Runs an async operation to completion from synchronous code.
enum Blocking {
    static func run<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task.detached {
            do { box.result = .success(try await body()) } catch { box.result = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try box.result!.get()
    }

    final class ResultBox<T>: @unchecked Sendable { var result: Result<T, Error>? }
}
