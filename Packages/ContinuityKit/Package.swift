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
        .library(name: "Playback", targets: ["Playback"]),
    ],
    dependencies: [
        .package(path: "../ContinuityCore"),
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
        // Playback: AVAudioEngine decks, player state machine, now-playing bridge.
        // Sibling of Ingest — depends on Domain + ContinuityCore only, never on Ingest.
        .target(
            name: "Playback",
            dependencies: ["Domain", .product(name: "ContinuityCore", package: "ContinuityCore")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
