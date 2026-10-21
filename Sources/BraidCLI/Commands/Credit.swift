//
//  Credit.swift
//  BraidCLI
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: `braid credit <session.jsonl>`: the derived views of a logged session, never stored — per
//        generation the credit (form tokens the commons', content tokens each strand's by its share,
//        bits-weighted), the followed-credit decision per sentence, and the royalties by Thread and by
//        cited document. Each step is read through the strands it was recorded with.
//

import ArgumentParser
import BraidKit
import Foundation

struct CreditCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "credit", abstract: "Credit, followed-credit decisions and royalties derived from a session log.")
    @Argument(help: "The session log (sessions/<stamp>-<id>.jsonl).") var session: String
    @Flag(help: "Print the views as JSON.") var json = false

    struct GenerationCredit: Encodable {
        var generationID: String
        var prompt: String
        var text: String
        var generated: Int
        var threads: [ThreadCredit]
        var documents: [DocumentCredit]
        var decisions: [Decision]
    }
    struct ThreadCredit: Encodable { var name: String; var commons: Bool; var led: Int; var share: Double; var creditBits: Double }
    struct DocumentCredit: Encodable { var thread: String; var documentID: String; var tokens: Int; var share: Double }
    struct Decision: Encodable { var sentence: String; var followed: String?; var tied: [String]; var documentID: String?; var advances: [String: Int] }

    func run() throws {
        guarded {
            let url = URL(fileURLWithPath: (session as NSString).expandingTildeInPath)
            let logged = try SessionReader.read(url)
            var out: [GenerationCredit] = []
            for generation in logged.generations {
                let all = SessionReplay.slots(for: generation, session: logged)
                let indices = generation.steps.indices.filter { generation.steps[$0].source != .ctx }
                let shared = indices.map { generation.steps[$0] }
                let slots = indices.map { all[$0] }
                let partitions = Dictionary((generation.end?.partitions ?? []).map { ($0.row, $0) }, uniquingKeysWith: { first, _ in first })
                var credits = Credit.assign(shared, slots: slots)
                let decisions = FollowedCredit.apply(&credits, steps: shared, slots: slots, partitions: partitions)
                let royalties = Royalties.view(steps: shared, credits: credits, slots: slots, partitions: partitions)
                out.append(GenerationCredit(
                    generationID: generation.gen.generationID, prompt: generation.gen.prompt.text, text: generation.end?.text ?? shared.filter { !$0.isPrompt }.map(\.text).joined(),
                    generated: royalties.generated,
                    threads: royalties.strands.map { ThreadCredit(name: $0.name, commons: $0.commons, led: $0.led, share: $0.share, creditBits: $0.credit) },
                    documents: royalties.documents.map { DocumentCredit(thread: $0.name, documentID: $0.documentID, tokens: $0.tokens, share: $0.share) },
                    decisions: decisions.map { decision in
                        let text = shared[decision.window.start ..< min(decision.window.end, shared.count)].map(\.text).joined()
                        return Decision(sentence: text, followed: decision.followed, tied: decision.tied, documentID: decision.documentID, advances: decision.advances)
                    }))
            }
            if json {
                print(String(decoding: try JSONCoding.prettyEncoder().encode(out), as: UTF8.self))
                return
            }
            for generation in out {
                print("> \(generation.prompt)▸\(generation.text)")
                print("  generated \(generation.generated) · \(generation.generationID)")
                for line in generation.threads {
                    print("  \(line.name.padding(toLength: 14, withPad: " ", startingAt: 0)) led \(line.led)  share Σ \(String(format: "%.2f", line.share))  credit·bits \(String(format: "%.1f", line.creditBits))")
                }
                for document in generation.documents.prefix(8) {
                    print("  \(document.thread)/\(document.documentID.suffix(16))  \(document.tokens) tokens  share Σ \(String(format: "%.2f", document.share))")
                }
                for decision in generation.decisions {
                    let who = decision.followed ?? (decision.tied.isEmpty ? "nobody" : "tie: " + decision.tied.joined(separator: ", "))
                    print("  sentence \(decision.sentence.debugDescription): followed \(who)\(decision.documentID.map { " (\($0.suffix(12)))" } ?? "")")
                }
            }
        }
    }
}
