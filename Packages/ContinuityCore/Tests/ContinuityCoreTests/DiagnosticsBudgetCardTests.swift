import XCTest
@testable import ContinuityCore

final class DiagnosticsBudgetCardTests: XCTestCase {
    override func tearDown() {
        MemoryBudgetRecorder.shared.reset()
        super.tearDown()
    }

    func testSnapshotExtractsStagePeaksFromBreadcrumbs() {
        let samples: [MemoryBreadcrumbSample] = [
            .init(label: "ort session load begin", headroomMB: 2_200, rssMB: 900),
            .init(label: "ort session ready", headroomMB: 1_600, rssMB: 1_500),
            .init(label: "window 0", headroomMB: 1_400, rssMB: 1_800),
            .init(label: "window 10", headroomMB: 1_200, rssMB: 2_100),
            .init(label: "window 20", headroomMB: 1_300, rssMB: 1_900),
            .init(label: "separation done", headroomMB: 1_500, rssMB: 1_700),
            .init(label: "ort session drain", headroomMB: 2_000, rssMB: 800),
            .init(label: "playback", headroomMB: 2_400, rssMB: 850),
        ]

        let snapshot = MemoryBudgetRecorder.snapshot(
            from: samples,
            qualityTier: "full",
            avfAudioExceptionCount: 3,
            lastCaughtDescription: "play: engine not running",
            stemRequiredStartMB: 1_400,
            stemWindowFloorMB: 600,
            physicalMemoryMB: 8_192,
            currentHeadroomMB: 2_400,
            currentRSSMB: 850
        )

        XCTAssertEqual(snapshot.peakRSSMB, 2_100)
        XCTAssertEqual(snapshot.sessionLoadBeginRSSMB, 900)
        XCTAssertEqual(snapshot.sessionLoadReadyRSSMB, 1_500)
        XCTAssertEqual(snapshot.windowPeakRSSMB, 2_100)
        XCTAssertEqual(snapshot.separationDoneRSSMB, 1_700)
        XCTAssertEqual(snapshot.sessionDrainRSSMB, 800)
        XCTAssertEqual(snapshot.latestPlaybackHeadroomMB, 2_400)
        XCTAssertEqual(snapshot.latestPlaybackRSSMB, 850)
        XCTAssertEqual(snapshot.avfAudioExceptionCount, 3)
        XCTAssertEqual(snapshot.qualityTier, "full")
    }

    func testRenderIncludesTierExceptionsAndPeaks() {
        let snapshot = DiagnosticsBudgetSnapshot(
            qualityTier: "balanced",
            avfAudioExceptionCount: 2,
            lastCaughtDescription: "start: bad format",
            stemRequiredStartMB: 1_600,
            stemWindowFloorMB: 600,
            physicalMemoryMB: 5_500,
            currentHeadroomMB: 1_100,
            currentRSSMB: 1_200,
            peakRSSMB: 2_800,
            sessionLoadBeginRSSMB: 1_000,
            sessionLoadReadyRSSMB: 2_200,
            windowPeakRSSMB: 2_800,
            separationDoneRSSMB: 1_900,
            sessionDrainRSSMB: 900,
            latestPlaybackHeadroomMB: 1_100,
            latestPlaybackRSSMB: 1_200,
            recentBreadcrumbs: [
                .init(label: "ort session ready", headroomMB: 1_500, rssMB: 2_200),
                .init(label: "playback", headroomMB: 1_100, rssMB: 1_200),
            ]
        )

        let text = DiagnosticsBudgetCard.render(snapshot)
        XCTAssertTrue(text.contains("== Stem / playback budget =="))
        XCTAssertTrue(text.contains("adaptive quality tier: balanced"))
        XCTAssertTrue(text.contains("requiredStart=1600 MB"))
        XCTAssertTrue(text.contains("windowFloor=600 MB"))
        XCTAssertTrue(text.contains("peak RSS (this process): 2800 MB"))
        XCTAssertTrue(text.contains("ORT session ready RSS: 2200 MB"))
        XCTAssertTrue(text.contains("window peak RSS: 2800 MB"))
        XCTAssertTrue(text.contains("ORT session drain RSS: 900 MB"))
        XCTAssertTrue(text.contains("AVFAudio exceptions caught this session: 2"))
        XCTAssertTrue(text.contains("last caught: start: bad format"))
        XCTAssertTrue(text.contains("mem[ort session ready] 1500 MB headroom 2200 MB rss"))
        XCTAssertTrue(text.contains("mem[playback] 1100 MB headroom 1200 MB rss"))
    }

    func testRenderMarksMissingMeasurements() {
        let text = DiagnosticsBudgetCard.render(
            DiagnosticsBudgetSnapshot(
                qualityTier: "constrained",
                avfAudioExceptionCount: 0,
                stemRequiredStartMB: 1_800,
                stemWindowFloorMB: 600
            )
        )
        XCTAssertTrue(text.contains("peak RSS (this process): n/a"))
        XCTAssertTrue(text.contains("(none yet)"))
        XCTAssertTrue(text.contains("last caught: none"))
    }

    func testRecorderTracksPeakAndRingCapacity() {
        let recorder = MemoryBudgetRecorder()
        for i in 0..<(MemoryBudgetRecorder.capacity + 5) {
            recorder.record(.init(label: "window \(i)", headroomMB: 1_000, rssMB: i))
        }
        let snapshot = recorder.makeSnapshot(
            qualityTier: "full",
            avfAudioExceptionCount: 0,
            stemRequiredStartMB: 1_400,
            stemWindowFloorMB: 600
        )
        XCTAssertEqual(snapshot.recentBreadcrumbs.count, MemoryBudgetRecorder.capacity)
        XCTAssertEqual(snapshot.recentBreadcrumbs.first?.label, "window 5")
        XCTAssertEqual(snapshot.peakRSSMB, MemoryBudgetRecorder.capacity + 4)
        XCTAssertEqual(snapshot.windowPeakRSSMB, MemoryBudgetRecorder.capacity + 4)
    }

    func testSharedRecorderFeedsMakeSnapshot() {
        MemoryBudgetRecorder.shared.record(
            .init(label: "ort session load begin", headroomMB: 2_000, rssMB: 700)
        )
        MemoryBudgetRecorder.shared.record(
            .init(label: "ort session ready", headroomMB: 1_400, rssMB: 1_600)
        )
        let snapshot = MemoryBudgetRecorder.shared.makeSnapshot(
            qualityTier: "full",
            avfAudioExceptionCount: 1,
            lastCaughtDescription: "scheduleSegment: bad range",
            stemRequiredStartMB: 1_400,
            stemWindowFloorMB: 600,
            currentHeadroomMB: 1_800,
            currentRSSMB: 900
        )
        XCTAssertEqual(snapshot.sessionLoadReadyRSSMB, 1_600)
        XCTAssertEqual(snapshot.peakRSSMB, 1_600)
        XCTAssertEqual(snapshot.avfAudioExceptionCount, 1)
    }
}
