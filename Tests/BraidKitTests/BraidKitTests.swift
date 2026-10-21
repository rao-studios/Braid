//
//  BraidKitTests.swift
//  BraidKitTests
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//

import Testing
@testable import BraidKit

@Suite("BraidKit")
struct BraidKitSmokeTests {
    @Test func version() { #expect(BraidVersion.string == "0.1.0") }
}
