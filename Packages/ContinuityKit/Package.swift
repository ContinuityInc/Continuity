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
    ],
    dependencies: [
        .package(path: "../ContinuityCore"),
        .package(url: "https://github.com/alexeichhorn/YouTubeKit", branch: "main"),
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", exact: "1.20.0"),
    ],
    targets: [
        // Domain: SwiftData @Model types, transition settings, and the on-disk cache path layer.
        // Swift 5 language mode matches the app target (SWIFT_VERSION 5.0) so extracting these
        // files into a module is a pure move with no concurrency-checking behavior change.
        .target(
            name: "Domain",
            dependencies: [.product(name: "ContinuityCore", package: "ContinuityCore")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Ingest: downloading, resolving playlists/streams, stem separation, track analysis.
        // Depends on Domain + ContinuityCore; owns the external YouTubeKit/onnxruntime deps.
        .target(
            name: "Ingest",
            dependencies: [
                "Domain",
                .product(name: "ContinuityCore", package: "ContinuityCore"),
                .product(name: "YouTubeKit", package: "YouTubeKit"),
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
