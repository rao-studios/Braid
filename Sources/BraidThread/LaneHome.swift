//
//  LaneHome.swift
//  BraidThread
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Which AII a lane address names and how to reach its Thread: the machine's home (`~/.rao`,
//        or AII_HOME) or a demo home Braid created under <repo>/aii/<name>; the Thread's ports from
//        the home's aii/config.json (the shared-stack plan 47081/47090 by default); the lane's
//        secret from the home's secrets/, read the way AII reads it.
//

import AII
import BraidCore
import Foundation

public struct LaneEndpoint: Sendable, Equatable {
    public var address: LaneAddress
    public var home: URL
    public var httpPort: Int
    public var grpcPort: Int
    public var host = "127.0.0.1"

    public var healthURL: URL { URL(string: "http://\(host):\(httpPort)/health")! }
    public var description: String { "\(address) @ \(home.path) grpc:\(grpcPort)" }
}

public enum LaneHomes {
    /// The home an `<aii>` name refers to: `home` is the machine's, anything else a demo under `demoRoot`.
    public static func home(for aii: String, demoRoot: URL) -> AIIHome {
        aii == LaneAddress.machine ? AIIHome.resolved() : AIIHome(root: demoRoot.appendingPathComponent(aii, isDirectory: true))
    }

    public static func endpoint(for address: LaneAddress, demoRoot: URL) throws -> LaneEndpoint {
        let home = home(for: address.aii, demoRoot: demoRoot)
        guard FileManager.default.fileExists(atPath: home.layoutFile.path) else {
            throw BraidFailure.unavailable("no AII home at \(home.root.path)", hint: address.isMachine ? "install an app that provisions ~/.rao, or set AII_HOME" : "run braid aii create \(address.aii)")
        }
        let ports = AIIConfig.load(home: home).threadPorts
        return LaneEndpoint(address: address, home: home.root, httpPort: ports.http, grpcPort: ports.grpc)
    }

    /// The lane's secret: the app's, as AII reads it (owner, mode, 64 hex).
    public static func secret(for address: LaneAddress, demoRoot: URL) throws -> String {
        let home = home(for: address.aii, demoRoot: demoRoot)
        guard let secret = try home.readSecret(for: .app(address.lane)) else {
            throw BraidFailure.unavailable("no secret for \(address.lane.rawValue) in \(home.root.path)/secrets")
        }
        return secret
    }

    /// Whom the lane's app files its records under: the owner its manifest entry names (an app that
    /// joined with `owner: .local` files under aii-local), else a new lane's default, `local-<app>`.
    /// The owner AIIInstance files under.
    public static func owner(for address: LaneAddress, demoRoot: URL) -> String {
        let home = home(for: address.aii, demoRoot: demoRoot)
        return (home.lane(address.lane)?.owner ?? AIILanes.defaultOwner(for: address.lane)).rawValue
    }
}
