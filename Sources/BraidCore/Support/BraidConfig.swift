//
//  BraidConfig.swift
//  BraidCore
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: braid.toml at the work-area root, written by `braid init`: the pack a braid runs on
//        (its hashes and shape), the index and gate constants, which Threads bare `braid`
//        attaches, and where the machine's AII lives. The cut is the pack's (`braid_cut`), not
//        braid.toml's; a `cut` key an older file carries is ignored.
//

import Foundation

public struct BraidConfig: Sendable, Equatable {
    public struct Pack: Sendable, Equatable {
        public var name: String
        public var sha256: String
        public var vocabularySHA256: String
        public var tokenizerSHA256: String
        public var hiddenSize: Int
        public var layers: Int
        public var heads: Int
        public var headDim: Int
        public var stateSize: Int
        public var convKernel: Int
        public var vocabRows: Int
        public var vocabTokens: Int
        public var keyScheme: String

        public init(name: String, sha256: String, vocabularySHA256: String, tokenizerSHA256: String, hiddenSize: Int, layers: Int, heads: Int, headDim: Int,
                    stateSize: Int, convKernel: Int, vocabRows: Int, vocabTokens: Int, keyScheme: String) {
            self.name = name
            self.sha256 = sha256
            self.vocabularySHA256 = vocabularySHA256
            self.tokenizerSHA256 = tokenizerSHA256
            self.hiddenSize = hiddenSize
            self.layers = layers
            self.heads = heads
            self.headDim = headDim
            self.stateSize = stateSize
            self.convKernel = convKernel
            self.vocabRows = vocabRows
            self.vocabTokens = vocabTokens
            self.keyScheme = keyScheme
        }
    }

    public struct Index: Sendable, Equatable {
        public var alpha: Double = 0.5
        public var k: Int = 16
        public var tau: Double = 0.05
        public var checkpointStride: Int = 1024
        public init() {}
    }

    public var version = 1
    public var pack: Pack?
    public var index = Index()
    public var gate = GateSettings()
    public var attach: [String] = []
    public var aiiHome: String = "~/.rao"

    public init(pack: Pack? = nil) { self.pack = pack }

    public static let fileName = "braid.toml"

    public func render() -> String {
        var document: TOMLSubset.Document = [("", [("version", .integer(version))])]
        if let p = pack {
            document.append(("pack", [
                ("name", .string(p.name)), ("sha256", .string(p.sha256)), ("vocabulary_sha256", .string(p.vocabularySHA256)),
                ("tokenizer_sha256", .string(p.tokenizerSHA256)), ("hidden_size", .integer(p.hiddenSize)), ("layers", .integer(p.layers)),
                ("heads", .integer(p.heads)), ("head_dim", .integer(p.headDim)), ("state_size", .integer(p.stateSize)), ("conv_kernel", .integer(p.convKernel)),
                ("vocab_rows", .integer(p.vocabRows)), ("vocab_tokens", .integer(p.vocabTokens)), ("key_scheme", .string(p.keyScheme)),
            ]))
        }
        document.append(("index", [("alpha", .float(index.alpha)), ("k", .integer(index.k)), ("tau", .float(index.tau)), ("checkpoint_stride", .integer(index.checkpointStride))]))
        document.append(("gate", [
            ("evidence_floor", .float(gate.evidenceFloor)), ("evidence_ceiling", .float(gate.evidenceCeiling)), ("share_rate", .float(gate.shareRate)),
            ("credibility_rate", .float(gate.credibilityRate)), ("commons_prior", .float(gate.commonsPrior)), ("open_floor", .float(gate.openFloor)),
            ("module_gain", .float(gate.moduleGain)), ("shadow_beta", .float(gate.shadowBeta)), ("evidence", .string(gate.evidence.rawValue)),
        ]))
        document.append(("cluster", [("attach", .strings(attach))]))
        document.append(("aii", [("home", .string(aiiHome))]))
        return TOMLSubset.render(document)
    }

    public static func parse(_ text: String) throws -> BraidConfig {
        let document = try TOMLSubset.parse(text)
        func str(_ table: String, _ key: String) throws -> String {
            guard let value = TOMLSubset.value(document, table, key)?.string else { throw BraidFailure.configuration("braid.toml: missing \(table).\(key)") }
            return value
        }
        func int(_ table: String, _ key: String) throws -> Int {
            guard let value = TOMLSubset.value(document, table, key)?.integer else { throw BraidFailure.configuration("braid.toml: missing \(table).\(key)") }
            return value
        }
        var config = BraidConfig()
        config.version = TOMLSubset.value(document, "", "version")?.integer ?? 1
        if document.contains(where: { $0.table == "pack" }) {
            config.pack = Pack(name: try str("pack", "name"), sha256: try str("pack", "sha256"), vocabularySHA256: try str("pack", "vocabulary_sha256"),
                               tokenizerSHA256: try str("pack", "tokenizer_sha256"), hiddenSize: try int("pack", "hidden_size"), layers: try int("pack", "layers"),
                               heads: try int("pack", "heads"), headDim: try int("pack", "head_dim"), stateSize: try int("pack", "state_size"),
                               convKernel: try int("pack", "conv_kernel"), vocabRows: try int("pack", "vocab_rows"), vocabTokens: try int("pack", "vocab_tokens"),
                               keyScheme: try str("pack", "key_scheme"))
        }
        if let v = TOMLSubset.value(document, "index", "alpha")?.float { config.index.alpha = v }
        if let v = TOMLSubset.value(document, "index", "k")?.integer { config.index.k = v }
        if let v = TOMLSubset.value(document, "index", "tau")?.float { config.index.tau = v }
        if let v = TOMLSubset.value(document, "index", "checkpoint_stride")?.integer { config.index.checkpointStride = v }
        if let v = TOMLSubset.value(document, "gate", "evidence_floor")?.float { config.gate.evidenceFloor = v }
        if let v = TOMLSubset.value(document, "gate", "evidence_ceiling")?.float { config.gate.evidenceCeiling = v }
        if let v = TOMLSubset.value(document, "gate", "share_rate")?.float { config.gate.shareRate = v }
        if let v = TOMLSubset.value(document, "gate", "credibility_rate")?.float { config.gate.credibilityRate = v }
        if let v = TOMLSubset.value(document, "gate", "commons_prior")?.float { config.gate.commonsPrior = v }
        if let v = TOMLSubset.value(document, "gate", "open_floor")?.float { config.gate.openFloor = v }
        if let v = TOMLSubset.value(document, "gate", "module_gain")?.float { config.gate.moduleGain = v }
        if let v = TOMLSubset.value(document, "gate", "shadow_beta")?.float { config.gate.shadowBeta = v }
        if let v = TOMLSubset.value(document, "gate", "evidence")?.string, let e = GateSettings.Evidence(rawValue: v) { config.gate.evidence = e }
        config.attach = TOMLSubset.value(document, "cluster", "attach")?.strings ?? []
        config.aiiHome = TOMLSubset.value(document, "aii", "home")?.string ?? "~/.rao"
        return config
    }

    public static func load(from url: URL) throws -> BraidConfig { try parse(String(contentsOf: url, encoding: .utf8)) }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(render().utf8).write(to: url, options: .atomic)
    }

    public var sha256: String { ContentHash.sha256Hex(render()) }
}
