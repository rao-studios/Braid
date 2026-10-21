//
//  Version.swift
//  BraidCore
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The package's version string and the session-log schema version, in one place.
//

import Foundation

public enum BraidVersion {
    /// The CLI's `--version`.
    public static let string = "0.1.0"
    /// The session log's schema (see Record/Session/SessionLog.swift). Bumped when a line's shape changes.
    public static let sessionSchema = 1
}
