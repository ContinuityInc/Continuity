// swift-tools-version: 6.0
import PackageDescription

// ContinuityCore holds the pure-Swift, platform-agnostic logic that powers the
// transition engine: crossfade gain curves, harmonic-mixing (Camelot) rules, and
// beat-alignment math. Keeping it free of UIKit/AVFoundation means the Foundation
// subset compiles and unit-tests on Linux via `swift test` (see AGENTS.md).
//
// BeatTracker.swift and KeyDetector.swift import Accelerate (Apple vDSP). On Linux
// SwiftPM excludes them from the ContinuityCore target so `swift test` is first-class
// — no throwaway assemble script. On Apple platforms the full target (including BPM
// and key suites) builds as one module for ContinuityKit / the app. Do not change the
// BeatTracker/KeyDetector algorithms in this package layout work.

#if os(Linux)
/// Sources that require Apple's Accelerate; omitted from the Linux build.
private let accelerateSources = [
    "BeatTracker.swift",
    "KeyDetector.swift",
]
/// Tests that exercise those sources; Mac-only.
private let accelerateTests = [
    "BeatTrackerTests.swift",
    "KeyDetectorTests.swift",
    "KeyDetectorAccuracyTests.swift",
]
#else
private let accelerateSources: [String] = []
private let accelerateTests: [String] = []
#endif

let package = Package(
    name: "ContinuityCore",
    products: [
        .library(name: "ContinuityCore", targets: ["ContinuityCore"])
    ],
    targets: [
        .target(
            name: "ContinuityCore",
            exclude: accelerateSources
        ),
        .testTarget(
            name: "ContinuityCoreTests",
            dependencies: ["ContinuityCore"],
            exclude: accelerateTests
        )
    ]
)
