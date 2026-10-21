//
//  CorpusModels.swift
//  BraidCore
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: A corpus as a dataset node stores it and as Braid deposits it into a lane: documents,
//        their partitions (the citation unit), and the facts each one states.
//  PIN:  A partition's address is (documentID, partitionIndex), never Thread's partition id
//        (which hashes the embedding). Kinds are plain strings: Braid reads RaoLM's datasets, it
//        does not generate them, so it carries no generator vocabulary.
//

import Foundation

/// One fact a document states, located precisely inside its partition.
///
/// Offsets are UTF-8 byte offsets into the partition text. `answer` begins with the space that
/// separates it from `prompt`, so the prompt/answer boundary is also a token boundary under a
/// byte-level BPE.
public struct Fact: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: String
    public var documentID: String
    public var partitionIndex: Int
    /// The entity the fact is about, as it appears in the text.
    public var subject: String
    public var prompt: String
    public var answer: String
    public var sentence: String
    public var sentenceStart: Int
    /// Start of the sentence before this one in the same partition (or `sentenceStart`).
    public var contextStart: Int
    /// Offset of the space before the answer value.
    public var answerStart: Int
    public var answerEnd: Int
    /// Prompts for the same fact that do not occur anywhere in the corpus.
    public var paraphrases: [String]
    /// The same template about an entity that exists nowhere in the corpus.
    public var negativePrompt: String
    /// Natural questions about the fact, each with the corpus-style stem it should rewrite to.
    /// Nil in datasets generated before questions.
    public var questions: [FactQuestion]?
    public var negativeQuestions: [FactQuestion]?

    public init(id: String, kind: String, documentID: String, partitionIndex: Int, subject: String, prompt: String, answer: String,
                sentence: String, sentenceStart: Int, contextStart: Int, answerStart: Int, answerEnd: Int, paraphrases: [String] = [],
                negativePrompt: String = "", questions: [FactQuestion]? = nil, negativeQuestions: [FactQuestion]? = nil) {
        self.id = id
        self.kind = kind
        self.documentID = documentID
        self.partitionIndex = partitionIndex
        self.subject = subject
        self.prompt = prompt
        self.answer = answer
        self.sentence = sentence
        self.sentenceStart = sentenceStart
        self.contextStart = contextStart
        self.answerStart = answerStart
        self.answerEnd = answerEnd
        self.paraphrases = paraphrases
        self.negativePrompt = negativePrompt
        self.questions = questions
        self.negativeQuestions = negativeQuestions
    }
}

/// A question about a fact and the stem the commons' adapter should rewrite it to.
public struct FactQuestion: Codable, Sendable, Equatable {
    public var text: String
    public var stem: String

    public init(text: String, stem: String) {
        self.text = text
        self.stem = stem
    }
}

public struct CorpusPartition: Codable, Sendable, Equatable {
    public var index: Int
    public var text: String
    public var textSHA256: String
    /// The address the corpus supplies to a Thread for this partition.
    public var url: String

    public init(index: Int, text: String, textSHA256: String? = nil, url: String) {
        self.index = index
        self.text = text
        self.textSHA256 = textSHA256 ?? ContentHash.sha256Hex(text)
        self.url = url
    }
}

public struct CorpusDocument: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var kind: String
    public var subject: String
    public var partitions: [CorpusPartition]
    public var facts: [Fact]
    /// SHA-256 of the partitions joined by a blank line (the document's canonical text).
    public var textSHA256: String

    public init(id: String, name: String, kind: String, subject: String, partitions: [CorpusPartition], facts: [Fact], textSHA256: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.subject = subject
        self.partitions = partitions
        self.facts = facts
        self.textSHA256 = textSHA256 ?? ContentHash.sha256Hex(partitions.map(\.text).joined(separator: "\n\n"))
    }

    public var text: String { partitions.map(\.text).joined(separator: "\n\n") }
}

public struct CorpusManifest: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var slug: String
    public var generator: String
    public var generatorVersion: Int
    public var seed: UInt64
    public var documentCount: Int
    public var partitionCount: Int
    public var factCount: Int
    public var chunkMaxChars: Int
    public var chunkMinChars: Int
    /// In generation order, which is the feeding order.
    public var documentIDs: [String]
    public var corpusHash: String
}

public struct GeneratedCorpus: Sendable, Equatable {
    public var manifest: CorpusManifest
    /// In feeding order.
    public var documents: [CorpusDocument]

    public init(manifest: CorpusManifest, documents: [CorpusDocument]) {
        self.manifest = manifest
        self.documents = documents
    }

    public var facts: [Fact] { documents.flatMap(\.facts) }

    public var corpusEntries: [ContentHash.CorpusEntry] {
        documents.flatMap { document in
            document.partitions.map { ContentHash.CorpusEntry(documentID: document.id, partitionIndex: $0.index, textSHA256: $0.textSHA256) }
        }
    }

    /// The corpus hash recomputed from the documents' texts (not the stored SHAs).
    public var recomputedCorpusHash: String {
        ContentHash.corpusHash(documents.flatMap { document in
            document.partitions.map { ContentHash.CorpusEntry(documentID: document.id, partitionIndex: $0.index, textSHA256: ContentHash.sha256Hex($0.text)) }
        })
    }
}

/// Where a cited token lives: the Thread, the document, the partition inside it, and the token
/// offset inside that partition's own tokenization.
public struct SourceAddress: Codable, Sendable, Hashable {
    public var threadID: String?
    public var documentID: String
    public var partitionIndex: Int
    public var tokenOffset: Int
    public var partitionURL: String?

    public init(threadID: String? = nil, documentID: String, partitionIndex: Int, tokenOffset: Int, partitionURL: String? = nil) {
        self.threadID = threadID
        self.documentID = documentID
        self.partitionIndex = partitionIndex
        self.tokenOffset = tokenOffset
        self.partitionURL = partitionURL
    }
}

/// A position in an index's partition table: the row and the token offset inside it.
public struct TokenPosition: Codable, Sendable, Hashable {
    public var row: Int
    public var offset: Int

    public init(row: Int, offset: Int) {
        self.row = row
        self.offset = offset
    }
}
