//
//  Options.swift
//  BraidCLI
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The options every command shares: the work area (BRAID_WORK_AREA, else the mounted T9,
//        else refused unless named), and the failure mapping to sysexits so scripts can branch.
//

import ArgumentParser
import BraidKit
import Foundation

struct WorkAreaOptions: ParsableArguments {
    @Option(name: .customLong("work-area"), help: "Where Braid's data lives (default: BRAID_WORK_AREA, else /Volumes/T9/rao/projects/braid when the T9 is mounted).")
    var workAreaPath: String?

    func resolve() throws -> WorkArea {
        if let workAreaPath { return WorkArea(root: URL(fileURLWithPath: (workAreaPath as NSString).expandingTildeInPath, isDirectory: true)) }
        guard let area = WorkArea.resolve() else {
            throw BraidFailure.configuration("no work area: the T9 is not mounted", hint: "set BRAID_WORK_AREA or pass --work-area; Braid does not write to the internal disk unasked")
        }
        return area
    }

    func config(in area: WorkArea) throws -> BraidConfig {
        guard FileManager.default.fileExists(atPath: area.configFile.path) else {
            throw BraidFailure.missing("no braid.toml in \(area.root.path)", hint: "run braid init --base <pack or hf-id> first")
        }
        return try BraidConfig.load(from: area.configFile)
    }
}

/// Runs a command body, printing a BraidFailure and exiting with its code; other errors are internal.
func guarded(_ body: () throws -> Void) {
    do {
        try body()
    } catch let failure as BraidFailure {
        FileHandle.standardError.write(Data("braid: \(failure.description)\n".utf8))
        exit(failure.code.rawValue)
    } catch let failure as ConformanceFailureBox {
        FileHandle.standardError.write(Data("braid: \(failure.description)\n".utf8))
        exit(ExitCode.data.rawValue)
    } catch {
        FileHandle.standardError.write(Data("braid: \(error)\n".utf8))
        exit(ExitCode.internalError.rawValue)
    }
}

struct ConformanceFailureBox: Error, CustomStringConvertible { var description: String }

func note(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }
