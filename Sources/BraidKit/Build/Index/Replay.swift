//
//  Replay.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: KV-free replay: any key of an index recomputed from the nearest state checkpoint at or
//        before its position (or from a zero state), after both of the checkpoint's hashes are
//        checked. `braid verify --keys` reads keys back through it.
//

import BraidCore
import Foundation
import MLX

public enum Replay {
    /// The key at a corpus position, recomputed from the nearest checkpoint at or before it (or
    /// from a zero state), scanning forward. Both the checkpoint's hashes are verified first.
    public static func key(at target: TokenPosition, index: ProvenanceIndex, corpus: TokenizedCorpus, trunk: Trunk, pack: Pack) throws -> (key: MLXArray, checkpointDistance: Int) {
        guard let document = corpus.document(ofRow: target.row), let position = document.addresses.firstIndex(of: target) else {
            throw BraidFailure.data("position \(target) is not in the corpus")
        }
        let candidates = index.checkpoints.checkpoints.filter { $0.documentID == document.documentID && $0.position <= position }
        var state: StateStack? = nil
        var start = 0
        if let nearest = candidates.max(by: { $0.position < $1.position }) {
            let url = index.directory.appendingPathComponent(IndexFiles.checkpointDirectory).appendingPathComponent(nearest.file)
            guard try ContentHash.sha256Hex(fileAt: url) == nearest.sha256 else { throw BraidFailure.data("checkpoint \(nearest.file) does not hash to its record") }
            guard NodeCheckpoint.prefixHash(Array(document.tokens[0...nearest.position])) == nearest.prefixSHA256 else { throw BraidFailure.data("checkpoint \(nearest.file) is bound to another prefix") }
            state = try StateStack.load(from: url, expecting: trunk.config)
            start = nearest.position + 1
        }
        guard position >= start else { throw BraidFailure.data("checkpoint past the target") }
        let segment = Array(document.tokens[start...position])
        let key = SegmentKeys.lastKey(trunk: trunk, segment: segment, state: state, scheme: index.info.keyScheme, alpha: index.info.alpha)
        return (key, position - start + 1)
    }
}
