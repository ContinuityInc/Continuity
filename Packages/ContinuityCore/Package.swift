// swift-tools-version: 6.0
import PackageDescription

// ContinuityCore holds the pure-Swift, platform-agnostic logic that powers the
// transition engine: crossfade gain curves, harmonic-mixing (Camelot) rules, and
// beat-alignment math. Keeping it free of UIKit/AVFoundation means it compiles and
// unit-tests on any platform (including via `swift test` with only the Command Line
// Tools), so the math is verifiable without building the full iOS app.
let package = Package(
    name: "ContinuityCore",
    products: [
        .library(name: "ContinuityCore", targets: ["ContinuityCore"])
    ],
    targets: [
        .target(name: "ContinuityCore"),
        .testTarget(
            name: "ContinuityCoreTests",
            dependencies: ["ContinuityCore"]
        )
    ]
)
