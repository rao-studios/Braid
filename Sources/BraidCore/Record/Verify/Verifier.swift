//
//  Verifier.swift
//  BraidCore
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: What a session log proves: its structure and body hashes, the share arithmetic, the gate's
//        memory recursion (the clamp held), the shadow gate, the trace replayed from the hits over
//        each strand's index layout, and every verbatim span re-read from the source — the live lane
//        or the snapshot. The key replay (recomputing cited keys from state checkpoints) is the
//        model-side check BraidKit adds on top. A log imported from RaoLM takes the checks that
//        do not depend on Braid's live gate (the report's `skipped` names the rest); where such a
//        record lacks a strand's hits, the chains that would have started there cannot be replayed,
//        so a mismatch after that point is counted unreplayable instead of failed.
//

import Foundation

public enum VerifyStatus: String, Codable, Sendable { case ok, failed }

public struct SpanCheck: Codable, Sendable, Equatable {
    public var generationID: String
    public var span: Int
    public var text: String
    public var documentID: String
    public var partitionIndex: Int
    public var tokenOffset: Int
    public var status: VerificationStatus
    public var detail: String?
}

public struct TraceCheck: Codable, Sendable, Equatable {
    public var generationID: String
    public var strand: Int
    public var positions: Int
    public var mismatches: Int
    /// An imported RaoLM log's mismatches after a position whose hits the record lacks (not failures:
    /// the seeds there are not in the log).
    public var unreplayable: Int = 0
}

public struct VerifyReport: Codable, Sendable {
    public var session: String
    public var createdAt: Date
    public var generations: Int
    public var issues: [ReplayIssue]
    public var traces: [TraceCheck]
    public var spans: [SpanCheck]
    public var spansVerified: Int
    public var spansFailed: Int
    public var status: VerifyStatus
    public var notes: [String]
    /// The checks this log did not take: an imported RaoLM log's memory recursion and shadow β4, and
    /// the spans when no source was given to re-read them from.
    public var skipped: [String] = []
}

/// Reads partition texts for the span check: a snapshot, or a live lane.
public protocol PartitionReading {
    func partitionText(documentID: String, partitionIndex: Int) throws -> String?
}

public struct SnapshotPartitionReader: PartitionReading {
    let texts: [String: [Int: String]]
    public init(snapshots: [CorpusSnapshot]) {
        var texts: [String: [Int: String]] = [:]
        for snapshot in snapshots {
            for document in snapshot.documents { texts[document.id] = Dictionary(uniqueKeysWithValues: document.partitions.map { ($0.index, $0.text) }) }
        }
        self.texts = texts
    }
    public func partitionText(documentID: String, partitionIndex: Int) throws -> String? { texts[documentID]?[partitionIndex] }
}

public enum Verifier {
    /// Per strand name, the index layout to replay traces over (nil for strands without an index).
    public typealias Layouts = (String) -> IndexLayout?

    public static func verify(session: LoggedSession, name: String, layouts: Layouts, reader: PartitionReading?, tokenizer: (any Tokenizing)?,
                              spanSettings: Spans.Settings = Spans.Settings()) -> VerifyReport {
        var issues: [ReplayIssue] = []
        var traces: [TraceCheck] = []
        var spans: [SpanCheck] = []
        var notes: [String] = []
        // Spans are checked token for token against the session's own tokenizer, or not at all.
        let tokenizerRefused = tokenizer.map { $0.sha256 != session.header.pack.tokenizerSHA256 } ?? false
        if let tokenizer, tokenizerRefused {
            issues.append(ReplayIssue(generationID: "-", step: nil, strand: nil, check: "tokenizer",
                                      detail: "the tokenizer \(tokenizer.sha256.prefix(12)) is not the session's \(session.header.pack.tokenizerSHA256.prefix(12)); spans are not checked against it"))
        }
        let imported = session.header.source == RaoLMImport.source
        var skipped = SessionReplay.skipped(for: session.header)
        if imported {
            notes.append("source raolm: a RaoLM generation imported as a session. RaoLM's gate (its memory lifted by agreement, and in the trajectory arms times exp(β·(trace − mean))) is not Braid's live gate, so the memory recursion and the shadow β4 are not checked; w′ is checked from the logged gate, p and the shares from w′ and each strand's p_lm and p_knn, H_knn from the hits, and the trace is replayed over RaoLM's index layout")
        }
        if reader == nil { skipped.append("spans") }
        for generation in session.generations {
            issues += SessionReplay.check(generation, session: session)
            let strands = SessionReplay.strands(for: generation, session: session)
            let shared = generation.steps.filter { $0.source != .ctx }
            // Trace replay per strand: the tracker over the logged hits reproduces every logged chain.
            // Membership changes inside the generation move strands' indices; a strand attached
            // mid-generation seeds its chains from the catch-up hits the attach line carries.
            var current = strands
            var trackers: [String: TraceTracker] = [:]
            var tokensSoFar: [Int32] = []
            var positions: [String: Int] = [:]
            var mismatches: [String: Int] = [:]
            var unreplayable: [String: Int] = [:]
            // An imported record lacks a Thread strand's hits where RaoLM gave its retrieval no weight.
            var lacking: Set<String> = []
            for strand in strands where !strand.commons {
                if let layout = layouts(strand.name) { trackers[strand.name] = TraceTracker(corpus: layout.corpus, rule: session.header.trace) }
            }
            var membershipIndex = 0
            var previousToken: Int32? = nil
            for (k, step) in generation.steps.enumerated() {
                while membershipIndex < generation.membership.count, generation.membership[membershipIndex].before == k {
                    let line = generation.membership[membershipIndex].line
                    if line.kind == "attach" {
                        current.append(line.thread)
                        if !line.thread.commons, let layout = layouts(line.thread.name) {
                            if let hits = line.catchUpHits {
                                // The catch-up: the same feeds the live tracker got, (token j, hits j) over the prefix but its last position.
                                var tracker = TraceTracker(corpus: layout.corpus, rule: session.header.trace)
                                for (j, h) in hits.enumerated() where j + 1 < tokensSoFar.count { _ = tracker.step(token: tokensSoFar[j], hits: h) }
                                trackers[line.thread.name] = tracker
                            } else {
                                // A log written before attach lines carried the catch-up hits: the chains the
                                // newcomer started with are not in the log, so its trace cannot be replayed.
                                trackers[line.thread.name] = nil
                                notes.append("\(line.thread.name) attached at \(line.position) without catch-up hits in the log; its trace is not replayed")
                            }
                        }
                    } else if current.indices.contains(line.strand) {
                        current.remove(at: line.strand)
                    }
                    membershipIndex += 1
                }
                defer {
                    previousToken = step.token
                    if step.source != .ctx { tokensSoFar.append(step.token) }
                }
                guard step.source != .ctx, let records = step.threads, records.count == current.count, let token = previousToken else { continue }
                for (t, strand) in current.enumerated() where !strand.commons {
                    guard var tracker = trackers[strand.name] else { continue }
                    // Step j logs the hits that predicted token j and the chain state after feeding (token j−1, those hits).
                    let state = tracker.step(token: token, hits: records[t].hits)
                    trackers[strand.name] = tracker
                    positions[strand.name, default: 0] += 1
                    if let logged = records[t].trace, logged.length != state.length || logged.next != state.next {
                        if lacking.contains(strand.name) { unreplayable[strand.name, default: 0] += 1 } else { mismatches[strand.name, default: 0] += 1 }
                    }
                    // Hits seed chains for the tokens after this one, so a lack here leaves later states unknown.
                    if imported, records[t].hits.isEmpty { lacking.insert(strand.name) }
                }
            }
            for (name, count) in positions.sorted(by: { $0.key < $1.key }) {
                let misses = mismatches[name] ?? 0
                let index = (session.header.threads + session.membership.filter { $0.kind == "attach" }.map(\.thread)).firstIndex { $0.name == name } ?? 0
                let unknown = unreplayable[name] ?? 0
                traces.append(TraceCheck(generationID: generation.gen.generationID, strand: index, positions: count, mismatches: misses, unreplayable: unknown))
                if misses > 0 {
                    issues.append(ReplayIssue(generationID: generation.gen.generationID, step: nil, strand: index, check: "trace", detail: "\(name): \(misses) of \(count) chain states differ on replay"))
                }
                if unknown > 0 {
                    notes.append("\(name): \(unknown) of \(count) chain states differ after a position whose hits the RaoLM record lacks (RaoLM pooled none of them there); not replayable")
                }
            }
            // Spans from the log, re-read from the source.
            guard let reader, let end = generation.end, !tokenizerRefused else { continue }
            let partitions = Dictionary(uniqueKeysWithValues: end.partitions.map { ($0.row, $0) })
            // Each step read through the strands it was recorded with (attach and detach move indices).
            let allSlots = SessionReplay.slots(for: generation, session: session)
            let sharedSlots = generation.steps.indices.filter { generation.steps[$0].source != .ctx }.map { allSlots[$0] }
            let (_, found) = Spans.annotate(steps: shared, slots: sharedSlots, partitions: partitions, settings: spanSettings)
            for (i, span) in found.enumerated() where span.kind == .verbatim {
                var check = SpanCheck(generationID: generation.gen.generationID, span: i, text: span.text, documentID: span.source.documentID, partitionIndex: span.source.partitionIndex,
                                      tokenOffset: span.source.tokenOffset, status: .unverified, detail: nil)
                do {
                    guard let live = try reader.partitionText(documentID: span.source.documentID, partitionIndex: span.source.partitionIndex) else {
                        check.status = .missing
                        spans.append(check)
                        continue
                    }
                    if ContentHash.sha256Hex(live) != span.textSHA256 {
                        check.status = .stale
                        check.detail = "live text \(ContentHash.sha256Hex(live).prefix(12)) ≠ indexed \(span.textSHA256.prefix(12))"
                    } else if let tokenizer, tokenizer.sha256 == session.header.pack.tokenizerSHA256 {
                        let tokens = tokenizer.encode(live)
                        let range = span.source.tokenOffset ..< span.source.tokenOffset + span.tokens.count
                        if range.upperBound <= tokens.count, Array(tokens[range]) == span.tokens {
                            check.status = .verified
                        } else if range.upperBound <= tokens.count, tokenizer.decode(Array(tokens[range])) == span.text {
                            check.status = .tokenizerDrift
                        } else {
                            check.status = .mismatch
                            check.detail = "tokens at offset \(span.source.tokenOffset) differ"
                        }
                    } else {
                        check.status = .verified
                        check.detail = "text hash only (no tokenizer)"
                    }
                } catch {
                    check.status = .missing
                    check.detail = "\(error)"
                }
                spans.append(check)
            }
        }
        let verified = spans.filter { $0.status == .verified }.count
        let failed = spans.count - verified
        return VerifyReport(session: name, createdAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)), generations: session.generations.count,
                            issues: issues, traces: traces, spans: spans, spansVerified: verified, spansFailed: failed,
                            status: issues.isEmpty && failed == 0 ? .ok : .failed, notes: notes, skipped: skipped)
    }
}
