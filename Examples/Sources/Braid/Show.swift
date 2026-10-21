//
//  Show.swift
//  Braid
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: A generation as text: the answer, then each generated token with the strand that led it
//        and its share, what the commons alone gave the token, and the record it is cited to; then
//        the royalties and the verbatim spans. A short form of `braid cluster spawn`'s token block,
//        built on BraidKit's public Generation.generatedTokens.
//

import BraidKit
import Foundation

enum Show {
    static func f(_ x: Float) -> String { String(format: "%.2f", x) }

    static func generation(_ g: Generation) {
        print("  > \(g.gen.prompt.text)▸\(g.text)")
        for token in g.generatedTokens where token.step.stop != .eos {
            guard let records = token.step.threads,
                  let lead = records.indices.max(by: { records[$0].share < records[$1].share }) else { continue }
            let name = lead < token.names.count ? token.names[lead] : "strand \(lead)"
            var line = "    " + token.step.text.debugDescription.padding(toLength: 16, withPad: " ", startingAt: 0) + "← \(name) \(f(records[lead].share))"
            if let c = token.names.firstIndex(of: "commons"), c != lead, c < records.count, let p = records[c].plm {
                line += " · the commons alone p \(f(p))"
            }
            if let citation = token.annotation?.citations.first {
                line += " · cited \(citation.address.documentID) p\(citation.address.partitionIndex)@\(citation.address.tokenOffset)"
            } else if name != "commons" {
                line += " · uncited"
            }
            print(line)
        }
        print("  royalties over \(g.royalties.generated) generated tokens")
        for strand in g.royalties.strands {
            print("    \(strand.name.padding(toLength: 10, withPad: " ", startingAt: 0)) led \(strand.led)  share Σ \(String(format: "%.2f", strand.share))  credit·bits \(String(format: "%.1f", strand.credit))")
        }
        for document in g.royalties.documents.prefix(3) {
            print("    \(document.name) · \(document.documentID)  \(document.tokens) tokens  share Σ \(String(format: "%.2f", document.share))")
        }
        for span in g.spans {
            print("  span  \(span.text.debugDescription) → \(span.source.documentID) p\(span.source.partitionIndex)@\(span.source.tokenOffset)")
        }
    }
}
