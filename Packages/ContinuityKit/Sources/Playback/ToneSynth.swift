import AVFoundation

/// Generates a short, seamless, loopable musical phrase as PCM. Used only for M0 so the app
/// has pleasant audible output without bundling any copyrighted audio. From M1 the player
/// loads real decoded audio files instead; this whole file goes away then.
enum ToneSynth {

    static func makeLoop(seed: Int, format: AVAudioFormat, seconds: Double = 8) -> AVAudioPCMBuffer {
        let sampleRate = format.sampleRate
        let frameCount = AVAudioFrameCount(sampleRate * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channelData = buffer.floatChannelData else {
            // Should never happen with a standard float format; return a tiny silent buffer.
            return AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
        }
        buffer.frameLength = frameCount

        let channels = Int(format.channelCount)
        let total = Int(frameCount)

        // A gentle stacked-interval phrase rooted on a seed-chosen low note.
        let roots: [Double] = [130.81, 146.83, 164.81, 196.0, 220.0] // C3 D3 E3 G3 A3
        let root = roots[abs(seed) % roots.count]
        let intervals: [Double] = [1.0, 1.25, 1.5, 2.0]
        let notesPerLoop = 4
        let noteFrames = max(1, total / notesPerLoop)

        for n in 0..<notesPerLoop {
            let freq = root * intervals[(n + abs(seed)) % intervals.count]
            let start = n * noteFrames
            let end = min(start + noteFrames, total)
            for i in start..<end {
                let localT = Double(i - start) / Double(noteFrames)
                // Smooth 0→1→0 amplitude envelope; reaching ~0 at note edges avoids clicks.
                let env = sin(.pi * localT)
                let phase = 2.0 * .pi * freq * Double(i) / sampleRate
                let value = (sin(phase) + 0.3 * sin(2 * phase) + 0.15 * sin(3 * phase)) * env * 0.18
                for c in 0..<channels {
                    channelData[c][i] = Float(value)
                }
            }
        }

        // Belt-and-braces fade across the loop seam for a click-free repeat.
        let fade = min(1024, total / 8)
        if fade > 0 {
            for i in 0..<fade {
                let g = Float(i) / Float(fade)
                for c in 0..<channels {
                    channelData[c][i] *= g
                    channelData[c][total - 1 - i] *= g
                }
            }
        }
        return buffer
    }
}
