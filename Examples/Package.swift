// swift-tools-version: 6.4
// Created by Ritesh Pakala.
// Copyright © 2026 Rao Studios LLC.
//
// WHAT: The Braid playground, a package of its own, with two programs.
//       Braid, the playground, joins this Mac's AII as an app of its own, records test data in the app's
//       lane, trains one Thread on those records, attaches it to a braid beside the commons, and
//       asks it. Examples/run.sh builds it (release) and runs it.
//       Proof trains two Threads on one corpus, one with blocks 0..<12 of its own (the delta) and
//       one with the commons' blocks, scores the same texts through both, and reads whether the
//       delta is what makes retrieval entropy a provenance signal. Examples/proof.sh builds it
//       (release) and runs it with its arguments.
//       Scratch, the work area and the commons' pack, is shared by both. Its type is ScratchArea, so
//       that no type is named like its module.
// PIN:  Braid by path. AII by the URL and requirement Braid uses, with no traits (the Server trait
//       would pull Frigate and SinatraHarness by path), so SwiftPM resolves one AII; run.sh mirrors
//       it to the sibling checkout. ArgumentParser by the URL and requirement Braid uses, so it
//       resolves to Braid's pin. Swift 5 language mode, like Braid's MLX targets (MLX's types are
//       not Sendable). A package rather than an Xcode playground: MLX finds mlx.metallib only
//       beside the running binary.
import PackageDescription

let package = Package(
    name: "BraidPlayground",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(path: ".."),
        .package(url: "https://github.com/rao-studios/AII.git", branch: "main", traits: []),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "Scratch",
            dependencies: [
                .product(name: "BraidKit", package: "Braid"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Braid",
            dependencies: [
                "Scratch",
                .product(name: "BraidKit", package: "Braid"),
                .product(name: "AII", package: "AII"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Proof",
            dependencies: [
                "Scratch",
                .product(name: "BraidKit", package: "Braid"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
