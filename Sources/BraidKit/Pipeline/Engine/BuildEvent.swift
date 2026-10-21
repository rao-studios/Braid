//
//  BuildEvent.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The stages a Thread is built through, in order, and what the engine reports while it
//        builds: a stage beginning, and the progress lines `braid thread` prints (the studio shows
//        the same lines in its Events pane).
//

import Foundation

public enum StageName: String, Sendable, CaseIterable {
    /// Read the source (or the live snapshot) and, for a new Thread, write its record.
    case snapshot
    /// Train the Thread's own blocks, 0..<cut.
    case train
    /// Key every position and write the version's index and checkpoints.
    case index
    /// Write the version's record and make it live.
    case promote
    /// Add the Thread to `[cluster] attach` in braid.toml.
    case attach
}

public enum BuildEvent: Sendable, Equatable {
    case stage(thread: String, StageName)
    case note(String)

    /// The text a terminal prints for the event; nil for a stage boundary.
    public var line: String? {
        if case .note(let text) = self { return text }
        return nil
    }
}
