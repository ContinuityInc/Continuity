import XCTest
import SwiftData
import OSLog
import Domain
@testable import Ingest

/// Opt-in, live-network diagnostic for the ingest pipeline. Skipped unless
/// `CONTINUITY_LIVE_PROBE=1` is in the environment, so normal test runs stay hermetic.
///
/// Drives the real `PreparationQueue` (YouTubeKit resolve → ranged download → analysis) for a
/// handful of well-known videos plus two search-query tracks, then prints every
/// `com.continuity.app` log line the run produced. When YouTube changes something and every
/// imported track starts spinning and then failing, this shows the failing stage and the exact
/// error in one run — no device, no debugger. Run it against an iOS Simulator destination:
///
///     cd Packages/ContinuityKit && CONTINUITY_LIVE_PROBE=1 \
///       DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
///       -scheme ContinuityKit-Package -destination 'platform=iOS Simulator,id=<UDID>' \
///       -only-testing:IngestTests/LiveIngestProbeTests
///
/// (The env var must reach the test process: xcodebuild forwards `TEST_RUNNER_`-prefixed
/// variables, so `TEST_RUNNER_CONTINUITY_LIVE_PROBE=1` also works.)
///
/// History: on 2026-09-10 this reproduced "every track spins, then shows the orange retry
/// badge" — every ranged download 403'd (`streamURLExpired`) because the pinned YouTubeKit
/// still asked the ANDROID_VR client for stream URLs, which YouTube stopped serving beyond the
/// first chunk in mid-August 2026. YouTubeKit 0.4.9 (visionOS/web clients) fixed it: 8/8 ready.
@MainActor
final class LiveIngestProbeTests: XCTestCase {

    private static let videoIDs = ["dQw4w9WgXcQ", "9bZkp7q19f0", "kJQP7kiw5Fk", "JGwWNGJdvx8"]
    private static let queries = ["Blinding Lights The Weeknd", "bad guy Billie Eilish"]

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["CONTINUITY_LIVE_PROBE"] == "1" || env["TEST_RUNNER_CONTINUITY_LIVE_PROBE"] == "1",
                          "live-network probe; set CONTINUITY_LIVE_PROBE=1 to run")
    }

    func testLiveIngest() async throws {
        let start = Date()
        let budget: TimeInterval = Double(ProcessInfo.processInfo.environment["CONTINUITY_LIVE_PROBE_SECONDS"] ?? "") ?? 300
        print("PROBE start os=\(ProcessInfo.processInfo.operatingSystemVersionString) budget=\(Int(budget))s")

        // Playlist page scrape (metadata only) — the first stage of a YouTube playlist import.
        do {
            let resolved = try await YouTubePlaylistResolver().resolvePlaylist(playlistID: "PLFgquLnL59alCl_2TQvOiD5Vgm1hCaGSI")
            print("PROBE playlist resolve OK: \(resolved.items.count) items, title=\(resolved.title ?? "-")")
        } catch {
            print("PROBE playlist resolve FAILED: \(error)")
        }

        let schema = Schema([Playlist.self, Track.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let queue = PreparationQueue()

        let playlist = Playlist(title: "Probe", subtitle: "probe", gradientSeed: 1)
        context.insert(playlist)
        var tracks: [Track] = []
        for (i, id) in Self.videoIDs.enumerated() {
            // Force a real download: evict any cached copy from an earlier run.
            for container in ["m4a", "webm", "mp4"] {
                try? FileManager.default.removeItem(at: AudioCache.fileURL(videoID: id, container: container))
            }
            let track = Track(title: "vid \(id)", artist: "probe", durationSeconds: 0, gradientSeed: i, sortIndex: i,
                              prepState: .pending, youtubeVideoID: id,
                              sourceURLString: "https://www.youtube.com/watch?v=\(id)")
            playlist.tracks.append(track); context.insert(track); tracks.append(track)
        }
        for (i, query) in Self.queries.enumerated() {
            let track = Track(title: query, artist: "probe", durationSeconds: 0, gradientSeed: 100 + i, sortIndex: 100 + i,
                              prepState: .pending, searchQuery: query)
            playlist.tracks.append(track); context.insert(track); tracks.append(track)
        }
        try context.save()
        for track in tracks { queue.enqueue(track, in: context) }

        var lastStates = ""
        while Date().timeIntervalSince(start) < budget {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            let states = tracks.map { "\($0.youtubeVideoID ?? $0.searchQuery ?? "?")=\($0.prepState.rawValue)" }.joined(separator: " ")
            if states != lastStates {
                print("PROBE t+\(Int(Date().timeIntervalSince(start)))s \(states)")
                lastStates = states
            }
            if tracks.allSatisfy({ $0.prepState == .ready || $0.prepState == .failed }) { break }
        }

        print("PROBE ===== LOG DUMP (com.continuity.app) =====")
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let entries = try store.getEntries(at: store.position(date: start))
            var printed = 0
            for case let entry as OSLogEntryLog in entries where entry.subsystem == "com.continuity.app" {
                printed += 1
                if printed > 400 { print("PROBE ... (truncated)"); break }
                let ts = String(format: "%.1f", entry.date.timeIntervalSince(start))
                print("PROBE LOG t+\(ts)s [\(entry.category)] \(entry.level.rawValue): \(entry.composedMessage)")
            }
            print("PROBE log entries printed: \(printed)")
        } catch {
            print("PROBE OSLogStore unavailable: \(error)")
        }

        print("PROBE ===== FINAL =====")
        for track in tracks {
            let path = track.localRelativePath.map { AudioCache.url(forRelativePath: $0).path } ?? "-"
            let bytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            print("PROBE FINAL \(track.youtubeVideoID ?? track.searchQuery ?? "?") state=\(track.prepState.rawValue) dur=\(Int(track.durationSeconds))s bytes=\(bytes) bpm=\(track.bpm ?? 0)")
        }
        let ready = tracks.filter { $0.prepState == .ready }.count
        print("PROBE RESULT ready=\(ready)/\(tracks.count) elapsed=\(Int(Date().timeIntervalSince(start)))s")
        XCTAssertEqual(ready, tracks.count, "not every probe track became ready — see PROBE LOG lines above")
    }
}
