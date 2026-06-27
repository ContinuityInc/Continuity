import XCTest
@testable import ContinuityCore

final class BeatTrackerTests: XCTestCase {

    // MARK: - Synthetic signal helper

    /// Build a mono click track: a short, exponentially-decaying blip at every beat.
    /// - Parameters:
    ///   - bpm: tempo of the clicks.
    ///   - seconds: total length of the buffer.
    ///   - sampleRate: sample rate in Hz.
    ///   - blipMillis: duration of each decaying impulse.
    private func clickTrack(
        bpm: Double,
        seconds: Double,
        sampleRate: Double,
        blipMillis: Double = 8
    ) -> [Float] {
        let total = Int(seconds * sampleRate)
        var out = [Float](repeating: 0, count: total)

        let beatInterval = 60.0 / bpm
        let blipSamples = max(1, Int(blipMillis / 1000.0 * sampleRate))
        // ~1.8 kHz tone in the blip so it produces real spectral content (and thus flux).
        let toneFreq = 1800.0
        let decay = 5.0  // exponential decay rate over the blip

        var beatTime = 0.0
        while beatTime < seconds {
            let startSample = Int(beatTime * sampleRate)
            for k in 0..<blipSamples {
                let idx = startSample + k
                guard idx < total else { break }
                let frac = Double(k) / Double(blipSamples)
                let envelope = exp(-decay * frac)
                let phase = 2.0 * Double.pi * toneFreq * (Double(k) / sampleRate)
                out[idx] += Float(envelope * sin(phase))
            }
            beatTime += beatInterval
        }
        return out
    }

    // MARK: - Tempo detection

    func testDetects120BPM() {
        let samples = clickTrack(bpm: 120, seconds: 10, sampleRate: 44_100)
        let analysis = BeatTracker.analyze(samples: samples, sampleRate: 44_100)
        XCTAssertEqual(analysis.bpm, 120, accuracy: 4)
        XCTAssertGreaterThan(analysis.confidence, 0)
        XCTAssertLessThanOrEqual(analysis.confidence, 1)
    }

    func testDetects90BPM() {
        let samples = clickTrack(bpm: 90, seconds: 10, sampleRate: 44_100)
        let analysis = BeatTracker.analyze(samples: samples, sampleRate: 44_100)
        XCTAssertEqual(analysis.bpm, 90, accuracy: 4)
        XCTAssertGreaterThan(analysis.confidence, 0)
    }

    func testDetects140BPM() {
        let samples = clickTrack(bpm: 140, seconds: 10, sampleRate: 44_100)
        let analysis = BeatTracker.analyze(samples: samples, sampleRate: 44_100)
        XCTAssertEqual(analysis.bpm, 140, accuracy: 4)
        XCTAssertGreaterThan(analysis.confidence, 0)
    }

    // MARK: - Beat grid

    func testBeatSpacing() {
        let samples = clickTrack(bpm: 120, seconds: 10, sampleRate: 44_100)
        let analysis = BeatTracker.analyze(samples: samples, sampleRate: 44_100)

        // Need at least a couple of beats to measure spacing.
        XCTAssertGreaterThan(analysis.beatTimes.count, 2)

        // Average consecutive spacing should be ~0.5s for a 120 BPM track.
        var deltas: [Double] = []
        for i in 1..<analysis.beatTimes.count {
            deltas.append(analysis.beatTimes[i] - analysis.beatTimes[i - 1])
        }
        let avg = deltas.reduce(0, +) / Double(deltas.count)
        XCTAssertEqual(avg, 0.5, accuracy: 0.05)

        // Beat times should be strictly ascending.
        for i in 1..<analysis.beatTimes.count {
            XCTAssertGreaterThan(analysis.beatTimes[i], analysis.beatTimes[i - 1])
        }
    }

    // MARK: - Safety

    func testEmptyInputIsSafe() {
        let analysis = BeatTracker.analyze(samples: [], sampleRate: 44_100)
        XCTAssertEqual(analysis.bpm, 0)
        XCTAssertTrue(analysis.beatTimes.isEmpty)
        XCTAssertEqual(analysis.confidence, 0)
    }

    func testTooShortInputIsSafe() {
        // A handful of samples is far below the minimum frame count.
        let analysis = BeatTracker.analyze(samples: [Float](repeating: 0, count: 100), sampleRate: 44_100)
        XCTAssertEqual(analysis.bpm, 0)
        XCTAssertTrue(analysis.beatTimes.isEmpty)
        XCTAssertEqual(analysis.confidence, 0)
    }
}
