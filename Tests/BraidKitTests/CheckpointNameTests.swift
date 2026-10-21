//
//  CheckpointNameTests.swift
//  BraidKitTests
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The file a state checkpoint is saved as. A plain document id (every dataset, folder and
//        Braid lane id) keeps the name every existing index has; an app's record id, which holds `/`
//        and may hold `:` and capitals, becomes one safe path component that stays distinct even on
//        a case-insensitive volume.
//

import Foundation
import Testing
@testable import BraidKit

@Suite("Checkpoint file names")
struct CheckpointNameTests {
    @Test("plain ids keep the names every existing index has")
    func plain() {
        #expect(CheckpointRef.fileName(documentID: "braid-tdir-4af39a9c551639b7cb8667c6", position: 18) == "braid-tdir-4af39a9c551639b7cb8667c6-18.safetensors")
        #expect(CheckpointRef.fileName(documentID: "raolm-ambient-12", position: 1024) == "raolm-ambient-12-1024.safetensors")
        #expect(CheckpointRef.fileName(documentID: "Doc_1.v2", position: 3) == "Doc_1.v2-3.safetensors")
    }

    @Test("a record id becomes one safe path component, distinct by case and punctuation")
    func records() {
        let longest = "app" + String(repeating: "x", count: 29) + "/" + String(repeating: "k", count: 32) + "/" + String(repeating: "Z:@", count: 43)
        let ids = ["braidplayground/log/harlow-light", "notes/note/A", "notes/note/a", "notes/note/a:b", "notes/note/a@b", "notes/note/a_b", longest]
        let names = ids.map { CheckpointRef.fileName(documentID: $0, position: 1024) }
        for name in names {
            #expect(!name.contains("/") && !name.contains(":"))
            #expect(name.utf8.count <= 255 && name.hasSuffix("-1024.safetensors") && name.contains("~"))
        }
        #expect(names[0].hasPrefix("braidplayground_log_harlow-light~"))
        #expect(Set(names.map { $0.lowercased() }).count == ids.count, "distinct even on a case-insensitive volume")
    }
}
