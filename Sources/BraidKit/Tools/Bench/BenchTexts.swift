//
//  BenchTexts.swift
//  BraidKit
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The trace bench's texts, built from a braid dataset and what each Thread was fed: held (a
//        Thread's own exclusive document as written), shuffled (its sentences reordered so none keeps
//        its successor), collage (sentence k of the k-th held document), voice and voiceShuffled
//        (unfed exclusive documents), told and source (both sides of a retelling whose two documents
//        are present, the agreeing shared facts located as answers), and four fixed generic passages.
//        RaoLM's TrajectoryTexts, ported: the same splitting, the same sizes, the same order.
//  PIN:  Pure: a tokenizer, a dataset and the Threads' present documents in, texts out; nothing
//        touches a node. A document is tokenized partition by partition and joined by the pack's
//        paragraph break, exactly as its Thread's index read it. Sentence units exist only when
//        re-joining them reproduces the partition's tokens.
//

import BraidCore
import Foundation

public enum BenchTextKind: String, Codable, Sendable, CaseIterable {
    case held, shuffled, collage, voice, voiceShuffled, told, source, generic
}

/// A fact's answer inside a text: its first token (a position in the text's tokens), its length, its words.
public struct BenchAnswer: Codable, Sendable, Equatable {
    public var start: Int
    public var count: Int
    public var text: String

    public init(start: Int, count: Int, text: String) {
        self.start = start
        self.count = count
        self.text = text
    }
}

public struct BenchText: Codable, Sendable, Equatable {
    public var kind: BenchTextKind
    public var label: String
    public var tokens: [Int32]
    /// The Thread the text belongs to: whose document it is, was cut from or is in the voice of, and
    /// the holder of a told or source text. Nil for generic prose.
    public var owner: String?
    /// Told and source: the Thread on the other side of the retelling.
    public var near: String?
    public var document: String?
    public var answers: [BenchAnswer]

    public init(kind: BenchTextKind, label: String, tokens: [Int32], owner: String? = nil, near: String? = nil, document: String? = nil, answers: [BenchAnswer] = []) {
        self.kind = kind
        self.label = label
        self.tokens = tokens
        self.owner = owner
        self.near = near
        self.document = document
        self.answers = answers
    }
}

public struct BenchTextSizes: Codable, Sendable, Equatable {
    /// Held, collage and voice texts per Thread.
    public var perNode = 20
    public var minTokens = 128
    public var maxTokens = 256
    /// Told and source texts may be shorter.
    public var minRetold = 96
    public var seed: UInt64 = 42

    public init() {}
}

/// A Thread as the text builder sees it: its name, the dataset node it was fed from, and the ids of
/// the documents present in its snapshot. Everything else of the node's corpus is unfed.
public struct BenchThread: Sendable, Equatable {
    public var name: String
    public var node: String
    public var present: Set<String>

    public init(name: String, node: String, present: Set<String>) {
        self.name = name
        self.node = node
        self.present = present
    }
}

/// What the builders read of a dataset: each node's corpus in feeding order and the links.
public struct BenchWorld: Sendable {
    public var name: String
    public var corpora: [String: GeneratedCorpus]
    public var crosslinks: [DatasetCrosslink]

    public init(name: String, corpora: [String: GeneratedCorpus], crosslinks: [DatasetCrosslink]) {
        self.name = name
        self.corpora = corpora
        self.crosslinks = crosslinks
    }

    public init(dataset: BraidDataset) {
        self.init(name: dataset.directory.lastPathComponent, corpora: dataset.corpora, crosslinks: dataset.crosslinks)
    }

    public func document(id: String) -> CorpusDocument? {
        for corpus in corpora.values { if let document = corpus.documents.first(where: { $0.id == id }) { return document } }
        return nil
    }
}

public enum BenchTexts {
    /// Prose about nothing any Thread holds (RaoLM's four passages, unchanged).
    public static let generic = [
        """
        The tide came in slowly that afternoon, filling the channels between the sandbanks one by one. Gulls stood in a line \
        along the breakwater, facing the wind, and a single rowing boat worked its way across the harbour mouth. By the time \
        the lamps were lit on the quay the water had reached the steps, and the boats that had leaned all day on their keels \
        were floating again, turning gently on their moorings as if they had only been waiting for permission to move.
        """,
        """
        Bread wants patience more than skill. The dough is mixed in the evening and left in a cool corner, covered with a \
        cloth, while the yeast does its quiet work through the night. In the morning it has doubled and smells faintly sour. \
        It is folded, shaped and left to rise once more, then baked in the hottest oven the kitchen can manage, until the \
        crust sings as it cools on the rack and the whole house knows that breakfast is nearly ready.
        """,
        """
        A bicycle teaches its rider about hills in a way no map can. A slope that looks gentle on paper becomes a long \
        argument with the legs, and a descent that seemed steep turns out to be the best part of the day. Riders learn to \
        read the road ahead, to shift before the climb rather than halfway up it, and to save a little breath for the last \
        bend, where the gradient always seems to steepen just when the top comes into view.
        """,
        """
        In winter the garden keeps its secrets underground. The beds look bare, the branches are grey, and frost draws white \
        lines along every stem. Yet the bulbs planted in autumn are already sending roots into the cold soil, and the buds on \
        the apple tree are sealed tight against the weather, waiting. A patient gardener walks the paths on clear mornings, \
        notes what the wind has broken, and makes small plans for the first warm week of spring.
        """,
    ]

    /// A partition's sentences: split at a space after . ? ! or a closing quote, before a capital or a quote.
    public static func sentences(_ text: String) -> [String] {
        let characters = Array(text)
        guard characters.count > 2 else { return text.isEmpty ? [] : [text] }
        var units: [String] = []
        var start = 0
        for i in 1..<(characters.count - 1) where characters[i] == " " {
            guard ".?!\"".contains(characters[i - 1]), characters[i + 1].isUppercase || characters[i + 1] == "\"" else { continue }
            units.append(String(characters[start..<i]))
            start = i + 1
        }
        units.append(String(characters[start...]))
        return units.filter { !$0.isEmpty }
    }

    /// A document's tokens as its Thread tokenized it (each partition on its own, joined by the pack's
    /// paragraph break), and its sentences' tokens, a break riding on the sentence before it; no
    /// sentences when re-joining them would not give those tokens.
    public static func split(_ document: CorpusDocument, tokenizer: any Tokenizing, paragraphBreak: [Int32]) -> (tokens: [Int32], units: [[Int32]]?) {
        var tokens: [Int32] = []
        var units: [[Int32]] = []
        var exact = true
        for (n, partition) in document.partitions.sorted(by: { $0.index < $1.index }).enumerated() {
            if n > 0 {
                tokens += paragraphBreak
                if exact, !units.isEmpty { units[units.count - 1] += paragraphBreak }
            }
            let own = tokenizer.encode(partition.text)
            tokens += own
            let pieces = sentences(partition.text).enumerated().map { i, piece in tokenizer.encode(i == 0 ? piece : " " + piece) }
            if pieces.flatMap({ $0 }) == own { units += pieces } else { exact = false }
        }
        return (tokens, exact ? units : nil)
    }

    /// The sentences in an order where none is followed by the sentence that followed it before.
    public static func shuffled(_ units: [[Int32]], rng: inout SplitMix64) -> [[Int32]]? {
        guard units.count >= 3 else { return nil }
        for _ in 0..<200 {
            let order = Array(units.indices).shuffled(using: &rng)
            if zip(order, order.dropFirst()).allSatisfy({ $1 != $0 + 1 }) { return order.map { units[$0] } }
        }
        return nil
    }

    /// Sentence k of the k-th document (cycling), at least `minTokens` and at most `maxTokens`; nil when it stays short.
    public static func collage(_ sources: [[[Int32]]], from c: Int, minTokens: Int, maxTokens: Int) -> [Int32]? {
        guard sources.count >= 2 else { return nil }
        var tokens: [Int32] = []
        var k = 0
        while tokens.count < minTokens, k < sources.count {
            let units = sources[(c + k) % sources.count]
            let unit = units[k % units.count]
            if tokens.count + unit.count > maxTokens { break }
            tokens += unit
            k += 1
        }
        return tokens.count >= minTokens ? tokens : nil
    }

    /// Where each located fact's answer sits in the document's tokens (as `split` lays them out).
    public static func answers(_ document: CorpusDocument, facts ids: Set<String>, tokenizer: any Tokenizing, byteOffsets: ([Int32]) -> [Int],
                               paragraphBreak: [Int32]) -> [BenchAnswer] {
        guard !ids.isEmpty else { return [] }
        let snapshot = CorpusSnapshot(
            documents: [SnapshotDocument(id: document.id, name: document.name, ownerID: "bench", groupID: "bench", groupLabel: "bench", createdAt: 0, mediaType: "text",
                                         partitions: document.partitions.map { SnapshotPartition(index: $0.index, text: $0.text, url: $0.url) })],
            slug: nil, source: "bench", threadID: nil, owner: "bench", group: "bench", documentIDPrefix: "")
        let corpus = TokenizedCorpus(snapshot: snapshot, tokenizer: tokenizer, paragraphBreak: paragraphBreak, threadID: nil)
        var starts: [Int: Int] = [:]
        var total = 0
        for (n, partition) in corpus.partitions.enumerated() {
            if n > 0 { total += paragraphBreak.count }
            starts[partition.row] = total
            total += partition.tokens.count
        }
        return FactLocator.locate(document.facts.filter { ids.contains($0.id) }, corpus: corpus, byteOffsets: byteOffsets).located
            .map { BenchAnswer(start: (starts[$0.row] ?? 0) + $0.answerToken, count: $0.answerLength, text: $0.fact.answer) }
            .sorted { $0.start < $1.start }
    }

    /// The documents of a node that no non-homonym link touches: held by one Thread alone.
    public static func exclusive(_ documents: [CorpusDocument], crosslinks: [DatasetCrosslink]) -> [CorpusDocument] {
        let crossed = Set(crosslinks.filter { $0.kind != .homonym }.flatMap { [$0.source.documentID, $0.target.documentID] })
        return documents.filter { !crossed.contains($0.id) }
    }

    public static func build(world: BenchWorld, threads: [BenchThread], tokenizer: any Tokenizing, byteOffsets: ([Int32]) -> [Int], paragraphBreak: [Int32],
                             sizes: BenchTextSizes = BenchTextSizes()) -> [BenchText] {
        var rng = SplitMix64(seed: sizes.seed)
        var cache: [String: (tokens: [Int32], units: [[Int32]]?)] = [:]
        func pieces(_ document: CorpusDocument) -> (tokens: [Int32], units: [[Int32]]?) {
            if let cached = cache[document.id] { return cached }
            let made = split(document, tokenizer: tokenizer, paragraphBreak: paragraphBreak)
            cache[document.id] = made
            return made
        }
        // Links between nodes the braid holds; the first Thread fed from a node stands for it.
        var threadByNode: [String: BenchThread] = [:]
        for thread in threads where threadByNode[thread.node] == nil { threadByNode[thread.node] = thread }
        let links = world.crosslinks.filter { threadByNode[$0.source.node] != nil && threadByNode[$0.target.node] != nil }
        let whole = sizes.minTokens...sizes.maxTokens
        var texts: [BenchText] = []
        for thread in threads {
            let own = exclusive(world.corpora[thread.node]?.documents ?? [], crosslinks: links)
            let held = own.filter { thread.present.contains($0.id) }
            for document in held.filter({ whole.contains(pieces($0).tokens.count) }).prefix(sizes.perNode) {
                texts.append(BenchText(kind: .held, label: "\(thread.name) · \(document.name)", tokens: pieces(document).tokens, owner: thread.name, document: document.id))
                if let units = pieces(document).units, let order = shuffled(units, rng: &rng) {
                    texts.append(BenchText(kind: .shuffled, label: "\(thread.name) · \(document.name) (shuffled)", tokens: order.flatMap { $0 }, owner: thread.name,
                                           document: document.id))
                }
            }
            // Sentence k of the k-th held document: a Thread's own sentences, following none of them.
            let sources = held.compactMap { pieces($0).units }
            if sources.count >= 2 {
                for c in 0..<min(sizes.perNode, sources.count) {
                    if let tokens = collage(sources, from: c, minTokens: sizes.minTokens, maxTokens: sizes.maxTokens) {
                        texts.append(BenchText(kind: .collage, label: "\(thread.name) · collage \(c + 1)", tokens: tokens, owner: thread.name))
                    }
                }
            }
            let unfed = own.filter { !thread.present.contains($0.id) && whole.contains(pieces($0).tokens.count) }
            for document in unfed.prefix(sizes.perNode) {
                texts.append(BenchText(kind: .voice, label: "\(thread.name) · \(document.name) (unfed)", tokens: pieces(document).tokens, owner: thread.name,
                                       document: document.id))
                if let units = pieces(document).units, let order = shuffled(units, rng: &rng) {
                    texts.append(BenchText(kind: .voiceShuffled, label: "\(thread.name) · \(document.name) (unfed, shuffled)", tokens: order.flatMap { $0 },
                                           owner: thread.name, document: document.id))
                }
            }
        }
        // Both sides of every retelling whose two documents are present.
        let retold = sizes.minRetold...sizes.maxTokens
        var sources = Set<String>()
        for link in links where link.kind != .homonym {
            guard let teller = threadByNode[link.target.node], let origin = threadByNode[link.source.node],
                  origin.present.contains(link.source.documentID), teller.present.contains(link.target.documentID),
                  let source = world.document(id: link.source.documentID), let target = world.document(id: link.target.documentID)
            else { continue }
            let agreeing = link.facts.filter(\.agrees)
            if retold.contains(pieces(target).tokens.count) {
                texts.append(BenchText(
                    kind: .told, label: "\(teller.name) ≈ \(origin.name) · \(link.subject) (\(link.kind.rawValue))", tokens: pieces(target).tokens,
                    owner: teller.name, near: origin.name, document: target.id,
                    answers: answers(target, facts: Set(agreeing.map(\.targetFact)), tokenizer: tokenizer, byteOffsets: byteOffsets, paragraphBreak: paragraphBreak)))
            }
            if !sources.contains(source.id), retold.contains(pieces(source).tokens.count) {
                sources.insert(source.id)
                texts.append(BenchText(
                    kind: .source, label: "\(origin.name) → \(teller.name) · \(link.subject)", tokens: pieces(source).tokens,
                    owner: origin.name, near: teller.name, document: source.id,
                    answers: answers(source, facts: Set(agreeing.map(\.sourceFact)), tokenizer: tokenizer, byteOffsets: byteOffsets, paragraphBreak: paragraphBreak)))
            }
        }
        for (i, passage) in generic.enumerated() {
            texts.append(BenchText(kind: .generic, label: "generic \(i + 1)", tokens: tokenizer.encode(passage)))
        }
        return texts
    }

    /// `kind n · kind n …` for a progress line.
    public static func census(_ texts: [BenchText]) -> String {
        BenchTextKind.allCases.map { kind in "\(kind.rawValue) \(texts.filter { $0.kind == kind }.count)" }.joined(separator: " · ")
    }
}

/// The prompts the gaming and lift benches ask: a Thread's facts from its own exclusive documents,
/// newest first, one from each document in turn (RaoLM's `BraidExample` order).
public enum BenchPrompts {
    /// Sentences about nothing the datasets hold (RaoLM's gate bench prompts, unchanged).
    public static let generic = [
        "How should we understand our lives",
        "How should we understand our lives as travellers",
        "What is the best way to learn a new language",
        "The weather tomorrow is going to be",
        "In the future, computers will be able to",
        "My favourite thing about the weekend is",
        "To make a good cup of tea you should",
        "The most important lesson I ever learned was",
    ]

    /// General English no Thread holds and the base model knows (RaoLM's commons prompts, unchanged).
    public static let commons = [
        "The capital of France is", "Water freezes at a temperature of", "The largest planet in our solar system is",
        "Shakespeare wrote the play", "The chemical symbol for gold is", "The first man to walk on the moon was",
        "Photosynthesis is the process by which plants", "The Pacific Ocean is the largest", "In mathematics, the square root of sixteen is",
        "Honey is made by", "The heart pumps blood through the", "Mount Everest is the highest mountain in",
        "The Mona Lisa was painted by", "Light travels faster than", "The opposite of hot is", "Rain falls from clouds when",
        "A triangle has three sides, and a square has", "The sun rises in the", "A group of wolves is called a",
        "The Great Wall of China was built to",
    ]

    /// One fact prompt: the partition's tokens from the context sentence to the answer, and the answer.
    public struct FactPrompt: Sendable, Equatable {
        public var thread: String
        public var fact: Fact
        public var tokens: [Int32]
        public var answerTokens: Int
        public var documentID: String
        public var partitionIndex: Int
    }

    /// A Thread's facts located in its own exclusive present documents, newest documents first, one
    /// fact from each in turn (within a document by fact id), `perNode` of them.
    public static func facts(thread: BenchThread, world: BenchWorld, tokenizer: any Tokenizing, byteOffsets: ([Int32]) -> [Int], paragraphBreak: [Int32],
                             perNode: Int) -> [FactPrompt] {
        let own = BenchTexts.exclusive(world.corpora[thread.node]?.documents ?? [], crosslinks: world.crosslinks).filter { thread.present.contains($0.id) }
        guard !own.isEmpty else { return [] }
        let snapshot = CorpusSnapshot(
            documents: own.map { document in
                SnapshotDocument(id: document.id, name: document.name, ownerID: "bench", groupID: "bench", groupLabel: "bench", createdAt: 0, mediaType: "text",
                                 partitions: document.partitions.map { SnapshotPartition(index: $0.index, text: $0.text, url: $0.url) })
            },
            slug: nil, source: "bench", threadID: nil, owner: "bench", group: "bench", documentIDPrefix: "")
        let corpus = TokenizedCorpus(snapshot: snapshot, tokenizer: tokenizer, paragraphBreak: paragraphBreak, threadID: nil)
        let located = FactLocator.locate(own.flatMap(\.facts), corpus: corpus, byteOffsets: byteOffsets).located
        let order = Dictionary(own.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
        var byDocument = Dictionary(grouping: located, by: \.fact.documentID)
            .sorted { (order[$0.key] ?? 0) > (order[$1.key] ?? 0) }
            .map { $0.value.sorted { $0.fact.id < $1.fact.id } }
        var ranked: [LocatedFact] = []
        while byDocument.contains(where: { !$0.isEmpty }) {
            for i in byDocument.indices where !byDocument[i].isEmpty { ranked.append(byDocument[i].removeFirst()) }
        }
        return ranked.prefix(max(0, perNode)).map { fact in
            let partition = corpus.partitions[fact.row]
            return FactPrompt(thread: thread.name, fact: fact.fact, tokens: Array(partition.tokens[fact.contextToken..<fact.answerToken]),
                              answerTokens: fact.answerLength, documentID: partition.ref.documentID, partitionIndex: partition.ref.partitionIndex)
        }
    }

    /// The same templates about entities that exist nowhere: each ranked fact's negative prompt, distinct.
    public static func unknown(_ facts: [FactPrompt], count: Int) -> [String] {
        var seen = Set<String>()
        var prompts: [String] = []
        for fact in facts where !fact.fact.negativePrompt.isEmpty && !seen.contains(fact.fact.negativePrompt) && prompts.count < count {
            seen.insert(fact.fact.negativePrompt)
            prompts.append(fact.fact.negativePrompt)
        }
        return prompts
    }

    /// A fact from each list in turn (RaoLM's interleaving), `total` at most when given.
    public static func interleave<T>(_ lists: [[T]], total: Int? = nil) -> [T] {
        var result: [T] = []
        var round = 0
        while lists.contains(where: { round < $0.count }) {
            for list in lists where round < list.count {
                if let total, result.count >= total { return result }
                result.append(list[round])
            }
            round += 1
        }
        return result
    }
}
