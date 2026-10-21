//
//  Withholding.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The documents a Thread trains on but leaves out of its index (the stitched bench's P):
//        a fraction of them, drawn by seed from the ids in sorted order, so the draw does not
//        depend on the order the source returned them in.
//

import BraidCore
import Foundation

public enum Withholding {
    /// `fraction` of the documents (rounded, at least one, never all), drawn by `seed` from the ids in sorted order.
    public static func draw(_ ids: [String], fraction: Double, seed: UInt64) -> Set<String> {
        let sorted = Array(Set(ids)).sorted()
        guard sorted.count >= 2 else { return [] }
        let count = min(max(1, Int((fraction * Double(sorted.count)).rounded())), sorted.count - 1)
        var rng = SplitMix64(seed: seed ^ 0x5717_C4ED_0000_0000)
        return Set(sorted.shuffled(using: &rng).prefix(count))
    }
}
