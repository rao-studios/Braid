//
//  MLXGate.swift
//  BraidKitTests
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The MLX suites run one at a time (MLX's eval lock deadlocks concurrent gradient traces)
//        and only when asked: BRAID_MLX_TESTS=1 (or FRIGATE_MLX_TESTS=1), which Scripts/test.sh sets.
//

import Foundation
import Testing

let mlxTests: Bool = {
    let env = ProcessInfo.processInfo.environment
    return env["BRAID_MLX_TESTS"] == "1" || env["FRIGATE_MLX_TESTS"] == "1"
}()

@Suite("MLX, one suite at a time", .enabled(if: mlxTests), .serialized)
struct BraidMLXSuites {}
