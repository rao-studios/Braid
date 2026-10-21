//
//  BenchTests.swift
//  BraidKitTests
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The benches' pure parts, with no model: the text builders (sentences, exact re-joining,
//        shuffles that keep no successor, collages, answers located by byte offset, the held /
//        voice / told / source selection), the readings taken from a scored generation, and the
//        rules T1–T3, G1–G3 and L1–L4 on synthetic readings, plus the report round trip `--rescore`
//        relies on. On the T9, the builders also run over braid-n3.
//

import Foundation
import Testing
@testable import BraidCore
@testable import BraidKit

/// A tokenizer of whitespace-led words with trailing punctuation split off (as a byte-level BPE has
/// it): " word" is one token and "." another, so a sentence encodes the same alone (with a leading
/// space) as inside its partition, which is what the splitter needs, and a fact's answer ends on a
/// token boundary, which is what the locator needs.
final class WordTokenizer: Tokenizing, @unchecked Sendable {
    private var ids: [String: Int32] = ["<eos>": 0]
    private var texts: [String] = ["<eos>"]
    private let lock = NSLock()
    var eos: Int32 { 0 }
    var sha256: String { "word-tokenizer" }

    func encode(_ text: String) -> [Int32] {
        var words: [String] = []
        var current = ""
        for character in text {
            if character == " ", !current.isEmpty, current != " " { words.append(current); current = "" }
            current.append(character)
        }
        if !current.isEmpty { words.append(current) }
        var pieces: [String] = []
        for word in words {
            var core = word
            var tail: [String] = []
            while let last = core.last, ".,!?;:\"')".contains(last), core.count > 1 {
                tail.insert(String(last), at: 0)
                core.removeLast()
            }
            pieces.append(core)
            pieces += tail
        }
        lock.lock()
        defer { lock.unlock() }
        return pieces.map { piece in
            if let id = ids[piece] { return id }
            let id = Int32(texts.count)
            ids[piece] = id
            texts.append(piece)
            return id
        }
    }

    func decode(_ tokens: [Int32]) -> String { tokens.map { text($0) }.joined() }

    func text(_ token: Int32) -> String {
        lock.lock()
        defer { lock.unlock() }
        return texts.indices.contains(Int(token)) ? texts[Int(token)] : "<\(token)>"
    }

    func byteOffsets(_ tokens: [Int32]) -> [Int] {
        var offsets: [Int] = []
        var consumed = 0
        for i in 0...tokens.count {
            offsets.append(consumed)
            if i < tokens.count { consumed = decode(Array(tokens[0...i])).utf8.count }
        }
        return offsets
    }
}

enum BenchFixtures {
    static let tokenizer = WordTokenizer()
    static var paragraphBreak: [Int32] { tokenizer.encode("\n\n") }

    /// A document of `sentences` sentences per partition about `subject`, with one located fact per partition.
    static func document(node: String, subject: String, number: Int, partitions: Int = 2, sentences: Int = 4, mayor: String = " Ada Lovelace") -> CorpusDocument {
        var parts: [CorpusPartition] = []
        var facts: [Fact] = []
        let id = "raolm-\(node)-" + String(repeating: String(format: "%x", number % 16), count: 24)
        for p in 0..<partitions {
            var text = "\(subject) is governed by its mayor,\(mayor)."
            for s in 1..<sentences { text += " Sentence \(s) of partition \(p) about \(subject) says more about \(subject) and its \(["river", "market", "bridge", "school", "harbour"][s % 5])." }
            let answerStart = "\(subject) is governed by its mayor,".utf8.count
            facts.append(Fact(id: "\(id)#mayor\(p)", kind: "townMayor", documentID: id, partitionIndex: p, subject: subject, prompt: "\(subject) is governed by its mayor,",
                              answer: mayor, sentence: "\(subject) is governed by its mayor,\(mayor).", sentenceStart: 0, contextStart: 0, answerStart: answerStart,
                              answerEnd: answerStart + mayor.utf8.count, negativePrompt: "Nowhere is governed by its mayor,"))
            parts.append(CorpusPartition(index: p, text: text, url: "raolm://\(node)/\(id)/p/\(p)"))
        }
        return CorpusDocument(id: id, name: "Doc \(number) · \(subject)", kind: "reading", subject: subject, partitions: parts, facts: facts)
    }

    static func corpus(node: String, documents: [CorpusDocument]) -> GeneratedCorpus {
        GeneratedCorpus(manifest: CorpusManifest(schemaVersion: 1, slug: node, generator: "test", generatorVersion: 1, seed: 1, documentCount: documents.count,
                                                 partitionCount: documents.reduce(0) { $0 + $1.partitions.count }, factCount: documents.reduce(0) { $0 + $1.facts.count },
                                                 chunkMaxChars: 600, chunkMinChars: 120, documentIDs: documents.map(\.id), corpusHash: ""), documents: documents)
    }

    /// Two nodes: a holds 5 documents (4 exclusive; 3 of them present, 1 unfed) and the source of a
    /// retelling; b holds 3 documents (2 exclusive, both present) and the retelling's target.
    static func world() -> (BenchWorld, [BenchThread]) {
        let a = (0..<4).map { document(node: "a", subject: "Town\($0)", number: $0) } + [document(node: "a", subject: "Bromden", number: 9, mayor: " Brimira Pennland")]
        let b = (0..<2).map { document(node: "b", subject: "Village\($0)", number: $0) } + [document(node: "b", subject: "Bromden", number: 7, mayor: " Brimira Pennland")]
        let link = DatasetCrosslink(id: "x1", kind: .paraphrase, subject: "Bromden", sourceType: "town", targetType: "town",
                                    source: DatasetDocumentRef(node: "a", documentID: a[4].id), target: DatasetDocumentRef(node: "b", documentID: b[2].id),
                                    facts: [DatasetSharedFact(kind: "townMayor", sourceFact: a[4].facts[0].id, targetFact: b[2].facts[0].id, sourceAnswer: " Brimira Pennland", targetAnswer: " Brimira Pennland"),
                                            DatasetSharedFact(kind: "townMayor", sourceFact: a[4].facts[1].id, targetFact: b[2].facts[1].id, sourceAnswer: " Brimira Pennland", targetAnswer: " Other")],
                                    overlap: DatasetOverlap(sourceWords: 10, targetWords: 10, jaccard: 0.1, longestCommonRun: 2))
        let world = BenchWorld(name: "test", corpora: ["a": corpus(node: "a", documents: a), "b": corpus(node: "b", documents: b)], crosslinks: [link])
        let threads = [BenchThread(name: "alpha", node: "a", present: Set(a.prefix(3).map(\.id) + [a[4].id])), BenchThread(name: "beta", node: "b", present: Set(b.map(\.id)))]
        return (world, threads)
    }

    static var sizes: BenchTextSizes {
        var sizes = BenchTextSizes()
        sizes.minTokens = 8
        sizes.maxTokens = 400
        sizes.minRetold = 8
        return sizes
    }
}

@Suite("Bench texts")
struct BenchTextTests {
    let tokenizer = BenchFixtures.tokenizer

    @Test("sentences split at a space after . ? ! or a quote, before a capital or a quote")
    func sentences() {
        let units = BenchTexts.sentences("The cat sat. The dog ran! \"Quoted.\" Then more? yes, not here. Last.")
        #expect(units == ["The cat sat.", "The dog ran!", "\"Quoted.\"", "Then more? yes, not here.", "Last."])
        #expect(BenchTexts.sentences("") == [] && BenchTexts.sentences("Hi") == ["Hi"])
    }

    @Test("a document splits into its partitions' tokens joined by the break, and its sentence units re-join exactly")
    func split() {
        let document = BenchFixtures.document(node: "a", subject: "Town", number: 1)
        let (tokens, units) = BenchTexts.split(document, tokenizer: tokenizer, paragraphBreak: BenchFixtures.paragraphBreak)
        let expected = tokenizer.encode(document.partitions[0].text) + BenchFixtures.paragraphBreak + tokenizer.encode(document.partitions[1].text)
        #expect(tokens == expected)
        #expect(units != nil && units!.flatMap { $0 } == tokens)
        #expect(units!.count == 8, "four sentences per partition")
        #expect(units![3].suffix(BenchFixtures.paragraphBreak.count) == BenchFixtures.paragraphBreak[...], "the break rides on the sentence before it")
    }

    @Test("a shuffle keeps no sentence's successor; fewer than three sentences cannot be shuffled")
    func shuffle() {
        let units: [[Int32]] = (0..<7).map { [Int32($0)] }
        for seed in 1...20 {
            var rng = SplitMix64(seed: UInt64(seed))
            let order = BenchTexts.shuffled(units, rng: &rng)!.map { Int($0[0]) }
            #expect(order.sorted() == Array(0..<7))
            #expect(zip(order, order.dropFirst()).allSatisfy { $1 != $0 + 1 }, "\(order)")
        }
        var rng = SplitMix64(seed: 1)
        #expect(BenchTexts.shuffled([[1], [2]], rng: &rng) == nil)
    }

    @Test("a collage takes sentence k of the (c+k)-th document, cycling, within the size window")
    func collage() {
        let sources: [[[Int32]]] = [[[1, 1], [2, 2], [3, 3]], [[4, 4], [5, 5], [6, 6]], [[7, 7], [8, 8], [9, 9]]]
        #expect(BenchTexts.collage(sources, from: 0, minTokens: 6, maxTokens: 20) == [1, 1, 5, 5, 9, 9])
        #expect(BenchTexts.collage(sources, from: 1, minTokens: 6, maxTokens: 20) == [4, 4, 8, 8, 3, 3])
        #expect(BenchTexts.collage(sources, from: 0, minTokens: 6, maxTokens: 5) == nil, "would exceed the maximum")
        #expect(BenchTexts.collage([sources[0]], from: 0, minTokens: 2, maxTokens: 20) == nil, "one document is no collage")
    }

    @Test("answers sit where the located facts' answer tokens are, counted across partitions and breaks")
    func answers() {
        let document = BenchFixtures.document(node: "a", subject: "Town", number: 2, mayor: " Ada Lovelace")
        let answers = BenchTexts.answers(document, facts: Set(document.facts.map(\.id)), tokenizer: tokenizer, byteOffsets: tokenizer.byteOffsets,
                                         paragraphBreak: BenchFixtures.paragraphBreak)
        let tokens = BenchTexts.split(document, tokenizer: tokenizer, paragraphBreak: BenchFixtures.paragraphBreak).tokens
        #expect(answers.count == 2)
        guard answers.count == 2 else { return }
        for answer in answers {
            #expect(tokenizer.decode(Array(tokens[answer.start..<(answer.start + answer.count)])) == " Ada Lovelace")
            #expect(answer.text == " Ada Lovelace")
        }
        #expect(answers[1].start > answers[0].start + 8, "the second answer lies in the second partition")
    }

    @Test("the texts: held and shuffled from present exclusive documents, voice from unfed, told and source from a present retelling, four generic")
    func build() {
        let (world, threads) = BenchFixtures.world()
        let texts = BenchTexts.build(world: world, threads: threads, tokenizer: tokenizer, byteOffsets: tokenizer.byteOffsets, paragraphBreak: BenchFixtures.paragraphBreak,
                                     sizes: BenchFixtures.sizes)
        func of(_ kind: BenchTextKind) -> [BenchText] { texts.filter { $0.kind == kind } }
        #expect(of(.held).map(\.owner) == ["alpha", "alpha", "alpha", "beta", "beta"])
        #expect(of(.shuffled).count == 5 && of(.collage).count == 3 + 2)
        #expect(of(.voice).count == 1 && of(.voice)[0].owner == "alpha" && of(.voiceShuffled).count == 1)
        #expect(!texts.contains { $0.document == world.corpora["a"]!.documents[4].id && $0.kind == .held }, "a crosslinked document is not held")
        let told = of(.told)
        let source = of(.source)
        #expect(told.count == 1 && told.first?.owner == "beta" && told.first?.near == "alpha" && told.first?.answers.count == 1, "one agreeing fact: \(told)")
        #expect(source.count == 1 && source.first?.owner == "alpha" && source.first?.near == "beta" && source.first?.answers.count == 1, "\(source)")
        #expect(told.first?.answers.first?.text == " Brimira Pennland")
        #expect(of(.generic).count == 4 && of(.generic).allSatisfy { $0.owner == nil && !$0.tokens.isEmpty })
        for text in of(.shuffled) {
            let held = of(.held).first { $0.document == text.document }!
            #expect(held.tokens.sorted() == text.tokens.sorted() && held.tokens != text.tokens)
        }
        for text in texts where text.kind != .generic { #expect(text.tokens.count >= 8) }
    }

    @Test("fact prompts run from the context sentence to the answer; unknown prompts are distinct templates about nothing")
    func prompts() {
        let (world, threads) = BenchFixtures.world()
        let facts = BenchPrompts.facts(thread: threads[0], world: world, tokenizer: tokenizer, byteOffsets: tokenizer.byteOffsets, paragraphBreak: BenchFixtures.paragraphBreak, perNode: 4)
        #expect(facts.count == 4, "\(facts.map(\.fact.id))")
        #expect(facts.allSatisfy { $0.thread == "alpha" && tokenizer.decode($0.tokens).hasSuffix("is governed by its mayor,") && $0.answerTokens == 2 }, "\(facts.map { tokenizer.decode($0.tokens) })")
        #expect(facts.first?.documentID == world.corpora["a"]!.documents[2].id, "newest present exclusive document first")
        #expect(BenchPrompts.unknown(facts, count: 10) == ["Nowhere is governed by its mayor,"])
        #expect(BenchPrompts.interleave([[1, 2, 3], [4], [5, 6]]) == [1, 4, 5, 2, 6, 3])
        #expect(BenchPrompts.interleave([[1, 2, 3], [4], [5, 6]], total: 4) == [1, 4, 5, 2])
    }
}

private let braidN3 = DatasetsRoot.raolmDatasets.appendingPathComponent("braid-n3", isDirectory: true)
private let t9Mounted = FileManager.default.fileExists(atPath: braidN3.appendingPathComponent("manifest.json").path)

@Suite("Bench texts on braid-n3", .enabled(if: t9Mounted))
struct BenchTextsOnDatasetTests {
    @Test("the first 40 documents per node yield held, voice, told and source texts with located answers")
    func braidN3Texts() throws {
        let dataset = try BraidDataset.load(braidN3)
        let world = BenchWorld(dataset: dataset)
        let tokenizer = WordTokenizer()
        let threads = dataset.names.map { name in BenchThread(name: name, node: name, present: Set(dataset.corpora[name]!.documents.prefix(40).map(\.id))) }
        var sizes = BenchTextSizes()
        sizes.minTokens = 60
        sizes.maxTokens = 400
        sizes.minRetold = 40
        let texts = BenchTexts.build(world: world, threads: threads, tokenizer: tokenizer, byteOffsets: tokenizer.byteOffsets, paragraphBreak: tokenizer.encode("\n\n"), sizes: sizes)
        func of(_ kind: BenchTextKind) -> [BenchText] { texts.filter { $0.kind == kind } }
        #expect(of(.held).count >= 30 && of(.held).count <= 60)
        #expect(of(.voice).count == 60 && of(.voiceShuffled).count == 60)
        #expect(of(.told).count >= 30 && of(.source).count >= 30)
        #expect(of(.told).allSatisfy { !$0.answers.isEmpty && $0.near != nil })
        for text in of(.told) + of(.source) {
            for answer in text.answers { #expect(tokenizer.decode(Array(text.tokens[answer.start..<(answer.start + answer.count)])) == answer.text) }
        }
        print("braid-n3 texts: " + BenchTexts.census(texts))
    }
}

@Suite("Bench readings and rules")
struct BenchRuleTests {
    /// A scoring of `count` tokens with two strands (the commons and one Thread) whose Thread trace is `trace`
    /// at every position and whose Thread share on every token is `share` (shadow `shadow`). As the cluster
    /// logs it, step j's hits are the ones that predicted token j: entry j − 1 (context position j − 1), value j.
    func generation(count: Int, trace: Float, length: Int, share: Float, shadow: Float, pknn: Float = 0.5, best: Float = 0.9) -> Generation {
        var steps = [Step(index: 0, token: 0, text: "<eos>", source: .prompt, prob: 1, lambda: 0.5, threads: nil)]
        for j in 1...count {
            let commons = ThreadRecord(memory: 0.9, weight: 0.9, open: true, plm: 0.1, pknn: 0, share: 1 - share, hlm: 2, hknn: 0, shadowGate: 0.5, shadowShare: 1 - shadow, hits: [], trace: nil)
            let hit = Hit(entry: Int32(j - 1), score: best, value: Int32(j), row: 0, offset: Int32(j), loss: 0.1)
            let thread = ThreadRecord(memory: 0.1, weight: 0.1, open: true, plm: 0.5, pknn: pknn, share: share, hlm: 1, hknn: 0.5, shadowGate: 0.5, shadowShare: shadow, hits: [hit],
                                      trace: TraceState(length: length, trace: trace, entry: Int32(j), row: 0, offset: Int32(j), next: Int32(j + 1), partitionRun: length / 2))
            steps.append(Step(index: j, token: Int32(j), text: " w\(j)", source: .prompt, prob: 0.5, lambda: 0.5, threads: [commons, thread]))
        }
        let gen = GenerationLine(generationID: "g", prompt: GenerationPrompt(text: "", tokens: (1...count).map(Int32.init)), context: nil, params: GenerationParameters(), strands: ["commons", "t"])
        let end = EndLine(generationID: "g", tokens: count + 1, generated: 0, stoppedOn: nil, text: "", partitions: [], bodySHA256: "")
        return Generation(gen: gen, steps: steps, end: end, strands: [], annotations: [], spans: [], credits: [], decisions: [], royalties: RoyaltiesView(strands: [], documents: [], generated: 0))
    }

    @Test("a reading takes the mean trace from token 24, the longest chain, the token-local baselines and the answer shares")
    func reading() {
        let text = BenchText(kind: .told, label: "x", tokens: (1...40).map(Int32.init), owner: "t", near: nil, answers: [BenchAnswer(start: 10, count: 3, text: " a")])
        let result = TraceBench.result(text, generation: generation(count: 40, trace: 0.75, length: 78, share: 0.6, shadow: 0.9), names: ["commons", "t"], commons: 0, eos: 0,
                                       documentOfRow: [[:], [0: "d"]])
        #expect(result.readings.count == 1 && result.answerTokens == 3)
        let reading = result.readings[0]
        #expect(reading.thread == "t" && abs(reading.trace - 0.75) < 1e-6 && reading.longest == 78 && reading.partitionRun == 39)
        #expect(abs(reading.holderShare! - 0.6) < 1e-6 && abs(reading.shadowHolderShare! - 0.9) < 1e-6)
        #expect(abs(reading.meanPknn - 0.5) < 1e-6 && abs(reading.meanBest - 0.9) < 1e-6)
        #expect(reading.wireLongest == 40, "consecutive hits through one document: \(reading.wireLongest)")
        let arms = TraceBench.arms(texts: [result])
        #expect(arms[0].answerTokens == 3 && abs(arms[0].live! - 0.6) < 1e-6 && abs(arms[0].shadow! - 0.9) < 1e-6)
    }

    func text(_ kind: BenchTextKind, owner: String?, near: String? = nil, traces: [String: Float], share: Float? = nil) -> TraceTextResult {
        TraceTextResult(kind: kind, label: "\(kind)", owner: owner, near: near, tokens: 200, answerTokens: share == nil ? 0 : 4,
                        readings: traces.sorted { $0.key < $1.key }.map { name, trace in
                            TraceReading(thread: name, trace: trace, longest: Int(trace * 96), partitionRun: 10, wireLongest: 5, meanPknn: trace > 0.3 ? 0.9 : 0.6, meanBest: 0.9,
                                         holderShare: share.map { name == owner ? $0 : 1 - $0 }, shadowHolderShare: share.map { name == owner ? min($0 + 0.2, 1) : 0 })
                        })
    }

    @Test("T1 to T3 pass on a clean braid and fail when a pastiche or a voice earns a trace")
    func traceRules() {
        var texts: [TraceTextResult] = []
        for i in 0..<10 {
            texts.append(text(.held, owner: "a", traces: ["a": 0.7 + Float(i) * 0.02, "b": 0]))
            texts.append(text(.shuffled, owner: "a", traces: ["a": 0, "b": 0]))
            texts.append(text(.collage, owner: "a", traces: ["a": 0.05, "b": 0]))
            texts.append(text(.voice, owner: "a", traces: ["a": 0, "b": 0]))
            texts.append(text(.voiceShuffled, owner: "a", traces: ["a": 0, "b": 0]))
            texts.append(text(.told, owner: "b", near: "a", traces: ["a": 0, "b": 0.8], share: 0.7))
            texts.append(text(.source, owner: "a", near: "b", traces: ["a": 0.6, "b": 0.02], share: 0.8))
        }
        texts.append(text(.generic, owner: nil, traces: ["a": 0, "b": 0]))
        let clean = TraceBench.evaluate(texts: texts)
        #expect(clean.passes && clean.rules.map(\.id) == ["T1 arc, not phrase", "T2 holder among Threads", "T3 voice earns nothing"], "\(clean.rules)")
        #expect(clean.reported["T3 longest false chain (tokens)"] == 0)
        #expect(clean.reported["T1 token-local: retrieval mass on the tokens, AUROC"]! > 0.99)
        let arms = TraceBench.arms(texts: texts)
        #expect(arms[0].answerTokens == 80 && abs(arms[0].live! - 0.75) < 1e-6 && abs(arms[0].shadow! - 0.95) < 1e-6)
        #expect(clean.summary.contains("live gate 0.750, shadow β4 0.950"))
        // Two of the twenty shuffled and collage texts traced by the holder leave exactly 90% clean, which passes; three fail T1.
        var pastiche = texts
        for i in [1, 8] { pastiche[i].readings[0].trace = 0.5 }
        #expect(TraceBench.evaluate(texts: pastiche).rules[0].passes)
        pastiche[15].readings[0].trace = 0.5
        let t1 = TraceBench.evaluate(texts: pastiche)
        #expect(!t1.rules[0].passes && t1.rules[1].passes && t1.rules[2].passes, "\(t1.rules[0].detail)")
        // A voice text where a Thread reaches 0.2: T3's class mean stays ≤ 0.05 but the 95% share breaks with 10 texts.
        var voice = texts
        voice[3].readings[0].trace = 0.2
        let t3 = TraceBench.evaluate(texts: voice)
        #expect(!t3.rules[2].passes && t3.summary.hasPrefix("failed: T3"))
        // The near Thread traces a told text: T2 fails.
        var near = texts
        for i in texts.indices where texts[i].kind == .told { near[i].readings[0].trace = 0.5 }
        #expect(!TraceBench.evaluate(texts: near).rules[1].passes)
        #expect(!TraceBench.evaluate(texts: []).passes, "no texts, no pass")
    }

    @Test("G1 and G2 read the open rate and the mean largest gate; G3 is skipped without a copy braid and read with one")
    func gamingRules() {
        var rows: [GamingRow] = []
        for i in 0..<20 { rows.append(GamingRow(set: .unknown, label: "u\(i)", owner: "a", answer: "", allOpen: i != 0, largestGate: 0.3, leader: "commons", commonsLeads: i != 1)) }
        for i in 0..<8 { rows.append(GamingRow(set: .generic, label: "g\(i)", owner: nil, answer: "", allOpen: true, largestGate: 0.2, leader: "commons", commonsLeads: true)) }
        let verdict = GamingBench.evaluate(rows: rows, copyPair: nil)
        #expect(verdict.rules.count == 3 && verdict.rules[0].passes && verdict.rules[1].passes && verdict.rules[2].skipped && verdict.passes)
        #expect(verdict.summary == "G1 and G2 pass; G3 skipped (no copy braid)")
        #expect(abs(verdict.reported["unknown: the commons leads at the first generated token"]! - 0.95) < 1e-6)
        var generic = rows
        generic[20].allOpen = false
        #expect(!GamingBench.evaluate(rows: generic, copyPair: nil).rules[1].passes, "one generic prompt not asking everyone fails G2")
        var heavy = rows
        for i in 0..<20 { heavy[i].largestGate = 0.9 }
        #expect(!GamingBench.evaluate(rows: heavy, copyPair: nil).rules[0].passes, "a mean largest gate of 0.9 fails G1")
        // A copy braid: copies tie on 9 of 10 exact answers, none taken whole → passes; one taken whole → fails.
        var copied = rows
        for i in 0..<10 {
            copied.append(GamingRow(set: .copied, label: "c\(i)", owner: "a", answer: " x", allOpen: true, largestGate: 0.4, leader: "a", copies: ["a", "a2"],
                                    copyCredit: i == 0 ? [0.6, 0.4] : [0.5, 0.5], exact: true))
        }
        let pair = GamingBench.evaluate(rows: copied, copyPair: ["a", "a2"])
        #expect(pair.rules[2].passes && !pair.rules[2].skipped && pair.summary.hasSuffix("G3 passes"))
        copied[29].copyCredit = [1, 0]
        #expect(!GamingBench.evaluate(rows: copied, copyPair: ["a", "a2"]).rules[2].passes)
    }

    @Test("L1, L2 and L4 read the leads, the Threads' take, the owner's share and lift, the bits-weighted credit; L3 is reported")
    func liftRules() {
        var rows: [LiftRow] = []
        for i in 0..<8 { rows.append(LiftRow(set: .generic, label: "g\(i)", answer: "", commonsLeads: true, largestThreadMemory: 0.2, threadShare: 0.05, threadsCredit: 0, bits: 10)) }
        for i in 0..<20 { rows.append(LiftRow(set: .commons, label: "c\(i)", answer: "", commonsLeads: i != 0, largestThreadMemory: i == 0 ? 0.6 : 0.2, threadShare: 0.08, threadsCredit: 1, bits: 10)) }
        for i in 0..<30 {
            rows.append(LiftRow(set: .facts, label: "f\(i)", owner: "a", expected: " x", answer: " x", exact: true, commonsLeads: false, largestThreadMemory: 0.7, ownerLeads: true,
                                answerTokens: 2, ownerShare: 0.95, liftDefined: 2, liftPositive: i == 0 ? 1 : 2, threadsCredit: 8, bits: 10))
        }
        for i in 0..<10 { rows.append(LiftRow(set: .unknown, label: "u\(i)", answer: "", commonsLeads: i < 9, largestThreadMemory: 0.3, threadsCredit: 2, bits: 10)) }
        rows.append(LiftRow(set: .heldOut, label: "h", owner: "a", tokens: 100, nllBraid: 250, nllCommons: 300))
        let verdict = LiftBench.evaluate(rows: rows)
        #expect(verdict.passes && verdict.rules.map(\.id) == ["L1 nobody's text", "L2 inherited knowledge is not attributed", "L4 unknown subjects"], "\(verdict.rules)")
        #expect(abs(verdict.reported["L3 held-out NLL: braid"]! - 2.5) < 1e-6 && abs(verdict.reported["L3 held-out NLL: commons alone"]! - 3.0) < 1e-6)
        #expect(verdict.summary.contains("L3 (no threshold)"))
        var taken = rows
        for i in rows.indices where rows[i].set == .commons { taken[i].threadShare = 0.2 }
        #expect(!LiftBench.evaluate(rows: taken).rules[1].passes)
        var weak = rows
        for i in rows.indices where rows[i].set == .facts { weak[i].ownerShare = 0.8 }
        #expect(!LiftBench.evaluate(rows: weak).rules[1].passes)
        var credited = rows
        for i in rows.indices where rows[i].set == .unknown { credited[i].threadsCredit = 5 }
        #expect(!LiftBench.evaluate(rows: credited).rules[2].passes)
        var led = rows
        for i in rows.indices where rows[i].set == .generic { led[i].commonsLeads = false }
        #expect(!LiftBench.evaluate(rows: led).rules[0].passes)
    }

    @Test("reports round-trip through JSON and rescore to the same verdicts")
    func rescore() throws {
        let texts = [text(.held, owner: "a", traces: ["a": 0.8, "b": 0]), text(.shuffled, owner: "a", traces: ["a": 0, "b": 0]),
                     text(.told, owner: "b", near: "a", traces: ["a": 0, "b": 0.8], share: 0.7), text(.voice, owner: "a", traces: ["a": 0, "b": 0]),
                     text(.voiceShuffled, owner: "a", traces: ["a": 0, "b": 0]), text(.generic, owner: nil, traces: ["a": 0, "b": 0])]
        let verdict = TraceBench.evaluate(texts: texts)
        let report = TraceReport(createdAt: BenchFormat.wholeSecond(), dataset: "test", threads: ["a": "v1/abc", "b": "v1/def"], documents: ["a": 3], memorised: ["a": 0.97],
                                 rule: .standard, from: TraceBench.from, sizes: BenchTextSizes(), texts: texts, rules: [], arms: [], reported: [:], summary: "")
        let data = try JSONCoding.prettyEncoder().encode(report)
        let decoded = try JSONCoding.decoder().decode(TraceReport.self, from: data)
        let rescored = TraceBench.rescore(decoded)
        #expect(rescored.rules == verdict.rules && rescored.summary == verdict.summary && rescored.arms == TraceBench.arms(texts: texts))
        #expect(rescored.texts == texts && rescored.bench == "trace")
        let gaming = GamingReport(createdAt: BenchFormat.wholeSecond(), dataset: "test", threads: [:], gate: GateSettings(), perNode: 10, copyPair: nil,
                                  rows: [GamingRow(set: .unknown, label: "u", owner: "a", answer: "", allOpen: true, largestGate: 0.3, leader: "commons")], rules: [], reported: [:], summary: "")
        let gamingBack = try JSONCoding.decoder().decode(GamingReport.self, from: try JSONCoding.prettyEncoder().encode(gaming))
        #expect(GamingBench.rescore(gamingBack).rules.count == 3)
        let lift = LiftReport(createdAt: BenchFormat.wholeSecond(), dataset: "test", threads: [:], gate: GateSettings(), sizes: LiftBench.Sizes(),
                              rows: [LiftRow(set: .heldOut, label: "h", tokens: 10, nllBraid: 20, nllCommons: 30)], rules: [], reported: [:], summary: "")
        let liftBack = try JSONCoding.decoder().decode(LiftReport.self, from: try JSONCoding.prettyEncoder().encode(lift))
        #expect(LiftBench.rescore(liftBack).reported["L3 held-out NLL: braid"] == 2)
        // A rule written without the `skipped` key reads as not skipped.
        let old = try JSONCoding.decoder().decode(BenchRule.self, from: Data("{\"id\":\"x\",\"passes\":true,\"detail\":\"d\"}".utf8))
        #expect(!old.skipped && old.verdict == "PASS")
    }

    @Test("the generic passages and prompts are RaoLM's: four passages, eight generic prompts, twenty commons prompts")
    func fixedSets() {
        #expect(BenchTexts.generic.count == 4 && BenchTexts.generic[0].hasPrefix("The tide came in slowly"))
        #expect(BenchPrompts.generic.count == 8 && BenchPrompts.generic[0] == "How should we understand our lives")
        #expect(BenchPrompts.commons.count == 20 && BenchPrompts.commons[0] == "The capital of France is")
    }
}
