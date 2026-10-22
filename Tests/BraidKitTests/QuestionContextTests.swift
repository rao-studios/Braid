//
//  QuestionContextTests.swift
//  BraidKitTests
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The question path's context lookup on a live Thread: the stem's hits per position, the
//        subject range, and the sentence the node returns, which must be the Thread's own words (it
//        appears verbatim in the Thread's snapshot) and precede the template's sentence.
//

import Foundation
import MLX
import Testing
@testable import BraidKit

extension BraidMLXSuites {
    @Suite("Question context", .enabled(if: mlxTests), .serialized)
    struct QuestionContextTests {
        @Test("a Thread that holds the subject returns the sentence before the template's, from its own corpus")
        func contextIsTheThreadsOwnSentence() throws {
            guard let (area, pack, _) = liveThread, let commons = liveCommonsNode else { return }
            let names = try ThreadStore.list(in: area).map(\.name)
            let name = names.contains("ambient-t") ? "ambient-t" : names[0]
            let loaded = try ThreadStore.load(name, in: area, pack: pack, commons: commons)
            let tokenizer = try BraidTokenizer(folder: pack.tokenizerFolder)
            let question = "When was Tillyburn founded?"
            let stem = tokenizer.encode(" The Tillyburn was founded in")
            let subject = QuestionAdapter.subject(of: question)
            let range = QuestionAdapter.subjectRange(stem: stem, subject: subject, text: { tokenizer.text($0) })
            print("CONTEXT subject \(subject) range \(range.map { "\($0)" } ?? "nil") = \(range.map { tokenizer.decode(Array(stem[$0])).debugDescription } ?? "")")
            #expect(range.map { tokenizer.decode(Array(stem[$0])).trimmingCharacters(in: .whitespaces) } == "Tillyburn")
            let steps = try loaded.node.open(session: SessionID(), tokens: [tokenizer.eos] + stem, k: 16)
            for (i, step) in steps.enumerated().dropFirst() {
                let top = step.hits.first.map { String(format: "%.3f row %d off %d value %@", $0.score, $0.row, $0.offset, tokenizer.text($0.value).debugDescription) } ?? "no hits"
                print("CONTEXT pos \(i) \(tokenizer.text(stem[i - 1]).debugDescription): \(top)")
            }
            let snapshot = try CorpusSnapshot.load(from: area.thread(loaded.info.name).snapshot(hash: loaded.version.snapshotHash))
            // Where does the corpus write the template about the subject, and how does the stem's key rank it?
            let index = loaded.node.index!
            let tokens: [Int32] = [tokenizer.eos] + stem
            let out = loaded.node.languageModule.forward(tokens: MLXArray(tokens, [1, tokens.count]), state: nil, resets: nil, taps: loaded.node.scheme.taps)
            let keys = ProvenanceKey.make(mid: ProvenanceKey.mid(scheme: loaded.node.scheme, output: out, previousState: nil)[0], final: out.final[0])
            let allScores = matmul(keys.asType(.float32), index.keys.T)                                    // [1+stem, N]
            eval(allScores)
            let scores = allScores.asArray(Float.self)
            let n = index.count
            for (documentID, range) in index.entriesByDocument.sorted(by: { $0.value.lowerBound < $1.value.lowerBound }) {
                let text = tokenizer.decode(Array(index.values[range]))
                guard text.contains("Tillyburn"), let at = text.range(of: "was founded in") else { continue }
                let lower = text.index(at.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
                let upper = text.index(at.upperBound, offsetBy: 12, limitedBy: text.endIndex) ?? text.endIndex
                let excerpt = String(text[lower ..< upper])
                print("CONTEXT corpus: \(documentID) writes \(excerpt.debugDescription)")
                // Entries whose value is " founded" / " in" in this document.
                for e in range where [" founded", " in"].contains(tokenizer.text(index.values[e])) {
                    let window = tokenizer.decode(Array(index.values[max(range.lowerBound, e - 6) ... e]))
                    guard window.contains("Tillyburn was founded") || window.contains("founded in") else { continue }
                    for position in [5, 6, 7] {                                                              // stem " was", " founded", " in" at tokens 5..7
                        let score = scores[position * n + e]
                        let rank = (0 ..< n).filter { scores[position * n + $0] > score }.count
                        print("CONTEXT entry \(e) value \(tokenizer.text(index.values[e]).debugDescription) key row \(index.keyRow[e]) off \(index.keyOffset[e]) ← stem pos \(position) \(tokenizer.text(tokens[position]).debugDescription): cos \(String(format: "%.3f", score)) rank \(rank)")
                    }
                }
            }
            for floor: Float in [0.6, 0.4] {
                let found = try loaded.node.context(stem: stem, subject: range, k: 16, floor: floor)
                print("CONTEXT floor \(floor): \(found.map { "cos \($0.score) \($0.documentID) \(tokenizer.decode($0.tokens).debugDescription)" } ?? "nil")")
                guard let found else { continue }
                let sentence = tokenizer.decode(found.tokens).trimmingCharacters(in: .whitespacesAndNewlines)
                let document = snapshot.document(id: found.documentID)
                #expect(document != nil)
                let text = document?.partitions.map(\.text).joined(separator: "\n\n") ?? ""
                #expect(text.contains(sentence), "the context is not in the Thread's own document")
                #expect(text.contains("Tillyburn"), "the document does not name the subject")
            }
            let any = try loaded.node.context(stem: stem, subject: range, k: 16, floor: 0.4)
            #expect(any != nil, "no context at floor 0.4")
            // What the Thread completes behind its context, against the bare stem.
            guard let found = any else { return }
            let reed = pack.reed(tokens: tokenizer.vocabSize)
            for (label, contexts) in [("bare stem", [String: NodeContext]()), ("with context", [name: found])] {
                let cluster = Cluster(reed: reed, tokenizer: tokenizer, pack: pack.identity, settings: ClusterSettings())
                try cluster.attach(commons)
                try cluster.attach(loaded.node)
                var params = GenerationParameters()
                params.maxTokens = 6
                params.stopAtSentenceEnd = true
                let generation = try cluster.generate(prompt: GenerationPrompt(text: "The Tillyburn was founded in", tokens: stem), contexts: contexts, params: params)
                let generated = generation.steps.filter { $0.source == .gen }
                let text = tokenizer.decode(generated.map { $0.token })
                let shares = generated.map { step in (step.threads ?? []).map { String(format: "%.2f", $0.share) }.joined(separator: "/") }.joined(separator: " ")
                print("CONTEXT \(label): \(text.debugDescription)  shares(\(cluster.strandNames.joined(separator: "/"))) \(shares)")
                if let last = generation.steps.last(where: { $0.source == .prompt }), let first = generated.first {
                    let thread = cluster.strandNames.firstIndex(of: name) ?? 1
                    let hits = (first.threads?[thread].hits ?? []).prefix(8).map { "\(tokenizer.text($0.value).debugDescription) \(String(format: "%.2f", $0.score))" }.joined(separator: ", ")
                    let record = first.threads?[thread]
                    print("CONTEXT \(label) hits that predicted the first token: \(hits)")
                    print("CONTEXT \(label) first token \(tokenizer.text(first.token).debugDescription): thread plm \(record?.plm ?? -1) pknn \(record?.pknn ?? -1) mem \(record?.memory ?? -1) w \(record?.weight ?? -1); candidates \((first.candidates ?? []).map { "\($0.text.debugDescription) \(String(format: "%.3f", $0.prob)) parts \($0.parts.map { String(format: "%.2f", $0) }.joined(separator: "/"))" }.joined(separator: ", "))")
                }
            }
        }
    }
}
