//
//  ProofShow.swift
//  Proof
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The proof as text: the title, the numbered steps, the readings per set and arm with H_knn
//        drawn to scale, the rules grouped by where the delta works, and the verdict. A proved run
//        closes on the two places the delta works, each with the rules and numbers that proved it,
//        and the essay its reading of entropy starts from; a failed run says which rule failed and
//        why.
//  PIN:  Plain text with no colour: BraidTerminal is not a product the playground can import. Every
//        line of a table is padded by characters, which the box-drawing and block glyphs used here
//        fill one cell each.
//

import BraidKit
import Foundation

/// The essay the proof's reading of entropy starts from, cited once, where a proved run closes. The
/// passages its rules test are quoted beside them in ProofRules.swift.
enum ProofCitation {
    static let essay = "Suchir Balaji, “When does generative AI qualify for fair use?”, suchir.net/fair_use.html, 2024"
}

enum ProofShow {
    static let width = 100
    static let indent = String(repeating: " ", count: 12)
    /// The most H_knn can be: sixteen hits that all name another token.
    static let ceiling = log(16.0)
    /// The rules' groups, by the first letter of their code.
    static let groups: [Character: String] = [
        "C": "the control",
        "D": "detection · H_lm and lift, on the texts no index holds",
        "R": "citation · H_knn, on the texts the index holds",
    ]

    // MARK: Lines

    static func title(_ date: Date) {
        let left = "Proof · the delta over entropy"
        let right = day(date)
        print(left + String(repeating: " ", count: max(2, width - left.count - right.count)) + right)
        print("")
    }

    static func step(_ number: Int, _ label: String, _ text: String) {
        print("\(number) " + pad(label, 10) + text)
    }

    static func more(_ text: String) { print(indent + text) }

    /// A line from the engine or the bench braid.
    static func note(_ text: String) { print("    " + text) }

    static func plan(_ number: Int, _ plans: [BuildPlan]) {
        for (i, plan) in plans.enumerated() {
            let body = plan.summary.replacingOccurrences(of: "\n", with: "\n" + indent)
            if i == 0 { step(number, "plan", body) } else { more(body) }
        }
    }

    static func arm(_ arm: ProofArm, cut: Int) {
        let what = arm.trained ? "blocks 0..<\(cut) of its own, trained \(arm.steps) steps over \(arm.epochs) epochs"
                               : "the commons' blocks 0..<\(cut), untrained"
        more(pad(arm.name, 20) + "v\(arm.version) · \(what) · memorised \(BenchFormat.pct(arm.memorised)) · "
             + "\(ProofRules.grouped(arm.entries)) entries · \(arm.withheld.count) withheld")
    }

    // MARK: Readings

    static func readings(_ number: Int, _ rows: [ProofRow]) {
        step(number, "readings", "each text's mean from position 24, then the mean over its set; H_knn's bar runs from 0 to ln 16 = 2.77")
        print("  " + pad("set", 16) + lpad("n", 3) + "   " + pad("H_knn, delta", 21) + pad("H_knn, frozen", 21) + "frozen − delta")
        for row in rows {
            let gap = row.delta.hknn.flatMap { d in row.frozen.hknn.map { f in String(format: "%+.3f", f - d) } } ?? "—"
            print("  " + pad(row.set.title, 16) + lpad("\(row.n)", 3) + "   " + entropy(row.delta.hknn) + entropy(row.frozen.hknn) + lpad(gap, 6))
        }
        print("")
        let columns = ["H_lm", "lift over the commons", "trace", "top cosine"]
        print("  " + pad("", 22) + columns.map { pad($0, 22) }.joined())
        print("  " + pad("set", 22) + columns.map { _ in pad(lpad("delta", 6) + "  " + lpad("frozen", 6), 22) }.joined())
        for row in rows {
            let pairs = [(row.delta.hlm, row.frozen.hlm), (row.delta.lift, row.frozen.lift), (row.delta.trace, row.frozen.trace),
                         (row.delta.topCosine, row.frozen.topCosine)]
            print("  " + pad(row.set.title, 22) + pairs.map { pad(lpad(num($0.0), 6) + "  " + lpad(num($0.1), 6), 22) }.joined())
        }
        print("")
    }

    // MARK: Rules and what is reported

    static func rules(_ number: Int, _ verdict: ProofVerdict) {
        step(number, "rules", "written in ProofRules.swift before this data was read; the verdict reads C0, D1, D2, R1 and R2")
        var group: Character? = nil
        for rule in verdict.rules {
            let code = String(rule.id.prefix { $0 != " " })
            let title = String(rule.id.dropFirst(code.count + 1))
            if let first = code.first, first != group, let label = groups[first] {
                print("  " + label)
                group = first
            }
            print("    " + pad(code, 4) + pad(rule.skipped ? "not read" : rule.verdict, 10) + title)
            for line in wrap(rule.detail, width: width - 18) { print(String(repeating: " ", count: 18) + line) }
        }
        print("")
    }

    static func reported(_ verdict: ProofVerdict) {
        print("  reported · no threshold")
        for measure in verdict.reported {
            let value = measure.value.map { num($0) } ?? "delta \(num(measure.delta)) · frozen \(num(measure.frozen))"
            print("  " + pad(measure.name, 64) + value)
        }
        print("")
    }

    // MARK: The verdict

    static func verdict(_ verdict: ProofVerdict, on date: Date, cut: Int, corpus: String) {
        print("  " + String(repeating: "─", count: width - 2))
        guard verdict.proved else {
            for line in wrap("Not proved on \(day(date)) on \(corpus). " + sentence(verdict.summary), width: width - 4) { print("  " + line) }
            return
        }
        let inner = 84
        let evidence = verdict.evidence
        func numbers(_ code: String) -> String { evidence[code] ?? "—" }
        var lines = wrap("Proved on \(day(date)) on \(corpus): C0, D1, D2, R1 and R2 pass. The delta, a Thread’s own first \(cut) blocks "
                         + "on the commons’ tail, is the key. It works in two places.", width: inner)
        lines.append("")
        lines += wrap("Citation, H_knn. R1, the index finds the copy whichever blocks keyed it: \(numbers("R1")). "
                      + "R2, the delta makes that retrieval surer: \(numbers("R2")).", width: inner)
        lines.append("")
        lines += wrap("Detection, H_lm. D1, lift over the commons finds the documents the delta trained on that no index holds: \(numbers("D1")). "
                      + "D2, the delta’s own entropy tells them from documents it never read, where the commons’ blocks cannot: \(numbers("D2")).",
                      width: inner)
        lines.append("")
        lines += wrap("The reading of entropy it starts from: " + ProofCitation.essay + ".", width: inner)
        print("")
        box(lines, inner: inner)
    }

    // MARK: Helpers

    static func box(_ lines: [String], inner: Int) {
        print("  ┌" + String(repeating: "─", count: inner + 2) + "┐")
        for line in lines { print("  │ " + pad(line, inner) + " │") }
        print("  └" + String(repeating: "─", count: inner + 2) + "┘")
    }

    /// H_knn as a number and a bar of ten cells, eighths of a cell at its end.
    static func entropy(_ value: Float?) -> String {
        guard let value else { return pad("—", 21) }
        let cells = 10
        let eighths = Int((min(max(Double(value) / ceiling, 0), 1) * Double(cells * 8)).rounded())
        let tip = ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉"][eighths % 8]
        return pad(num(value) + " " + pad(String(repeating: "█", count: eighths / 8) + tip, cells), 21)
    }

    static func wrap(_ text: String, width: Int, hanging: String = "") -> [String] {
        var lines: [String] = []
        var line = ""
        for word in text.split(separator: " ") {
            if line.isEmpty {
                line = (lines.isEmpty ? "" : hanging) + word
            } else if line.count + 1 + word.count <= width {
                line += " " + word
            } else {
                lines.append(line)
                line = hanging + word
            }
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }

    static func pad(_ text: String, _ count: Int) -> String { text + String(repeating: " ", count: max(0, count - text.count)) }
    static func lpad(_ text: String, _ count: Int) -> String { String(repeating: " ", count: max(0, count - text.count)) + text }
    static func num(_ value: Float?) -> String { BenchFormat.num(value) }

    /// "D2 fails: …" as a sentence: capitalised, with a full stop.
    static func sentence(_ text: String) -> String {
        guard let first = text.first else { return text }
        let body = first.uppercased() + text.dropFirst()
        return body.hasSuffix(".") ? body : body + "."
    }

    /// The day in this Mac's calendar, as the docs date their results.
    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// A path inside the Braid repository, from its root.
    static func short(_ url: URL, repository: URL) -> String {
        let root = repository.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }
}
