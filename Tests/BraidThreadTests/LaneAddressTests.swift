//
//  LaneAddressTests.swift
//  BraidThreadTests
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//

import AII
import Testing
@testable import BraidThread

@Suite("Lane addresses")
struct LaneAddressTests {
    @Test func parsing() {
        #expect(LaneAddress(parsing: "ambient") == LaneAddress(lane: .ambient))
        #expect(LaneAddress(parsing: "demo-a/craft") == LaneAddress(aii: "demo-a", lane: .craft))
        #expect(LaneAddress(parsing: "demo-a/aii") == nil)
        #expect(LaneAddress(parsing: "/veil") == nil)
        #expect(LaneAddress(parsing: "a/b/c") == nil)
        #expect(LaneAddress(aii: "home", lane: .veil).description == "home/veil")
        #expect(LaneAddress(lane: .veil).isMachine)
    }

    @Test("any registered app names a lane; a Thread records Braid's corpus or an app's records there")
    func customLanes() {
        #expect(LaneAddress(parsing: "home/notes") == LaneAddress(aii: "home", lane: "notes"))
        #expect(LaneAddress(parsing: "home/Notes") == nil)
        #expect(LaneAddress(parsing: "home/no-tes") == nil)
        #expect(LaneAddress(parsing: "home/n") == nil)
        #expect(LaneCorpus(recorded: "home/veil") == .braid(LaneAddress(aii: "home", lane: .veil)))
        #expect(LaneCorpus(recorded: "app:home/notes") == .app(LaneAddress(aii: "home", lane: "notes")))
        for text in ["home/veil", "demo-a/craft", "app:home/notes", "app:demo-a/braidplayground"] {
            #expect(LaneCorpus(recorded: text)?.description == text)
        }
        #expect(LaneCorpus(recorded: "app:") == nil)
        #expect(LaneCorpus(recorded: "app:a/b/c") == nil)
        #expect(LaneCorpus(recorded: "app:home/aii") == nil)
    }
}
