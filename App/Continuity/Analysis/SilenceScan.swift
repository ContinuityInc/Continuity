import AVFoundation
import ContinuityCore

/// App-side wrapper around `ContinuityCore.SilenceTrimmer`: decodes only the **head and tail**
/// of an audio file (targeted `framePosition` reads, not a full decode) and returns the track's
/// audible bounds for gapless transitions.
enum SilenceScan {
    /// How much of each end to scan. Leading silence beyond 15 s or trailing beyond 90 s would be
    /// bizarre for real music; scanning windows this size keeps the pass cheap (~20 MB of PCM).
    private static let headSeconds: Double = 15
    private static let tailSeconds: Double = 90

    /// Returns the audible bounds of `fileURL`, or nil if the file can't be decoded.
    static func audibleBounds(fileURL: URL) -> SilenceTrimmer.Bounds? {
        guard let file = try? AVAudioFile(forReading: fileURL) else { return nil }
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let totalFrames = file.length
        guard sampleRate > 0, totalFrames > 0 else { return nil }
        let duration = Double(totalFrames) / sampleRate

        func readMono(from start: AVAudioFramePosition, frames: AVAudioFrameCount) -> [Float]? {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
            file.framePosition = start
            guard (try? file.read(into: buffer, frameCount: frames)) != nil else { return nil }
            let n = Int(buffer.frameLength)
            guard n > 0, let data = buffer.floatChannelData else { return nil }
            let channels = Int(format.channelCount)
            var mono = [Float](repeating: 0, count: n)
            for c in 0..<channels {
                let src = data[c]
                for i in 0..<n { mono[i] += src[i] }
            }
            if channels > 1 {
                let scale = 1 / Float(channels)
                for i in 0..<n { mono[i] *= scale }
            }
            return mono
        }

        // Short file → scan the whole thing in one read.
        if duration <= headSeconds + tailSeconds {
            guard let mono = readMono(from: 0, frames: AVAudioFrameCount(totalFrames)) else { return nil }
            return SilenceTrimmer.audibleBounds(samples: mono, sampleRate: sampleRate)
        }

        // Head: leading-silence bound comes from the first `headSeconds`. (A fully-silent head
        // window returns audibleStart 0 — the untrimmed fallback — which is the conservative
        // "no trim" answer we want for silence longer than the window.)
        let headFrames = AVAudioFrameCount(headSeconds * sampleRate)
        guard let head = readMono(from: 0, frames: headFrames) else { return nil }
        let audibleStart = SilenceTrimmer.audibleBounds(samples: head, sampleRate: sampleRate).audibleStart

        // Tail: trailing-silence bound comes from the last `tailSeconds`.
        let tailFrames = AVAudioFrameCount(tailSeconds * sampleRate)
        let tailStart = totalFrames - AVAudioFramePosition(tailFrames)
        guard let tail = readMono(from: tailStart, frames: tailFrames) else { return nil }
        let tailBounds = SilenceTrimmer.audibleBounds(samples: tail, sampleRate: sampleRate)
        let tailOffset = Double(tailStart) / sampleRate
        // All-silent tail window returns the full span; that would mean 90 s of dead air — trim
        // to the window start in that (pathological) case is wrong too, so keep duration.
        let audibleEnd = tailBounds.audibleEnd < Double(tail.count) / sampleRate
            ? tailOffset + tailBounds.audibleEnd
            : duration

        return SilenceTrimmer.Bounds(audibleStart: audibleStart, audibleEnd: audibleEnd)
    }
}
