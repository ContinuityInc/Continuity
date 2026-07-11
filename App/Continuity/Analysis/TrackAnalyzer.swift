import Foundation
import AVFoundation
import ContinuityCore

/// Result of analysing one track's audio.
struct TrackAnalysis: Sendable {
    let bpm: Double
    let beatTimes: [Double]
    let key: MusicalKey?
    let camelot: Camelot?
}

/// Decodes a cached audio file to mono PCM and runs the (pure, unit-tested) ContinuityCore
/// analyzers on it. This is the M3 bridge between the on-disk audio and the DSP core.
///
/// `analyze` is CPU-heavy (FFTs) and intentionally NOT `@MainActor` — callers run it off the main
/// actor (e.g. `Task.detached`) and apply the `Sendable` result on the main actor.
enum TrackAnalyzer {
    /// Bump when analyzer improvements should retroactively re-analyze the library. Tracks
    /// stamped below this (or unstamped) re-analyze at launch — otherwise results computed by an
    /// old, buggier analyzer persist forever (e.g. keys detected before the tuning-correction fix).
    /// v2 = tuning-corrected KeyDetector (PR #10).
    static let analysisVersion = 2

    /// Only the first few minutes are analysed: tempo and key are stable over a track, and this
    /// bounds memory + time for long mixes/podcasts (no multi-GB whole-file decode).
    private static let maxAnalysisSeconds: Double = 360 // 6 minutes
    /// Frames per decode chunk (~256k → a couple MB per read, then released).
    private static let chunkFrames: AVAudioFrameCount = 1 << 18

    static func analyze(fileURL: URL) throws -> TrackAnalysis {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: fileURL)
        } catch {
            throw IngestError.decodeFailed(String(describing: error))
        }

        let format = file.processingFormat
        let sampleRate = format.sampleRate
        guard file.length > 0, sampleRate > 0 else {
            throw IngestError.decodeFailed("empty or unreadable audio")
        }

        let maxFrames = AVAudioFramePosition(maxAnalysisSeconds * sampleRate)
        let framesToAnalyze = min(file.length, maxFrames)

        guard let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw IngestError.decodeFailed("buffer allocation failed")
        }

        // Stream the file in fixed-size chunks, down-mixing each into one growing mono array.
        // Peak memory ≈ one chunk + the (capped) mono result — never the whole stereo file.
        var mono = [Float]()
        mono.reserveCapacity(Int(framesToAnalyze))
        var remaining = framesToAnalyze
        while remaining > 0 {
            let want = AVAudioFrameCount(min(AVAudioFramePosition(chunkFrames), remaining))
            chunk.frameLength = 0
            do {
                try file.read(into: chunk, frameCount: want)
            } catch {
                throw IngestError.decodeFailed(String(describing: error))
            }
            let got = Int(chunk.frameLength)
            if got == 0 { break } // end of file
            Self.appendDownmix(chunk, into: &mono)
            remaining -= AVAudioFramePosition(got)
        }

        guard !mono.isEmpty else { throw IngestError.decodeFailed("no audio decoded") }

        let beat = BeatTracker.analyze(samples: mono, sampleRate: sampleRate)
        let key = KeyDetector.analyze(samples: mono, sampleRate: sampleRate)

        return TrackAnalysis(
            bpm: beat.bpm,
            beatTimes: beat.beatTimes,
            key: key?.key,
            camelot: key?.camelot
        )
    }

    /// Appends a down-mixed-to-mono copy of `buffer`'s frames onto `mono`.
    private static func appendDownmix(_ buffer: AVAudioPCMBuffer, into mono: inout [Float]) {
        guard let channelData = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return }

        if channels == 1 {
            mono.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: frames))
            return
        }
        let scale = 1.0 / Float(channels)
        for i in 0..<frames {
            var sum: Float = 0
            for c in 0..<channels { sum += channelData[c][i] }
            mono.append(sum * scale)
        }
    }
}

extension MusicalKey {
    /// Human-readable name, e.g. "C Major" / "F Sharp Minor".
    var displayName: String {
        let raw = String(describing: self) // e.g. "cMajor", "fSharpMinor"
        var name = ""
        for ch in raw {
            if ch.isUppercase { name += " " }
            name.append(ch)
        }
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}
