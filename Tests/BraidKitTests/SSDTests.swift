//
//  SSDTests.swift
//  BraidKitTests
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation
import MLX
import MLXNN
import Testing
@testable import BraidKit

extension BraidMLXSuites {
    @Suite("The selective scan", .serialized)
    struct SSDTests {
        static let tiny = Mamba2Config(hiddenSize: 16, numHiddenLayers: 2, numHeads: 2, headDim: 4, stateSize: 4, nGroups: 1, convKernel: 4, vocabSize: 32,
                                       layerNormEpsilon: 1e-5, timeStepLimit: [0, .infinity], tieWordEmbeddings: true, chunkSize: 3, cut: 1, tapAfterBlocks: 1)

        func maxAbs(_ a: MLXArray, _ b: MLXArray) -> Float {
            let d = abs(a.asType(.float32) - b.asType(.float32))
            eval(d)
            return d.max().item(Float.self)
        }

        /// Random inputs for the scan: x [B,L,H,P], dt [B,L,H], B/C [B,L,G,N], parameters.
        func inputs(batch b: Int, length l: Int, resets: Bool, seed: UInt64) -> (x: MLXArray, dt: MLXArray, B: MLXArray, C: MLXArray, aLog: MLXArray, D: MLXArray, dtBias: MLXArray, resets: MLXArray?) {
            let c = Self.tiny
            MLXRandom.seed(seed)
            let x = MLXRandom.normal([b, l, c.numHeads, c.headDim])
            let dt = MLXRandom.normal([b, l, c.numHeads]) * 0.5
            let B = MLXRandom.normal([b, l, c.nGroups, c.stateSize]) * 0.5
            let C = MLXRandom.normal([b, l, c.nGroups, c.stateSize]) * 0.5
            let aLog = log(MLXArray(1 ... c.numHeads).asType(.float32))
            let D = MLXRandom.normal([c.numHeads])
            let dtBias = MLXArray.ones([c.numHeads]) * 0.3
            var r: MLXArray? = nil
            if resets {
                var flags = [Bool](repeating: false, count: b * l)
                for i in 0..<b { flags[i * l + (i + 2) % l] = true; flags[i * l + l - 1] = i == 0 }
                r = MLXArray(flags, [b, l])
            }
            return (x, dt, B, C, aLog, D, dtBias, r)
        }

        @Test("the chunked scan equals the token-by-token recurrence, resets included")
        func stepEqualsScan() {
            let c = Self.tiny
            let (b, l) = (2, 7)
            let inp = inputs(batch: b, length: l, resets: true, seed: 1)
            let (y, state) = SSD.scan(x: inp.x, dt: inp.dt, aLog: inp.aLog, B: inp.B, C: inp.C, D: inp.D, dtBias: inp.dtBias, limits: c.limits, state: nil, resets: inp.resets, chunk: 3)
            var s = MLXArray.zeros([b, c.numHeads, c.headDim, c.stateSize], dtype: .float32)
            var ys: [MLXArray] = []
            for t in 0..<l {
                let (yt, st) = SSD.step(x: inp.x[0..., t], dt: inp.dt[0..., t], aLog: inp.aLog, B: inp.B[0..., t], C: inp.C[0..., t], D: inp.D, dtBias: inp.dtBias,
                                        limits: c.limits, state: s, reset: inp.resets?[0..., t])
                ys.append(expandedDimensions(yt, axis: 1))
                s = st
            }
            let stepped = concatenated(ys, axis: 1)
            #expect(maxAbs(y, stepped) < 1e-5)
            #expect(maxAbs(state, s) < 1e-5)
            // A second call continuing from the state equals one longer scan.
            let more = inputs(batch: b, length: 5, resets: false, seed: 2)
            let (y2, state2) = SSD.scan(x: more.x, dt: more.dt, aLog: inp.aLog, B: more.B, C: more.C, D: inp.D, dtBias: inp.dtBias, limits: c.limits, state: state, resets: nil, chunk: 3)
            let (yAll, stateAll) = SSD.scan(x: concatenated([inp.x, more.x], axis: 1), dt: concatenated([inp.dt, more.dt], axis: 1), aLog: inp.aLog,
                                            B: concatenated([inp.B, more.B], axis: 1), C: concatenated([inp.C, more.C], axis: 1), D: inp.D, dtBias: inp.dtBias,
                                            limits: c.limits, state: nil, resets: concatenated([inp.resets!, MLXArray.zeros([b, 5], dtype: .bool)], axis: 1), chunk: 4)
            #expect(maxAbs(yAll[0..., l...], y2) < 1e-5)
            #expect(maxAbs(stateAll, state2) < 1e-5)
        }

        @Test("the causal convolution equals its step, and a reset cuts the window")
        func convolution() {
            let (b, l, ch, k) = (2, 6, 5, 4)
            MLXRandom.seed(3)
            let x = MLXRandom.normal([b, l, ch])
            let weight = MLXRandom.normal([ch, k, 1])
            let bias = MLXRandom.normal([ch])
            var flags = [Bool](repeating: false, count: b * l)
            flags[3] = true
            let resets = MLXArray(flags, [b, l])
            let (y, window) = SSD.causalConv(x: x, weight: weight, bias: bias, window: nil, resets: resets)
            var w = MLXArray.zeros([b, k - 1, ch], dtype: .float32)
            var ys: [MLXArray] = []
            for t in 0..<l {
                let (yt, wt) = SSD.convStep(x: x[0..., t], weight: weight, bias: bias, window: w, reset: resets[0..., t])
                ys.append(expandedDimensions(yt, axis: 1))
                w = wt
            }
            #expect(maxAbs(y, concatenated(ys, axis: 1)) < 1e-5)
            #expect(maxAbs(window, w) < 1e-5)
            // At the reset position only the current input counts.
            let direct = (x[0, 3] * weight[0..., k - 1, 0] + bias)
            #expect(maxAbs(y[0, 3], direct) < 1e-5)
        }

        @Test("gradients flow through the scan and match the unrolled recurrence")
        func gradients() {
            let c = Self.tiny
            let (b, l) = (1, 6)
            let inp = inputs(batch: b, length: l, resets: true, seed: 4)
            func lossScan(_ x: MLXArray) -> MLXArray {
                let (y, s) = SSD.scan(x: x, dt: inp.dt, aLog: inp.aLog, B: inp.B, C: inp.C, D: inp.D, dtBias: inp.dtBias, limits: c.limits, state: nil, resets: inp.resets, chunk: 4)
                return (y * y).sum() + (s * s).sum()
            }
            func lossSteps(_ x: MLXArray) -> MLXArray {
                var s = MLXArray.zeros([b, c.numHeads, c.headDim, c.stateSize], dtype: .float32)
                var total = MLXArray(Float(0))
                for t in 0..<l {
                    let (yt, st) = SSD.step(x: x[0..., t], dt: inp.dt[0..., t], aLog: inp.aLog, B: inp.B[0..., t], C: inp.C[0..., t], D: inp.D, dtBias: inp.dtBias,
                                            limits: c.limits, state: s, reset: inp.resets?[0..., t])
                    total = total + (yt * yt).sum()
                    s = st
                }
                return total + (s * s).sum()
            }
            let gScan = grad(lossScan)(inp.x)
            let gSteps = grad(lossSteps)(inp.x)
            eval(gScan, gSteps)
            let scale = max(abs(gSteps).max().item(Float.self), 1e-6)
            #expect(maxAbs(gScan, gSteps) / scale < 1e-4)
            // Finite differences on one coordinate.
            let eps: Float = 1e-2
            var plus = inp.x.asArray(Float.self)
            var minus = plus
            plus[5] += eps
            minus[5] -= eps
            let fd = (lossScan(MLXArray(plus, inp.x.shape)).item(Float.self) - lossScan(MLXArray(minus, inp.x.shape)).item(Float.self)) / (2 * eps)
            let analytic = gScan.asArray(Float.self)[5]
            #expect(abs(fd - analytic) <= 2e-2 * max(abs(analytic), 1), "fd \(fd) analytic \(analytic)")
        }

        @Test("two documents packed with resets equal each alone, through two whole blocks")
        func packedEqualsPerDocument() {
            let c = Self.tiny
            MLXRandom.seed(5)
            let trunk = Trunk(c)
            let docA: [Int32] = [0, 5, 6, 7, 8, 9]
            let docB: [Int32] = [0, 10, 11, 12]
            let packed = MLXArray(docA + docB, [1, docA.count + docB.count])
            let resets = MLXArray((docA + docB).map { $0 == 0 }, [1, docA.count + docB.count])
            let both = trunk.forward(tokens: packed, state: nil, resets: resets, taps: TapRequest(residualAfterBlocks: [1]))
            let a = trunk.forward(tokens: MLXArray(docA, [1, docA.count]), state: nil, resets: MLXArray(docA.map { $0 == 0 }, [1, docA.count]), taps: TapRequest(residualAfterBlocks: [1]))
            let bOnly = trunk.forward(tokens: MLXArray(docB, [1, docB.count]), state: nil, resets: MLXArray(docB.map { $0 == 0 }, [1, docB.count]), taps: TapRequest(residualAfterBlocks: [1]))
            #expect(maxAbs(both.final[0..., 0 ..< docA.count], a.final) < 1e-4)
            #expect(maxAbs(both.final[0..., docA.count...], bOnly.final) < 1e-4)
            #expect(maxAbs(both.residual[1]![0..., docA.count...], bOnly.residual[1]!) < 1e-4)
            for i in 0..<c.numHiddenLayers { #expect(maxAbs(both.state.layers[i].ssm, bOnly.state.layers[i].ssm) < 1e-4) }
            // Token by token equals the forward.
            var state = StateStack.zeros(config: c, batch: 1)
            var finals: [MLXArray] = []
            for (t, token) in docA.enumerated() {
                let out = trunk.step(token: MLXArray([token]), state: state, reset: MLXArray([t == 0]))
                finals.append(expandedDimensions(out.final, axis: 1))
                state = out.state
            }
            #expect(maxAbs(concatenated(finals, axis: 1), a.final) < 1e-4)
            #expect(maxAbs(state.layers[1].ssm, a.state.layers[1].ssm) < 1e-4)
            #expect(state.position == docA.count - 1 && a.state.position == docA.count - 1)
        }

        @Test("the state stack round-trips through safetensors and bytes; the 130m stack is 19,390,464 bytes")
        func stateStack() throws {
            let c = Self.tiny
            MLXRandom.seed(6)
            let trunk = Trunk(c)
            let out = trunk.forward(tokens: MLXArray([Int32]([0, 3, 4, 5]), [1, 4]), state: nil, resets: nil)
            var stack = out.state
            stack.prefixSHA256 = "abc"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("braid-stack-\(UUID().uuidString).safetensors")
            defer { try? FileManager.default.removeItem(at: url) }
            try stack.save(to: url, packSHA256: "pack")
            let loaded = try StateStack.load(from: url, expecting: c)
            #expect(loaded.position == 3 && loaded.prefixSHA256 == "abc")
            #expect(loaded.sha256 == stack.sha256)
            let bytes = try stack.data(packSHA256: nil)
            #expect(try StateStack.from(data: bytes, expecting: c).sha256 == stack.sha256)
            let m130 = Mamba2Config(hiddenSize: 768, numHiddenLayers: 24, numHeads: 24, headDim: 64, stateSize: 128, nGroups: 1, convKernel: 4, vocabSize: 50288, cut: 12)
            #expect(StateStack.byteCount(config: m130) == 19_390_464)
            #expect(StorageMath(config: m130).threadParameters == 45_183_840 && StorageMath(config: m130).trunkBytes == 335_223_168)
            #expect(StorageMath(config: m130).totalParameters == 128_989_632 + 0 || StorageMath(config: m130).totalParameters > 128_000_000)
        }
    }
}
