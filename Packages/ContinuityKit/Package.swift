// swift-tools-version: 6.0
import PackageDescription

// ContinuityKit holds the app's iOS-only modules (SwiftData models, ingestion, playback),
// split into library targets with compiler-enforced boundaries so agents can work on them in
// parallel. The pure, cross-platform logic lives in the separate ContinuityCore package.
//
// Dependency order: ContinuityCore ◄─ Domain ◄─ { Ingest, Playback } ◄─ (app target).
let package = Package(
    name: "ContinuityKit",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "Domain", targets: ["Domain"]),
        .library(name: "Ingest", targets: ["Ingest"]),
        .library(name: "Playback", targets: ["Playback"]),
    ],
    dependencies: [
        .package(path: "../ContinuityCore"),
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", exact: "1.20.0"),
    ],
    targets: [
        .target(
            name: "Domain",
            dependencies: [.product(name: "ContinuityCore", package: "ContinuityCore")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Ingest: local-file import, stem separation, track analysis.
        .target(
            name: "Ingest",
            dependencies: [
                "Domain",
                .product(name: "ContinuityCore", package: "ContinuityCore"),
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "IngestTests",
            dependencies: ["Ingest"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "AVFAudioShim",
            path: "Sources/AVFAudioShim",
            publicHeadersPath: "include"
        ),
        .target(
            name: "Playback",
            dependencies: [
                "Domain",
                "AVFAudioShim",
                .product(name: "ContinuityCore", package: "ContinuityCore"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PlaybackTests",
            dependencies: ["Playback"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
