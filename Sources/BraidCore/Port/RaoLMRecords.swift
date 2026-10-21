//
//  RaoLMRecords.swift
//  BraidCore
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: RaoLM's records as its trajectory bench dumped them, decoded as written: a scored text's
//        CitedGeneration (RaoLM/Sources/RaoLMCore/Citation/CitationModels.swift and Braid/
//        BraidModels.swift), the dump's index.json, and RaoLM's trajectory report. Only what the
//        import, the port validation and phase A read is declared; everything else in a record
//        (citations, spans, summary, a trace's span index, a prompt's source and question) is
//        skipped by the decoder and listed in the import report.
//  PIN:  Field names are RaoLM's. Optional wherever RaoLM's own type is optional or a later RaoLM
//        added the field, so a record from either decodes. Entries and rows in a record are global
//        (a strand's entryOffset and rowOffset added); a trajectory's entry and position are the
//        node's own.
//

import Foundation

public struct RaoLMPosition: Codable, Sendable, Equatable {
    public var row: Int
    public var offset: Int
}

public struct RaoLMManifest: Codable, Sendable, Equatable {
    public var runID: String
    public var epoch: Int
    public var checkpointSHA256: String
    public var indexSHA256: String
    public var corpusHash: String
    public var tokenizerSHA256: String
    public var ledgerSHA256: String?
    public var threadID: String?
}

public struct RaoLMPartition: Codable, Sendable, Equatable {
    public var row: Int
    public var documentID: String
    public var documentName: String
    public var partitionIndex: Int
    public var partitionURL: String?
    public var threadPartitionID: String?
    public var textSHA256: String
    public var tokenCount: Int
    public var memorisedAtEpoch: Int?
    public var threadID: String?
    public var createdAt: Int64?

    /// Braid's partition row (RaoLM's thread partition id has no Braid field).
    public var partitionRef: PartitionRef {
        PartitionRef(row: row, documentID: documentID, documentName: documentName, partitionIndex: partitionIndex, partitionURL: partitionURL,
                     textSHA256: textSHA256, tokenCount: tokenCount, memorisedAtEpoch: memorisedAtEpoch, threadID: threadID, createdAt: createdAt)
    }
}

public struct RaoLMPrompt: Codable, Sendable, Equatable {
    public var text: String
    public var tokens: [Int]
    public var tokenTexts: [String]?
}

public struct RaoLMParameters: Codable, Sendable, Equatable {
    public var lambda: Float
    public var tau: Float
    public var k: Int
    public var rankThreshold: Int
    public var minSpanLength: Int
    public var temperature: Float
    public var topK: Int
    public var seed: UInt64
    public var maxTokens: Int
    public var tapLayer: Int
    public var alpha: Float
}

/// One retrieved corpus position for one token, as RaoLM pooled it across Threads.
public struct RaoLMNeighbour: Codable, Sendable, Equatable {
    /// 1-based rank in the pool (by pooled weight).
    public var rank: Int
    /// Global entry: the strand's entryOffset plus its own entry.
    public var entry: Int
    public var score: Float
    /// The pooled weight: the strand's retrieval weight times softmax(score/τ) within the strand.
    public var weight: Float
    public var value: Int
    public var matches: Bool
    /// Global rows.
    public var key: RaoLMPosition
    public var cited: RaoLMPosition
    public var sourceLoss: Float
    public var sourceEntropy: Float
}

/// A Thread's retrieval trajectory at the position that predicts the token (node-local entry and row).
public struct RaoLMTrajectory: Codable, Sendable, Equatable {
    public var length: Int
    public var trace: Float
    public var entry: Int?
    public var at: RaoLMPosition?
    public var next: Int?
    /// Manner's readings: Braid deleted manner.
    public var phase: Float?
    public var fit: Float?
    public var arc: Float?
    public var manner: Float?
}

/// What one strand supplied to one token (RaoLM's StrandShare).
public struct RaoLMStrandShare: Codable, Sendable, Equatable {
    public var strand: String
    public var threadID: String?
    /// The gate before renormalising over the open strands: the memory lifted by agreement (and, in
    /// the trajectory arms, times its trace term).
    public var gate: Float
    public var open: Bool
    public var bestScore: Float?
    public var lmProb: Float?
    public var lmEntropy: Float?
    /// w′_t·p_knn,t(y): the strand's renormalised weight times its own retrieval mass on the token.
    public var knn: Float
    public var share: Float
    public var memory: Float?
    public var backs: Float?
    /// p_t(y) = λ_t·p_knn,t(y) + (1−λ_t)·p_lm,t(y); nil when the strand was not asked.
    public var alone: Float?
    public var trajectory: RaoLMTrajectory?
    public var lift: Float?
    public var thought: Float?
    public var credit: Float?
}

public struct RaoLMCandidate: Codable, Sendable, Equatable {
    public var token: Int
    public var text: String
    public var prob: Float
    public var parts: [Float]
}

/// Everything RaoLM recorded about one token (RaoLM's TokenTrace; citations and span index skipped).
public struct RaoLMTrace: Codable, Sendable, Equatable {
    public var index: Int
    public var token: Int
    public var text: String
    public var isPrompt: Bool
    public var lmEntropy: Float
    public var knnEntropy: Float
    public var mixedEntropy: Float
    public var sourceEntropy: Float
    public var lmProb: Float
    public var agreement: Float
    public var mixedProb: Float
    public var lambda: Float
    public var neighbours: [RaoLMNeighbour]
    public var uncited: Bool?
    public var confidence: Float?
    public var strands: [RaoLMStrandShare]?
    public var threadEntropy: Float?
    public var candidates: [RaoLMCandidate]?
    public var role: String?
    public var bits: Float?
    public var followed: String?
}

/// RaoLM's braided gate settings.
public struct RaoLMGate: Codable, Sendable, Equatable {
    public var evidenceFloor: Float
    public var evidenceCeiling: Float
    public var share: String
    public var shareRate: Float
    public var credibility: Bool
    public var credibilityRate: Float
    public var agreement: Bool
    public var generatedEvidence: Bool
    public var trajectory: String?
    public var trajectoryBeta: Float?
    public var ask: String?
    public var askFloor: Float?
    public var thoughtAgreement: Bool?
    public var commonsPrior: Float?
}

public struct RaoLMStrandRef: Codable, Sendable, Equatable {
    public var name: String
    public var label: String
    public var threadID: String?
    public var version: Int
    public var manifest: RaoLMManifest
    public var rowOffset: Int
    public var rowCount: Int
    public var entryOffset: Int
    public var commons: Bool?
    public var address: String?
    public var ownerKey: String?

    public var isCommons: Bool { commons == true }
}

public struct RaoLMBraid: Codable, Sendable, Equatable {
    public var vocabularySHA256: String
    public var gateFloor: Float
    public var strands: [RaoLMStrandRef]
    public var gating: String?
    public var gate: RaoLMGate?
    public var packSHA256: String?
}

/// One scored text: RaoLM's CitedGeneration.
public struct RaoLMGeneration: Codable, Sendable, Equatable {
    public var version: Int
    public var generationID: String
    public var manifest: RaoLMManifest
    public var createdAt: Date
    public var prompt: RaoLMPrompt
    public var params: RaoLMParameters
    public var tokens: [Int]
    public var text: String
    public var stoppedOnEOS: Bool
    public var partitions: [RaoLMPartition]
    public var traces: [RaoLMTrace]
    public var braid: RaoLMBraid?

    public static func load(from url: URL) throws -> RaoLMGeneration { try JSONCoding.read(RaoLMGeneration.self, from: url) }
}

// MARK: - The dump and RaoLM's report

public struct RaoLMAnswer: Codable, Sendable, Equatable {
    public var start: Int
    public var count: Int
    public var text: String
}

/// One scored text in the dump's index.json.
public struct RaoLMDumpText: Codable, Sendable, Equatable {
    public var file: String
    public var index: Int
    public var kind: String
    public var label: String
    public var owner: String?
    public var near: String?
    public var document: String?
    public var tokens: Int
    public var answers: [RaoLMAnswer]

    /// Text positions RaoLM counts as answer tokens: each answer's tokens from position 1 (position
    /// 0 has no trace).
    public var answerPositions: [Int] {
        var positions: [Int] = []
        var seen = Set<Int>()
        for answer in answers {
            for p in answer.start..<(answer.start + answer.count) where p >= 1 && seen.insert(p).inserted { positions.append(p) }
        }
        return positions
    }
}

/// The dump's index.json: the texts, the node versions scored, and where each gate arm's records went.
public struct RaoLMDumpIndex: Codable, Sendable, Equatable {
    public var createdAt: Date
    public var dataRoot: String
    public var nodes: [String: Int]
    /// Arm name ("both β4") → its directory under the dump ("arms/both-beta4").
    public var arms: [String: String]
    public var texts: [RaoLMDumpText]

    public static func load(from dump: URL) throws -> RaoLMDumpIndex { try JSONCoding.read(RaoLMDumpIndex.self, from: dump.appendingPathComponent("index.json")) }
}

/// RaoLM's trajectory report (trajectory.json): per text each strand's reading, the arms, the rules.
public struct RaoLMTrajectoryReport: Codable, Sendable {
    public struct Reading: Codable, Sendable, Equatable {
        public var strand: String
        public var trace: Float
        public var longest: Int
        public var wireLongest: Int
        public var manner: Float?
        public var arc: Float?
        public var fit: Float
        public var meanFit: Float
        public var meanBest: Float
        public var logLikelihood: Float
    }

    public struct Text: Codable, Sendable, Equatable {
        public var kind: String
        public var label: String
        public var owner: String?
        public var near: String?
        public var tokens: Int
        public var readings: [Reading]
    }

    public struct Arm: Codable, Sendable, Equatable {
        public var arm: String
        public var holderShare: Float?
        public var answerTokens: Int
        public var exact: Int
        public var prompts: Int
        public var largestGate: Float?
        public var allAsked: Float?
        public var notAsked: Float?
    }

    public struct Rule: Codable, Sendable, Equatable {
        public var rule: String
        public var passed: Bool
        public var detail: String
    }

    public struct Evaluation: Codable, Sendable {
        public var rules: [Rule]
        public var qualifies: [String]
        public var winner: String?
        public var reported: [String: Float]
        public var summary: String
    }

    public struct Constants: Codable, Sendable, Equatable {
        public var phrase: Int
        public var arc: Int
        public var bridge: Int
        public var heads: Int
        public var seeds: Int
    }

    public var createdAt: Date
    public var nodes: [String: Int]
    public var documents: [String: Int]
    public var memorised: [String: Float]
    public var rule: Constants
    public var texts: [Text]
    public var arms: [Arm]
    public var evaluation: Evaluation

    public static func load(from url: URL) throws -> RaoLMTrajectoryReport { try JSONCoding.read(RaoLMTrajectoryReport.self, from: url) }

    /// RaoLM's trace rule as Braid's.
    public var traceRule: TraceRule {
        var rule = TraceRule()
        rule.phrase = self.rule.phrase
        rule.arc = self.rule.arc
        rule.bridge = self.rule.bridge
        rule.heads = self.rule.heads
        rule.seeds = self.rule.seeds
        return rule
    }
}
