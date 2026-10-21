//
//  AII.swift
//  BraidCLI
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: `braid aii status|create|start|stop|ingest|wipe`: the machine's AII and the demo AIIs Braid
//        creates under the repo's aii/ folder, and the Braid corpus in a lane (deposit a dataset
//        node, remove it).
//

import ArgumentParser
import BraidKit
import Foundation

struct AIICommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "aii", abstract: "The machine's AII, demo AIIs, and Braid's corpus in a lane.",
                                                    subcommands: [Status.self, Create.self, Start.self, Stop.self, Ingest.self, Wipe.self], defaultSubcommand: Status.self)

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "status", abstract: "The machine's AII and every demo AII: home, lanes, Thread health.")
        func run() throws {
            guarded {
                let root = AIIDetect.demoRoot()
                for name in [LaneAddress.machine] + AIIDetect.demos(demoRoot: root) {
                    let report = try Blocking.run { await AIIDetect.status(aii: name, demoRoot: root) }
                    let health = report.health.map { "Thread \($0.status) on \(report.httpPort)/\(report.grpcPort) (stack \($0.stack ?? "?"), contract \($0.contract ?? 0), embedder \($0.embedderPhase ?? "?"))" } ?? (report.problem ?? "?")
                    print("\(name.padding(toLength: 10, withPad: " ", startingAt: 0)) \(report.home.path)  lanes \(report.lanes.joined(separator: "/"))  \(health)")
                }
            }
        }
    }

    struct Create: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "create", abstract: "Provision a demo AII home (APFS) and start its Thread on free ports.")
        @Argument var name: String
        @Option(help: "The home's path (default: <repo>/aii/<name>).") var at: String?
        @Option(help: "http,grpc ports (default: the first free pair of the plan 47181/47190, 47281/47290, …).") var ports: String?
        @Option(help: "The AIIServer binary (default: BRAID_AII_SERVER or ~/.rao/aii/bin/AIIServer).") var server: String?
        func run() throws {
            guarded {
                var pair: (http: Int, grpc: Int)? = nil
                if let ports {
                    let parts = ports.split(separator: ",").compactMap { Int($0) }
                    guard parts.count == 2 else { throw BraidFailure.usage("--ports takes http,grpc") }
                    pair = (parts[0], parts[1])
                }
                let serverURL = (server ?? ProcessInfo.processInfo.environment["BRAID_AII_SERVER"]).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                let record = try DemoAII.create(name: name, demoRoot: AIIDetect.demoRoot(), at: at.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) },
                                                ports: pair, server: serverURL) { note("aii create: \($0)") }
                print("\(record.name)  \(record.root)  http \(record.httpPort)  grpc \(record.grpcPort)")
                print("lanes: ambient, craft, veil — address a Thread as \(record.name)/<lane>")
            }
        }
    }

    struct Start: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "start", abstract: "Start (or adopt) a demo AII's Thread.")
        @Argument var name: String
        func run() throws {
            guarded {
                let record = try DemoAII.record(name: name, demoRoot: AIIDetect.demoRoot())
                try DemoAII.start(record: record) { note("aii start: \($0)") }
                print("\(name) up on \(record.httpPort)/\(record.grpcPort)")
            }
        }
    }

    struct Stop: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "stop", abstract: "Stop a demo AII's Thread.")
        @Argument var name: String
        func run() throws {
            guarded {
                let record = try DemoAII.record(name: name, demoRoot: AIIDetect.demoRoot())
                try DemoAII.stop(record: record)
                print("\(name) stopped")
            }
        }
    }

    struct Ingest: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "ingest", abstract: "Deposit a dataset node (or a folder) into a lane as Braid's corpus there.")
        @OptionGroup var workArea: WorkAreaOptions
        @Argument(help: "<aii>/<lane>, e.g. home/ambient or demo-a/craft") var lane: String
        @Option(help: "dataset:<name or path>#<node> or dir:<path>") var from: String
        @Option var limit: Int?
        @Option var batch: Int = 16
        func run() throws {
            guarded {
                guard let address = LaneAddress(parsing: lane) else { throw BraidFailure.usage("lane addresses are <aii>/<lane>: home or a demo AII, and a lane registered on it") }
                let spec = try CorpusSourceSpec(parsing: from)
                let area = try workArea.resolve()
                if case .lane = spec { throw BraidFailure.usage("ingest takes a dataset or a folder, not a lane") }
                if case .app = spec { throw BraidFailure.usage("ingest takes a dataset or a folder, not an app's records") }
                let snapshot = try CorpusSources.read(spec, slug: address.lane.rawValue, limit: limit, datasetsRoot: DatasetsRoot.resolve(workArea: area.root),
                                                      demoRoot: AIIDetect.demoRoot()).snapshot
                note("ingest: \(snapshot.documentCount) documents, \(snapshot.partitionCount) partitions → \(address)")
                try LaneSource.ingest(snapshot, into: address, demoRoot: AIIDetect.demoRoot(), batchSize: batch) { done, total in if done % 16 == 0 || done == total { note("ingest: \(done)/\(total)") } }
                let stats = try LaneSource.stats(address: address, demoRoot: AIIDetect.demoRoot())
                print("\(address): \(snapshot.documentCount) documents deposited; the lane now holds \(stats.documents) documents in \(stats.groups) groups")
            }
        }
    }

    struct Wipe: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "wipe", abstract: "Remove Braid's corpus from a lane (by exported ids; never an empty list).")
        @Argument var lane: String
        @Flag var yes = false
        func run() throws {
            guarded {
                guard let address = LaneAddress(parsing: lane) else { throw BraidFailure.usage("lane addresses are <aii>/<lane>") }
                guard yes else { throw BraidFailure.usage("pass --yes to remove Braid's documents from \(address)") }
                let removed = try LaneSource.wipe(address: address, demoRoot: AIIDetect.demoRoot())
                print("\(address): removed \(removed) documents")
            }
        }
    }
}
