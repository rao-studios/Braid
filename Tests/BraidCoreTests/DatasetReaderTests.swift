//
//  DatasetReaderTests.swift
//  BraidCoreTests
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation
import Testing
@testable import BraidCore

private let braidN3 = DatasetsRoot.raolmDatasets.appendingPathComponent("braid-n3", isDirectory: true)
private let t9Mounted = FileManager.default.fileExists(atPath: braidN3.appendingPathComponent("manifest.json").path)

@Suite("Dataset reader")
struct DatasetReaderTests {
    @Test("braid-n3 on the T9 loads and its hashes recompute", .enabled(if: t9Mounted))
    func loadsBraidN3() throws {
        let dataset = try BraidDataset.load(braidN3)
        #expect(dataset.names.count == 3)
        for name in dataset.names {
            let corpus = try dataset.corpus(node: name)
            let summary = dataset.manifest.nodes.first { $0.name == name }!
            #expect(corpus.documents.count == summary.documents)
            #expect(corpus.manifest.documentIDs == corpus.documents.map(\.id))
            #expect(corpus.recomputedCorpusHash == summary.corpusHash, "corpus hash of \(name)")
            #expect(corpus.recomputedCorpusHash == corpus.manifest.corpusHash)
            #expect(!(dataset.meta[name] ?? []).isEmpty)
        }
        #expect(try dataset.recomputedHash() == dataset.manifest.datasetHash)
        #expect(!dataset.crosslinks.isEmpty)
        #expect(dataset.crosslinks.contains { $0.kind == .paraphrase && !$0.agreeingFacts.isEmpty })
        let facts = dataset.corpora.values.flatMap(\.facts)
        #expect(facts.allSatisfy { $0.answer.hasPrefix(" ") && $0.answerEnd > $0.answerStart })
        #expect(facts.contains { !($0.questions ?? []).isEmpty })
    }

    @Test func rootResolution() throws {
        let env = ["BRAID_DATASETS_DIR": "/tmp/ds"]
        #expect(DatasetsRoot.resolve(environment: env, workArea: nil, exists: { _ in false })?.path == "/tmp/ds")
        let work = URL(fileURLWithPath: "/work")
        #expect(DatasetsRoot.resolve(environment: [:], workArea: work, exists: { $0.path == "/work/datasets" })?.path == "/work/datasets")
        #expect(DatasetsRoot.resolve(environment: [:], workArea: work, exists: { $0 == DatasetsRoot.raolmDatasets }) == DatasetsRoot.raolmDatasets)
        #expect(DatasetsRoot.resolve(environment: [:], workArea: nil, exists: { _ in false }) == nil)
        #expect(try DatasetsRoot.locate("braid-n3", root: work).path == "/work/braid-n3")
        #expect(try DatasetsRoot.locate("/x/y", root: nil).path == "/x/y")
        #expect(throws: DatasetError.noDatasetsRoot) { try DatasetsRoot.locate("braid-n3", root: nil) }
    }

    @Test func workArea() {
        #expect(WorkArea.resolve(environment: ["BRAID_WORK_AREA": "/w"], exists: { _ in false })?.root.path == "/w")
        #expect(WorkArea.resolve(environment: [:], exists: { $0 == WorkArea.t9Projects })?.root == WorkArea.t9)
        #expect(WorkArea.resolve(environment: [:], exists: { _ in false }) == nil)
        let area = WorkArea(root: URL(fileURLWithPath: "/w"))
        #expect(area.pack(sha256: "0123456789abcdef0123").path == "/w/packs/0123456789ab")
        #expect(area.thread("a").version(3).path == "/w/threads/a/versions/v0003")
    }
}
