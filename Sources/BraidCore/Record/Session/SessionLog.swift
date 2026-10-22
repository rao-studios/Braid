//
//  SessionLog.swift
//  BraidCore
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The session log: one JSON object per line. `header` once; per generation `gen`, the
//        `tok` lines (one per position, see Records.swift), `end`; `attach` and `detach` where a
//        strand joined or left. The artifact `braid verify` replays, the trajectory module reads
//        offline, and the benches run against.
//  PIN:  Sorted keys, compact lines, schema versioned. The `end` line carries the SHA-256 of every
//        line of its generation as written, so a log that was edited is caught before any number
//        in it is trusted.
//

import Foundation

public struct SessionThread: Codable, Sendable, Equatable {
    public var name: String
    public var label: String
    public var commons: Bool
    public var threadID: String?
    public var lane: String?
    public var indexSHA256: String?
    public var checkpointSHA256: String?
    public var versionSHA256: String?
    public var corpusHash: String?
    public var lambda: Float
    public var tau: Float
    /// Where this strand's rows begin in the braid's global partition table, and how many it has.
    public var rowOffset: Int
    public var rowCount: Int

    public init(descriptor d: NodeDescriptor, lambda: Float, rowOffset: Int, rowCount: Int) {
        name = d.name
        label = d.label
        commons = d.isCommons
        threadID = d.threadID
        lane = d.lane
        indexSHA256 = d.indexSHA256
        checkpointSHA256 = d.checkpointsSHA256
        versionSHA256 = d.versionSHA256
        corpusHash = d.corpusHash
        self.lambda = lambda
        tau = d.tau
        self.rowOffset = rowOffset
        self.rowCount = rowCount
    }
}

public struct PackIdentity: Codable, Sendable, Equatable {
    public var sha256: String?
    public var name: String?
    public var vocabularySHA256: String
    public var tokenizerSHA256: String
    public var hiddenSize: Int
    public var vocabulary: Int
    /// The seam of the tail every strand runs (the commons' blocks ≥ cut, embedding and final norm); nil in logs written before it was recorded.
    public var seamSHA256: String?

    public init(sha256: String?, name: String?, vocabularySHA256: String, tokenizerSHA256: String, hiddenSize: Int, vocabulary: Int, seamSHA256: String? = nil) {
        self.sha256 = sha256
        self.name = name
        self.vocabularySHA256 = vocabularySHA256
        self.tokenizerSHA256 = tokenizerSHA256
        self.hiddenSize = hiddenSize
        self.vocabulary = vocabulary
        self.seamSHA256 = seamSHA256
    }
}

public struct SessionHeader: Codable, Sendable, Equatable {
    public var kind = "header"
    public var schema: Int
    public var sessionID: String
    public var createdAt: Date
    /// "braid", or "raolm" for a log imported from RaoLM generations.
    public var source: String
    public var pack: PackIdentity
    public var gate: GateSettings
    public var gateFingerprint: String
    public var trace: TraceRule
    public var module: ModuleSettings?
    public var hitsLogged: Int
    public var threads: [SessionThread]

    public init(sessionID: String, createdAt: Date = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)), source: String = "braid",
                pack: PackIdentity, gate: GateSettings, trace: TraceRule, module: ModuleSettings?, hitsLogged: Int, threads: [SessionThread]) {
        schema = BraidVersion.sessionSchema
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.source = source
        self.pack = pack
        self.gate = gate
        gateFingerprint = gate.fingerprint
        self.trace = trace
        self.module = module
        self.hitsLogged = hitsLogged
        self.threads = threads
    }
}

public struct QuestionRewrite: Codable, Sendable, Equatable {
    public var question: String
    public var stem: String
    /// "commons" (the commons model, prompted) or "none" (the question itself).
    public var rewriter: String
    public var seconds: Double

    public init(question: String, stem: String, rewriter: String, seconds: Double) {
        self.question = question
        self.stem = stem
        self.rewriter = rewriter
        self.seconds = seconds
    }
}

public struct GenerationPrompt: Codable, Sendable, Equatable {
    public var text: String
    public var tokens: [Int32]
    public var question: QuestionRewrite?

    public init(text: String, tokens: [Int32], question: QuestionRewrite? = nil) {
        self.text = text
        self.tokens = tokens
        self.question = question
    }
}

public struct ContextRef: Codable, Sendable, Equatable {
    public var strand: Int
    public var tokens: [Int32]
    public var score: Float
    public var documentID: String
    public var row: Int
    public var offset: Int

    public init(strand: Int, tokens: [Int32], score: Float, documentID: String, row: Int, offset: Int) {
        self.strand = strand
        self.tokens = tokens
        self.score = score
        self.documentID = documentID
        self.row = row
        self.offset = offset
    }

    enum CodingKeys: String, CodingKey { case strand = "t", tokens, score, documentID, row, offset }
}

public struct GenerationParameters: Codable, Sendable, Equatable {
    public var lambda: Float = 0.5
    public var tau: Float = 0.05
    public var k: Int = 16
    public var temperature: Float = 0
    public var topK: Int = 0
    public var seed: UInt64 = 42
    public var maxTokens: Int = 24
    public var stopAtSentenceEnd = false

    public init() {}
}

public struct GenerationLine: Codable, Sendable, Equatable {
    public var kind = "gen"
    public var generationID: String
    public var prompt: GenerationPrompt
    public var context: [ContextRef]?
    public var params: GenerationParameters
    /// The strands in this generation's order (the header's, as changed by attach/detach lines so far).
    public var strands: [String]

    public init(generationID: String, prompt: GenerationPrompt, context: [ContextRef]?, params: GenerationParameters, strands: [String]) {
        self.generationID = generationID
        self.prompt = prompt
        self.context = context
        self.params = params
        self.strands = strands
    }
}

public struct EndLine: Codable, Sendable, Equatable {
    public var kind = "end"
    public var generationID: String
    public var tokens: Int
    public var generated: Int
    public var stoppedOn: StopReason?
    public var text: String
    /// Every global row any logged hit or chain touched.
    public var partitions: [PartitionRef]
    /// SHA-256 of every line of this generation (gen … last tok), each with its newline.
    public var bodySHA256: String
}

public struct MembershipLine: Codable, Sendable, Equatable {
    /// "attach" or "detach".
    public var kind: String
    public var strand: Int
    public var thread: SessionThread
    public var position: Int
    public var caughtUp: Int
    public var seconds: Double
    public var memory: [Float]
    /// For an attach: the newcomer's hits at every prefix position (what seeded its chains), so the
    /// trace replays exactly from the log.
    public var catchUpHits: [[Hit]]?

    public init(kind: String, strand: Int, thread: SessionThread, position: Int, caughtUp: Int, seconds: Double, memory: [Float], catchUpHits: [[Hit]]? = nil) {
        self.kind = kind
        self.strand = strand
        self.thread = thread
        self.position = position
        self.caughtUp = caughtUp
        self.seconds = seconds
        self.memory = memory
        self.catchUpHits = catchUpHits
    }

    enum CodingKeys: String, CodingKey { case kind, strand = "t", thread, position, caughtUp, seconds, memory, catchUpHits = "hits" }
}

/// A line's kind, read before decoding it.
struct LineKind: Codable { var kind: String }

public enum SessionLog {
    /// `sessions/<yyyymmdd-hhmmss>-<id8>.jsonl`.
    public static func fileName(sessionID: String, at date: Date = Date()) -> String {
        "\(stamp(at: date))-\(sessionID.prefix(8)).jsonl"
    }

    /// `yyyyMMdd-HHmmss` in UTC: the stamp sessions and bench reports are named by.
    public static func stamp(at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    public static func newSessionID() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }

    /// 16 hex of sha256(pack ‖ index SHAs ‖ gate fingerprint ‖ prompt ‖ params): the same prompt to the same braid repeats it.
    public static func generationID(pack: PackIdentity, threads: [SessionThread], gateFingerprint: String, prompt: GenerationPrompt, params: GenerationParameters) -> String {
        let parts = [pack.sha256 ?? pack.vocabularySHA256] + threads.map { "\($0.name)@\($0.indexSHA256 ?? "-")" } + [gateFingerprint]
            + [(try? JSONCoding.line(prompt)) ?? prompt.text, (try? JSONCoding.line(params)) ?? ""]
        return "gen-" + String(ContentHash.sha256Hex(parts.joined(separator: "|")).prefix(16))
    }
}

/// Writes a session log line by line, hashing each generation's body as it goes.
public final class SessionWriter: @unchecked Sendable {
    public let url: URL
    public let header: SessionHeader
    private let writer: JSONLWriter
    private let encoder = JSONCoding.lineEncoder()
    private var body: [String] = []
    private var inGeneration = false

    public init(url: URL, header: SessionHeader) throws {
        self.url = url
        self.header = header
        writer = try JSONLWriter(url: url, truncate: true)
        try writer.appendRaw(String(decoding: try encoder.encode(header), as: UTF8.self))
    }

    private func write<T: Encodable>(_ value: T) throws {
        let line = String(decoding: try encoder.encode(value), as: UTF8.self)
        if inGeneration { body.append(line) }
        try writer.appendRaw(line)
    }

    public func begin(_ generation: GenerationLine) throws {
        inGeneration = true
        body = []
        try write(generation)
    }

    public func append(_ step: Step) throws { try write(step) }

    public func membership(_ line: MembershipLine) throws { try write(line) }

    /// Closes the generation with its body hash and returns the end line as written.
    @discardableResult
    public func end(generationID: String, tokens: Int, generated: Int, stoppedOn: StopReason?, text: String, partitions: [PartitionRef]) throws -> EndLine {
        let hash = ContentHash.sha256Hex(body.map { $0 + "\n" }.joined())
        let line = EndLine(generationID: generationID, tokens: tokens, generated: generated, stoppedOn: stoppedOn, text: text, partitions: partitions, bodySHA256: hash)
        inGeneration = false
        body = []
        try write(line)
        return line
    }

    public func close() { writer.close() }
}

/// A generation as read back: its lines in order.
public struct LoggedGeneration: Sendable, Equatable {
    public var gen: GenerationLine
    public var steps: [Step]
    public var end: EndLine?
    /// Membership changes inside this generation, keyed by the step index they precede.
    public var membership: [(before: Int, line: MembershipLine)]
    public var bodySHA256: String

    public static func == (lhs: LoggedGeneration, rhs: LoggedGeneration) -> Bool {
        lhs.gen == rhs.gen && lhs.steps == rhs.steps && lhs.end == rhs.end && lhs.bodySHA256 == rhs.bodySHA256
    }
}

public struct LoggedSession: Sendable {
    public var header: SessionHeader
    public var generations: [LoggedGeneration]
    public var membership: [MembershipLine]
}

public enum SessionReader {
    public enum Failure: Error, CustomStringConvertible, Equatable {
        case empty
        case noHeader
        case schema(Int)
        case stray(String, line: Int)

        public var description: String {
            switch self {
            case .empty: return "the session log is empty"
            case .noHeader: return "the first line is not a header"
            case .schema(let s): return "session schema \(s) is not \(BraidVersion.sessionSchema)"
            case .stray(let kind, let line): return "a \(kind) line outside a generation at line \(line)"
            }
        }
    }

    public static func read(_ url: URL) throws -> LoggedSession {
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n").filter { !$0.allSatisfy(\.isWhitespace) }
        guard let first = lines.first else { throw Failure.empty }
        let decoder = JSONCoding.decoder()
        guard (try? decoder.decode(LineKind.self, from: Data(first.utf8)))?.kind == "header" else { throw Failure.noHeader }
        let header = try decoder.decode(SessionHeader.self, from: Data(first.utf8))
        guard header.schema == BraidVersion.sessionSchema else { throw Failure.schema(header.schema) }
        var generations: [LoggedGeneration] = []
        var membership: [MembershipLine] = []
        var current: LoggedGeneration?
        var body: [String] = []
        for (n, raw) in lines.enumerated().dropFirst() {
            let data = Data(raw.utf8)
            let kind = try decoder.decode(LineKind.self, from: data).kind
            switch kind {
            case "gen":
                if let open = current { generations.append(open) }
                body = [String(raw)]
                current = LoggedGeneration(gen: try decoder.decode(GenerationLine.self, from: data), steps: [], end: nil, membership: [], bodySHA256: "")
            case "tok":
                guard var open = current else { throw Failure.stray(kind, line: n + 1) }
                body.append(String(raw))
                open.steps.append(try decoder.decode(Step.self, from: data))
                current = open
            case "end":
                guard var open = current else { throw Failure.stray(kind, line: n + 1) }
                open.end = try decoder.decode(EndLine.self, from: data)
                open.bodySHA256 = ContentHash.sha256Hex(body.map { $0 + "\n" }.joined())
                generations.append(open)
                current = nil
                body = []
            case "attach", "detach":
                let line = try decoder.decode(MembershipLine.self, from: data)
                membership.append(line)
                if var open = current {
                    body.append(String(raw))
                    open.membership.append((open.steps.count, line))
                    current = open
                }
            default:
                continue
            }
        }
        if var open = current {
            open.bodySHA256 = ContentHash.sha256Hex(body.map { $0 + "\n" }.joined())
            generations.append(open)
        }
        return LoggedSession(header: header, generations: generations, membership: membership)
    }
}
