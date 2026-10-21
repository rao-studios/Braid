//
//  ImportConformanceTests.swift
//  BraidKitTests
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The import oracle: Braid's trunk against Frigate's Mamba2 implementation on the same
//        checkpoint folder. Logits within 1e-3 on fixed prompts; the token-by-token path within
//        1e-3 of the forward. The only place MLXLLM is linked. Runs when a pack has been imported
//        into the work area (BRAID_MLX_TESTS=1 and the T9 mounted).
//

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import Testing
@testable import BraidKit

private let importedPacks: [URL] = {
    guard let area = WorkArea.resolve() else { return [] }
    let urls = (try? FileManager.default.contentsOfDirectory(at: area.packs, includingPropertiesForKeys: nil)) ?? []
    return urls.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent(Pack.infoFile).path) }
}()

extension BraidMLXSuites {
    @Suite("Import conformance", .enabled(if: mlxTests && !importedPacks.isEmpty), .serialized)
    struct ImportConformanceTests {
        func maxAbs(_ a: MLXArray, _ b: MLXArray) -> Float {
            let d = abs(a.asType(.float32) - b.asType(.float32))
            eval(d)
            return d.max().item(Float.self)
        }

        /// Frigate's model, loaded from the checkpoint folder the pack came from.
        func reference(for pack: Pack) throws -> (Mamba2Model, URL)? {
            guard pack.info.source.hasPrefix("hub:") else { return nil }
            let repo = String(pack.info.source.dropFirst(4).split(separator: "@")[0])
            let folder = try PackImporter.fetch(repo: repo, revision: nil, modelsHome: WorkArea.resolve()!.modelsHome) { _ in }
            let config = try JSONCoding.decoder().decode(Mamba2Configuration.self, from: Data(JSONCoding.standardized(String(contentsOf: folder.appendingPathComponent("config.json"), encoding: .utf8)).utf8))
            let model = Mamba2Model(config)
            var weights: [String: MLXArray] = [:]
            for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where file.pathExtension == "safetensors" {
                for (key, value) in try loadArrays(url: file) { weights[key] = value.asType(.float32) }
            }
            try model.update(parameters: ModuleParameters.unflattened(model.sanitize(weights: weights)), verify: [.all])
            eval(model)
            return (model, folder)
        }

        @Test("the pack loads with its hashes re-derived, and the trunk's logits match Frigate's within 1e-3")
        func logitsMatch() throws {
            let pack = try Pack.load(from: importedPacks[0])
            let tokenizer = try BraidTokenizer(folder: pack.tokenizerFolder)
            #expect(tokenizer.eos == 0 && tokenizer.vocabSize == pack.info.tokenizerVocabSize)
            let trunk = try Trunk(pack: pack)
            let reed = pack.reed(tokens: tokenizer.vocabSize)
            guard let (model, _) = try reference(for: pack) else { return }
            var worst: Float = 0
            for prompt in ["The history of the city begins", "In 1848, the committee resolved that", "Once upon a time there was a"] {
                let ids: [Int32] = [tokenizer.eos] + tokenizer.encode(prompt)
                let input = MLXArray(ids, [1, ids.count])
                let ours = reed.logits(array: trunk.forward(tokens: input, state: nil, resets: nil).final[0])
                let theirs = model(input, cache: nil)[0]
                let n = tokenizer.vocabSize
                worst = max(worst, maxAbs(ours[0..., 0 ..< n], theirs[0..., 0 ..< n]))
            }
            #expect(worst < 1e-3, "max |Δ logits| \(worst)")
            print("import conformance: max |Δ logits| vs Frigate \(worst)")
        }

        @Test("the token-by-token step matches the forward over 32 tokens")
        func stepMatchesForward() throws {
            let pack = try Pack.load(from: importedPacks[0])
            let tokenizer = try BraidTokenizer(folder: pack.tokenizerFolder)
            let trunk = try Trunk(pack: pack)
            let ids: [Int32] = [tokenizer.eos] + tokenizer.encode("It was the best of times, it was the worst of times, it was the age of wisdom, it was the age of foolishness")
            let prefix = Array(ids.prefix(33))
            let whole = trunk.forward(tokens: MLXArray(prefix, [1, prefix.count]), state: nil, resets: nil)
            var state = StateStack.zeros(config: pack.config, batch: 1)
            var worst: Float = 0
            for (t, token) in prefix.enumerated() {
                let out = trunk.step(token: MLXArray([token]), state: state, reset: nil)
                worst = max(worst, maxAbs(out.final[0], whole.final[0, t]))
                state = out.state
            }
            #expect(worst < 1e-3, "max |Δ final| step vs forward \(worst)")
            for i in 0..<pack.config.numHiddenLayers { #expect(maxAbs(state.layers[i].ssm, whole.state.layers[i].ssm) < 1e-3) }
        }
    }
}
