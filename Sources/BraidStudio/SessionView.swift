//
//  SessionView.swift
//  BraidStudio
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: A generation as the screen holds it: the log lines that arrived (gen, tok…, end, any
//        attach/detach between them), the strands and the partition table they are read against,
//        and the views derived from them exactly as `braid verify` and `braid cluster spawn` derive
//        them — citations and verbatim spans, credit, royalties. Also the per-token detail block
//        (three lines) for the token under the cursor, as plain strings, so a test can pin them.
//  PIN:  Nothing here is stored per token beyond the log line; everything else is recomputed from
//        the lines, so a live session and a replayed one show the same numbers.
//

import BraidKit
import BraidTerminal
import Foundation

public struct GenerationView: Sendable {
    public var gen: GenerationLine
    /// The strands in effect, in record order (attach and detach lines move them).
    public var strands: [SessionThread]
    /// The braid's global partition table, by row.
    public var partitions: [Int: PartitionRef]
    public var steps: [Step] = []
    /// Per step (aligned with `steps`), the strands its records are in when it arrived.
    public var stepSlots: [[StrandSlot]] = []
    public var end: EndLine?
    /// Per shared step (the context lines excluded), the citations and the span it belongs to.
    public var annotations: [SpanAnnotation] = []
    public var spans: [CitedSpan] = []
    public var royalties: RoyaltiesView?
    /// What `v` found, by span index.
    public var verification: [Int: SpanCheck] = [:]

    public init(gen: GenerationLine, strands: [SessionThread], partitions: [PartitionRef]) {
        self.gen = gen
        self.strands = strands
        self.partitions = Dictionary(partitions.map { ($0.row, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The steps the derived views run over: prompt and generated positions, context lines excluded.
    public var shared: [Step] { steps.filter { $0.source != .ctx } }
    /// Indices into `shared` the cursor walks: every position whose strands were asked (the eos opener has none).
    public var walkable: [Int] { shared.indices.filter { shared[$0].threads != nil } }
    public var generated: [Step] { steps.filter { !$0.isPrompt } }
    public var commons: Int? { strands.firstIndex(where: \.commons) }
    public var text: String { end?.text ?? generated.map(\.text).joined() }
    public var isComplete: Bool { end != nil }

    /// The cursor position of the first generated token (the prompt's positions come first).
    public var firstGenerated: Int {
        let shared = self.shared
        return walkable.firstIndex { !shared[$0].isPrompt } ?? max(0, walkable.count - 1)
    }

    public mutating func append(_ step: Step) {
        let current = strands.map(StrandSlot.init)
        if step.source == .ctx, let owner = step.owner, current.indices.contains(owner) {
            stepSlots.append([current[owner]])
        } else {
            stepSlots.append(current)
        }
        steps.append(step)
        derive()
    }

    /// The slots of the shared steps (context lines excluded), aligned with `shared`.
    public var sharedSlots: [[StrandSlot]] {
        let current = strands.map(StrandSlot.init)
        return steps.indices.filter { steps[$0].source != .ctx }.map { $0 < stepSlots.count ? stepSlots[$0] : current }
    }

    /// The current index of a Thread by name (for its colour), if it is still attached.
    public func currentIndex(of name: String) -> Int? { strands.firstIndex { $0.name == name } }

    /// An attach or detach line inside the generation: the strand list follows it.
    public mutating func apply(_ line: MembershipLine) {
        if line.kind == "attach" {
            strands.append(line.thread)
        } else if strands.indices.contains(line.strand) {
            strands.remove(at: line.strand)
        }
    }

    /// Recomputes citations, spans, credit and royalties from the lines so far.
    public mutating func derive() {
        let shared = self.shared
        let slots = sharedSlots
        let found = Spans.annotate(steps: shared, slots: slots, partitions: partitions)
        annotations = found.annotations
        spans = found.spans
        var credits = Credit.assign(shared, slots: slots)
        _ = FollowedCredit.apply(&credits, steps: shared, slots: slots, partitions: partitions)
        royalties = Royalties.view(steps: shared, credits: credits, slots: slots, partitions: partitions)
    }

    public func annotation(shared k: Int) -> SpanAnnotation? { k < annotations.count ? annotations[k] : nil }

    public func isVerified(spanIndex: Int?) -> Bool {
        guard let spanIndex else { return false }
        return verification[spanIndex]?.status == .verified
    }

    /// The strand a global row belongs to (its index among the current strands).
    public func strand(ofRow row: Int) -> Int? {
        strands.indices.first { !strands[$0].commons && row >= strands[$0].rowOffset && row < strands[$0].rowOffset + strands[$0].rowCount }
    }

    /// The Thread a global row belongs to, by name, among every strand this generation has seen.
    public func strandName(ofRow row: Int) -> String? {
        if let t = strand(ofRow: row) { return strands[t].name }
        return stepSlots.lazy.flatMap { $0 }.first { $0.holds(row: row) }?.name
    }

    /// The record of the same Thread (by name) at the previous asked position, for the one-step deltas.
    public func previousRecord(shared k: Int, strand t: Int) -> ThreadRecord? {
        let shared = self.shared
        let slots = sharedSlots
        guard k < shared.count, k < slots.count, t < slots[k].count else { return nil }
        let name = slots[k][t].name
        var j = k - 1
        while j >= 0 {
            if let previous = shared[j].threads {
                guard j < slots.count, let i = slots[j].firstIndex(where: { $0.name == name }), previous.indices.contains(i) else { return nil }
                return previous[i]
            }
            j -= 1
        }
        return nil
    }
}

/// The styles the detail block is drawn with; `TokenDetail.plain` uses none.
public struct DetailStyles {
    public var text: Style
    public var title: Style
    public var dim: Style
    public var muted: Style
    public var gold: Style
    public var red: Style
    public var strand: (Int) -> Style

    public init(text: Style, title: Style, dim: Style, muted: Style, gold: Style, red: Style, strand: @escaping (Int) -> Style) {
        self.text = text
        self.title = title
        self.dim = dim
        self.muted = muted
        self.gold = gold
        self.red = red
        self.strand = strand
    }

    public static let plain = DetailStyles(text: .plain, title: .plain, dim: .plain, muted: .plain, gold: .plain, red: .plain, strand: { _ in .plain })
}

/// The per-token detail block, mapped one-to-one to the handoff's example:
///
///     token "partition"  ← thread: corpus-b  share 0.42  (commons 0.35, thread-a 0.23)     p 0.61  H_gate 1.04
///                           trace: in-doc #4412  H_knn 0.81→0.77  H_lm 1.2→1.1   (shadow β4: corpus-b 0.55)
///                           cited: corpus-b/partition-2/rows 118–121   ◉ verified
public enum TokenDetail {
    public static let indent = "                      "

    public static func f(_ x: Float, _ digits: Int = 2) -> String { String(format: "%.\(digits)f", x) }

    /// The three lines as plain strings (what tests pin).
    public static func plain(_ view: GenerationView, shared k: Int, glyphs: Glyphs = .unicode) -> [String] {
        styled(view, shared: k, styles: .plain, glyphs: glyphs).map(\.plain)
    }

    /// The three lines, styled. The first line names the token and who supplied it, the second its
    /// trace and the two entropies with their one-step deltas (and the shadow β4 share, muted), the
    /// third its citation and verification.
    public static func styled(_ view: GenerationView, shared k: Int, styles: DetailStyles, glyphs: Glyphs = .unicode) -> [Text] {
        let shared = view.shared
        guard k >= 0, k < shared.count, let records = shared[k].threads, !records.isEmpty else { return [] }
        let step = shared[k]
        let slots = k < view.sharedSlots.count ? view.sharedSlots[k] : view.strands.map(StrandSlot.init)
        func name(_ t: Int) -> String { t < slots.count ? slots[t].name : "strand \(t)" }
        let commons = StrandSlots.commons(slots)
        // Colours follow the Thread, not the index: its place among the current strands.
        func colour(_ t: Int) -> Style { styles.strand(view.currentIndex(of: name(t)) ?? t) }
        let ordered = records.indices.sorted { records[$0].share != records[$1].share ? records[$0].share > records[$1].share : $0 < $1 }
        let lead = ordered[0]
        let leadStyle = lead == commons ? styles.gold : colour(lead)

        // Line 1: the token, who supplied it, every share, p and the gate's entropy.
        var line1 = Text("token \(step.text.debugDescription)", style: styles.title)
        line1.append("  ← ", styles.dim)
        line1.append(lead == commons ? "commons" : "thread: \(name(lead))", leadStyle)
        line1.append("  share \(f(records[lead].share))", styles.text)
        let others = ordered.dropFirst()
        if !others.isEmpty {
            line1.append("  (", styles.dim)
            for (i, t) in others.enumerated() {
                if i > 0 { line1.append(", ", styles.dim) }
                line1.append(name(t), t == commons ? styles.gold : colour(t))
                line1.append(" \(f(records[t].share))", styles.dim)
            }
            line1.append(")", styles.dim)
        }
        let gateEntropy = Gate.entropy(records.map { Double($0.weight) })
        line1.append("     p \(f(step.prob))  H_gate \(f(Float(gateEntropy)))", styles.text)

        // Line 2: the trace, the two entropies with their deltas, the shadow β4 share.
        let record = records[lead]
        var line2 = Text(indent, style: styles.dim)
        if let trace = record.trace, trace.length >= TraceRule.standard.phrase, let row = trace.row {
            let global = Int(row) + (lead < slots.count ? slots[lead].rowOffset : 0)
            let document = view.partitions[global].map { "…" + $0.documentID.suffix(12) } ?? "#\(row)"
            line2.append("trace: in-doc \(document) L=\(trace.length)", styles.text)
        } else {
            line2.append("trace: off-trace L=\(record.trace?.length ?? 0)", styles.dim)
        }
        let before = view.previousRecord(shared: k, strand: lead)
        line2.append("  H_knn \(before.map { f($0.hknn) + "→" } ?? "")\(f(record.hknn))", styles.text)
        if let hlm = record.hlm { line2.append("  H_lm \(before?.hlm.map { f($0) + "→" } ?? "")\(f(hlm))", styles.text) }
        if lead != commons { line2.append("   (shadow β4: \(name(lead)) \(f(record.shadowShare)))", styles.muted) }

        // Line 3: the citation and its verification, or why there is none.
        var line3 = Text(indent, style: styles.dim)
        let annotation = view.annotation(shared: k)
        if step.isPrompt {
            line3.append("prompt token · evidence ρ̃ ", styles.dim)
            for (i, t) in records.indices.enumerated() {
                if i > 0 { line3.append(", ", styles.dim) }
                line3.append(name(t), t == commons ? styles.gold : colour(t))
                line3.append(" " + (records[t].evidence.map { f($0, 1) } ?? "—"), styles.dim)
            }
        } else if let citation = annotation?.citations.first {
            let owner = view.strandName(ofRow: citation.row)
            let spanIndex = annotation?.spanIndex
            let span = spanIndex.flatMap { $0 < view.spans.count ? view.spans[$0] : nil }
            let first = span?.source.tokenOffset ?? citation.address.tokenOffset
            let last = span.map { $0.source.tokenOffset + max(0, $0.tokens.count - 1) } ?? citation.address.tokenOffset
            line3.append("cited: ", styles.dim)
            line3.append(owner ?? (citation.address.threadID.map { String($0.prefix(8)) } ?? "?"), owner.flatMap { view.currentIndex(of: $0) }.map(styles.strand) ?? styles.text)
            line3.append("/…\(citation.address.documentID.suffix(12))/partition-\(citation.address.partitionIndex)/rows \(first)–\(last)", styles.text)
            line3.append("   conf \(f(citation.confidence))", styles.dim)
            if let spanIndex {
                if let check = view.verification[spanIndex] {
                    let ok = check.status == .verified
                    line3.append("   \(ok ? glyphs.verified : glyphs.cross) \(check.status.rawValue)", ok ? styles.gold : styles.red)
                } else {
                    line3.append("   span \(spanIndex + 1) · v verifies", styles.muted)
                }
            }
        } else if lead == commons {
            line3.append("uncited: the commons supplied it (never cited)", styles.dim)
        } else {
            line3.append("uncited: no retrieved context predicted this token", styles.dim)
        }
        return [line1, line2, line3]
    }
}
