// swift-tools-version: 6.4
// Created by Ritesh Pakala.
// Copyright © 2026 Rao Studios LLC.
//
// Braid — the Braid Transformer: a braid of per-Thread Mamba2 strands under one reed,
// every token split exactly by the Thread that supplied it and cited to its source.
//
// Two products, as the handoff asks: BraidKit (the library) and braid (the executable).
// Six targets, so language modes and test gating can differ:
//   BraidCore      the domain, by phase: Support/ (JSON, hashing, config, the work area), Data/
//                  (corpora, datasets), Strand/ (the Node protocol, hits, the Cluster), Mixture/
//                  (gate, mixer, trace, trajectory), Record/ (the session log, verify, credit),
//                  Port/ (RaoLM)                           (Foundation + Crypto, Swift 6 strict)
//   BraidThread    AII Thread lanes over Seam: lane client, source, ingest, AII detection, demo
//                  AIIs                                     (AII + Seam + gRPC, Swift 6 strict)
//   BraidTerminal  the terminal toolkit: raw mode, cells, diff renderer, widgets, app loop
//                                                          (Foundation only, Swift 6 strict)
//   BraidKit       the engine, by phase: Model/ (the Mamba2/SSD trunk and the reed), Build/
//                  (pack + import, corpus, delta training, index + checkpoints + replay, the
//                  Thread store), Pipeline/ (Thread recipes and the engine that builds them),
//                  Run/ (LocalNode, the question path), Tools/ (benches, doctor)
//                                                          (MLX via Frigate, Swift 5 mode)
//   BraidStudio    the studio: state, MLX worker, screens, fixtures   (Swift 5 mode)
//   BraidCLI       the `braid` executable                            (Swift 5 mode)
//
// Invariants the layering test holds: no Sources target links MLXLLM or MLXLMCommon (Braid has
// no KV cache and no attention; Frigate's Mamba2Model is the import conformance oracle in
// BraidKitTests only); no type is named like a module; `Thread.` is never written qualified
// (Foundation's Thread shadows the AII module of that name).
//
// Frigate (the vendored MLX stack) is taken by URL on main, pinned in Package.resolved; its Metal
// shaders are compiled from SwiftPM's checkout of it (build-metallib.sh). AII is taken by URL with
// its Server trait off, which resolves AII, Seam, grpc-swift, swift-protobuf, swift-log and
// swift-crypto and nothing else; a local AII checkout resolves through a SwiftPM mirror
// (Scripts/cli.sh sets it). The gRPC packages are the URLs AII uses, so SwiftPM unifies
// them into one GRPCCore. MLX-facing targets use Swift 5 language mode because Frigate's MLX
// types are not Sendable (the choice RaoLM, Fleet and Zehn made).

import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Braid",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "BraidKit", targets: ["BraidKit"]),
        .executable(name: "braid", targets: ["BraidCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/rao-studios/Frigate.git", branch: "main"),
        .package(url: "https://github.com/rao-studios/AII.git", branch: "main", traits: []),
        .package(url: "https://github.com/grpc/grpc-swift.git", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.2.0"),
    ],
    targets: [
        .target(
            name: "BraidCore",
            dependencies: [.product(name: "Crypto", package: "swift-crypto")]
        ),
        .target(
            name: "BraidThread",
            dependencies: [
                "BraidCore",
                .product(name: "AII", package: "AII"),
                .product(name: "Seam", package: "AII"),
                .product(name: "GRPCCore", package: "grpc-swift"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
            ]
        ),
        // Foundation only and Swift 6 strict: the toolkit never touches MLX or Braid's types.
        .target(name: "BraidTerminal"),
        .target(
            name: "BraidKit",
            dependencies: [
                "BraidCore", "BraidThread",
                .product(name: "MLX", package: "Frigate"),
                .product(name: "MLXNN", package: "Frigate"),
                .product(name: "MLXOptimizers", package: "Frigate"),
                .product(name: "FrigateHub", package: "Frigate"),
                .product(name: "FrigateTokenizers", package: "Frigate"),
                .product(name: "FrigateBridge", package: "Frigate"),
            ],
            swiftSettings: v5
        ),
        .target(
            name: "BraidStudio",
            dependencies: ["BraidKit", "BraidTerminal"],
            swiftSettings: v5
        ),
        .executableTarget(
            name: "BraidCLI",
            dependencies: [
                "BraidKit", "BraidStudio",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: v5
        ),
        .testTarget(name: "BraidCoreTests", dependencies: ["BraidCore"]),
        .testTarget(
            name: "BraidThreadTests",
            dependencies: [
                "BraidThread", "BraidCore",
                .product(name: "AII", package: "AII"),
                .product(name: "Seam", package: "AII"),
            ]
        ),
        .testTarget(name: "BraidTerminalTests", dependencies: ["BraidTerminal"]),
        // The only place MLXLLM and MLXLMCommon are linked: Frigate's Mamba2Model is the oracle
        // the import conformance test compares the in-repo trunk against.
        .testTarget(
            name: "BraidKitTests",
            dependencies: [
                "BraidKit", "BraidCore",
                .product(name: "MLX", package: "Frigate"),
                .product(name: "MLXNN", package: "Frigate"),
                .product(name: "MLXLLM", package: "Frigate"),
                .product(name: "MLXLMCommon", package: "Frigate"),
            ],
            resources: [.copy("Fixtures")],
            swiftSettings: v5
        ),
        .testTarget(
            name: "BraidStudioTests",
            dependencies: ["BraidStudio", "BraidTerminal", "BraidCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: v5
        ),
        .testTarget(name: "BraidCLITests", dependencies: ["BraidCLI"], swiftSettings: v5),
    ]
)
