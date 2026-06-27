import XCTest
@testable import ContinuityCore

final class AudioStreamSelectorTests: XCTestCase {

    private func aac(_ itag: Int, bitrate: Int) -> AudioStreamCandidate {
        AudioStreamCandidate(itag: itag, container: "m4a", audioCodec: "mp4a.40.2",
                             averageBitrate: bitrate, isAudioOnly: true,
                             isNativelyPlayable: true, urlString: "https://x/\(itag)")
    }
    private func opus(_ itag: Int, bitrate: Int) -> AudioStreamCandidate {
        AudioStreamCandidate(itag: itag, container: "webm", audioCodec: "opus",
                             averageBitrate: bitrate, isAudioOnly: true,
                             isNativelyPlayable: false, urlString: "https://x/\(itag)")
    }
    private func videoStream(_ itag: Int, bitrate: Int) -> AudioStreamCandidate {
        AudioStreamCandidate(itag: itag, container: "mp4", audioCodec: "mp4a.40.2",
                             averageBitrate: bitrate, isAudioOnly: false,
                             isNativelyPlayable: true, urlString: "https://x/\(itag)")
    }

    func testPicksHighestBitrateAAC() {
        let chosen = AudioStreamSelector.selectBest(from: [aac(139, bitrate: 48_000), aac(140, bitrate: 128_000)])
        XCTAssertEqual(chosen?.itag, 140)
    }

    func testPrefersNativeAACOverHigherBitrateOpus() {
        // Opus is higher bitrate but not natively playable -> AAC should still win.
        let chosen = AudioStreamSelector.selectBest(from: [opus(251, bitrate: 160_000), aac(140, bitrate: 128_000)])
        XCTAssertEqual(chosen?.itag, 140)
    }

    func testFallsBackToOpusWhenNoNative() {
        let chosen = AudioStreamSelector.selectBest(from: [opus(250, bitrate: 70_000), opus(251, bitrate: 160_000)])
        XCTAssertEqual(chosen?.itag, 251)
    }

    func testIgnoresVideoStreams() {
        let chosen = AudioStreamSelector.selectBest(from: [videoStream(22, bitrate: 500_000), aac(140, bitrate: 128_000)])
        XCTAssertEqual(chosen?.itag, 140)
    }

    func testReturnsNilWhenNoAudio() {
        XCTAssertNil(AudioStreamSelector.selectBest(from: [videoStream(22, bitrate: 500_000)]))
        XCTAssertNil(AudioStreamSelector.selectBest(from: []))
    }

    func testNativelyPlayableSelectorRejectsOpusOnly() {
        XCTAssertNil(AudioStreamSelector.selectBestNativelyPlayable(from: [opus(251, bitrate: 160_000)]))
        XCTAssertEqual(AudioStreamSelector.selectBestNativelyPlayable(from: [aac(140, bitrate: 128_000)])?.itag, 140)
    }

    func testTieBreakOnItag() {
        let chosen = AudioStreamSelector.selectBest(from: [aac(140, bitrate: 128_000), aac(139, bitrate: 128_000)])
        XCTAssertEqual(chosen?.itag, 139) // lower itag wins ties
    }
}
