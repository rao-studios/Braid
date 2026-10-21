//
//  CommonsTrunkTests.swift
//  BraidKitTests
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The commons is the trunk every Thread runs. On the live Thread: its tail blocks, embedding and
//        final norm are the commons' own module instances and its head blocks are its own; a version or
//        an index that names another seam or cut is refused before a head runs; a head file that carries
//        a block of the trunk, or lacks one of its own, is refused; a Thread node passed as the commons is
//        refused; and a head in front of the commons' tail gives what one monolithic trunk gives, bit for
//        bit, through forward and step, on a fixed prompt.
//

import Foundation
import MLX
import MLXNN
import Testing
@testable import BraidKit

extension BraidMLXSuites {
    @Suite("The commons is the trunk", .enabled(if: mlxTests), .serialized)
    struct CommonsTrunkTests {
        static let tiny = Mamba2Config(hiddenSize: 16, numHiddenLayers: 3, numHeads: 2, headDim: 4, stateSize: 4, nGroups: 1, convKernel: 4, vocabSize: 32, cut: 1)

        @Test("a Thread's tail is the commons' own modules; its head is its own")
        func tailIsTheCommons() throws {
            guard let (_, _, loaded) = liveThread, let commons = liveCommonsNode else { return }
            let thread = loaded.node.trunk
            let cut = commons.trunk.config.cut
            #expect(thread.seamSHA256 == commons.trunk.seamSHA256)
            #expect(thread.blocks.count == commons.trunk.blocks.count)
            for i in cut ..< commons.trunk.blocks.count { #expect(thread.blocks[i] === commons.trunk.blocks[i], "block \(i) is the commons' own instance") }
            for i in 0 ..< cut { #expect(thread.blocks[i] !== commons.trunk.blocks[i], "block \(i) is the Thread's own instance") }
            #expect(thread.backbone.embeddings === commons.trunk.backbone.embeddings)
            #expect(thread.backbone.normF === commons.trunk.backbone.normF)
            #expect(thread.tail.count == commons.trunk.config.numHiddenLayers - cut && thread.head.count == cut)
            #expect(loaded.node.descriptor.seamSHA256 == commons.descriptor.seamSHA256)
            print("COMMONS TRUNK: \(thread.tail.count) tail blocks are the commons', \(thread.head.count) head blocks the Thread's own, seam \(thread.seamSHA256.prefix(12))")
        }

        @Test("a version or an index that names another seam or cut is refused before a head runs")
        func foreignSeamRefused() throws {
            let tail = Trunk(Self.tiny).tail
            func version(seam: String, cut: Int) -> ThreadVersionInfo {
                ThreadVersionInfo(version: 3, packSHA256: "p", seamSHA256: seam, vocabularySHA256: "v", tokenizerSHA256: "t", cut: cut, keyScheme: .residual(afterBlocks: 1),
                                  corpusHash: "c", snapshotHash: "c", trained: true, steps: 1, epochs: 1, learned: true, memorised: 1, meanLoss: 0, heldOutLoss: nil,
                                  blocksSHA256: "b", indexSHA256: "i", checkpointsSHA256: "k", entries: 1, createdAt: Date())
            }
            func index(seam: String, cut: Int) -> IndexInfo {
                IndexInfo(keyScheme: .residual(afterBlocks: 1), alpha: 0.5, keyDims: 32, count: 1, documents: 1, partitions: 1, blocksSHA256: "b", packSHA256: "p",
                          seamSHA256: seam, vocabularySHA256: "v", corpusHash: "c", tokenizerSHA256: "t", threadID: nil, evalLoss: 0, evalEntropy: 0,
                          evalMemorisedFraction: 1, cut: cut, paragraphBreak: [535], eos: 0, checkpointsSHA256: "k", indexSHA256: "i", createdAt: Date())
            }
            let own = version(seam: tail.seamSHA256, cut: tail.cut)
            #expect(throws: Never.self) { try ThreadStore.checkSeam(own, index: index(seam: tail.seamSHA256, cut: tail.cut), tail: tail, thread: "t") }
            #expect(throws: BraidFailure.self) { try ThreadStore.checkSeam(version(seam: "0000000000000000", cut: tail.cut), index: nil, tail: tail, thread: "t") }
            #expect(throws: BraidFailure.self) { try ThreadStore.checkSeam(version(seam: tail.seamSHA256, cut: tail.cut + 1), index: nil, tail: tail, thread: "t") }
            #expect(throws: BraidFailure.self) { try ThreadStore.checkSeam(own, index: index(seam: "0000000000000000", cut: tail.cut), tail: tail, thread: "t") }
            #expect(throws: BraidFailure.self) { try ThreadStore.checkSeam(own, index: index(seam: tail.seamSHA256, cut: tail.cut + 1), tail: tail, thread: "t") }
        }

        @Test("a head file that carries a block of the trunk, or lacks one of its own, is refused")
        func headFileRefused() throws {
            let whole = Trunk(Self.tiny)
            let cut = Self.tiny.cut
            let arrays = Dictionary(uniqueKeysWithValues: whole.flattenedParameters().filter { Trunk.blockIndex(ofKey: $0.0) != nil })
            let own = arrays.filter { Trunk.blockIndex(ofKey: $0.key)! < cut }
            let head = try Trunk.makeHead(arrays: own, config: Self.tiny)
            #expect(head.count == cut)
            for (i, block) in head.enumerated() { #expect(block !== whole.blocks[i], "a loaded head is its own instance") }
            var withTail = own
            let tailKey = arrays.keys.first { Trunk.blockIndex(ofKey: $0) == cut }!
            withTail[tailKey] = arrays[tailKey]
            #expect(throws: BraidFailure.self) { _ = try Trunk.makeHead(arrays: withTail, config: Self.tiny) }
            #expect(throws: BraidFailure.self) { _ = try Trunk.makeHead(arrays: [:], config: Self.tiny) }
            #expect(throws: BraidFailure.self) { _ = try Trunk.makeHead(arrays: ["backbone.embeddings.weight": whole.embedding], config: Self.tiny) }
            var partial = own
            partial.removeValue(forKey: own.keys.sorted().first!)
            #expect(throws: (any Error).self) { _ = try Trunk.makeHead(arrays: partial, config: Self.tiny) }
        }

        @Test("a Thread node passed as the commons is refused")
        func threadAsCommonsRefused() throws {
            guard let (area, pack, loaded) = liveThread else { return }
            #expect(throws: BraidFailure.self) { _ = try ThreadStore.load(loaded.info.name, in: area, pack: pack, commons: loaded.node) }
        }

        @Test("a head in front of the commons' tail equals one monolithic trunk, bit for bit")
        func bitIdentical() throws {
            guard let (_, pack, loaded) = liveThread, liveCommonsNode != nil else { return }
            // The trunk the old loader built: every block fresh, the pack's weights, the version's blocks laid over 0..<cut.
            let monolithic = Trunk(pack.config)
            var weights = pack.blocks
            let blocksURL = loaded.directory.appendingPathComponent(ThreadStore.blocksFile)
            if FileManager.default.fileExists(atPath: blocksURL.path) { for (key, value) in try loadArrays(url: blocksURL) { weights[key] = value } }
            weights[Pack.embeddingKey] = pack.embedding
            weights[Pack.normKey] = pack.norm
            try monolithic.update(parameters: ModuleParameters.unflattened(weights), verify: [.all])
            eval(monolithic)
            let tokenizer = try BraidTokenizer(folder: pack.tokenizerFolder)
            let words = "The article says Tillyburn was founded in 1128, and the keeper of Harlow Light trimmed the lamp every night since the winter the harbour froze, when the town's records began"
            let tokens: [Int32] = [tokenizer.eos] + Array(tokenizer.encode(words).prefix(63))
            func bits(_ a: MLXArray) -> [UInt32] { a.asType(.float32).asArray(Float.self).map(\.bitPattern) }
            let input = MLXArray(tokens, [1, tokens.count])
            let mine = loaded.node.trunk
            // The kernels themselves: the same trunk twice gives the same bits.
            let once = monolithic.forward(tokens: input, state: nil, resets: nil), twice = monolithic.forward(tokens: input, state: nil, resets: nil)
            let kernelsRepeat = bits(once.final) == bits(twice.final)
            #expect(kernelsRepeat, "the same trunk's forward run twice differs in its bits")
            let a = mine.forward(tokens: input, state: nil, resets: nil), b = monolithic.forward(tokens: input, state: nil, resets: nil)
            let finalEqual = bits(a.final) == bits(b.final)
            #expect(finalEqual, "forward: the final states differ")
            var statesEqual = true
            for i in 0 ..< pack.config.numHiddenLayers where bits(a.state.layers[i].ssm) != bits(b.state.layers[i].ssm) || bits(a.state.layers[i].conv) != bits(b.state.layers[i].conv) {
                statesEqual = false
            }
            #expect(statesEqual, "forward: a layer's state differs")
            var sa = StateStack.zeros(config: pack.config, batch: 1), sb = StateStack.zeros(config: pack.config, batch: 1)
            var differing = 0
            for token in tokens {
                let x = mine.step(token: MLXArray([token]), state: sa, reset: nil), y = monolithic.step(token: MLXArray([token]), state: sb, reset: nil)
                if bits(x.final) != bits(y.final) { differing += 1 }
                sa = x.state
                sb = y.state
            }
            #expect(differing == 0, "step: \(differing) of \(tokens.count) positions differ")
            print("BIT-IDENTICAL: \(tokens.count) tokens, forward final equal \(finalEqual), every layer's state equal \(statesEqual), step positions differing \(differing), kernels repeat \(kernelsRepeat)")
        }
    }
}
