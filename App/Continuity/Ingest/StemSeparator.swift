import Foundation
import AVFoundation
import OnnxRuntimeBindings

/// The two stems Continuity needs for vocal-aware transitions.
struct StemPaths: Sendable, Equatable {
    let vocals: URL
    let accompaniment: URL
}

enum StemSeparationError: Error, Sendable {
    case decode(String)
    case inference(String)
    case write(String)
    case modelMissing
}

/// Splits a track into **vocals** + **accompaniment** so a transition can duck the outgoing
/// vocals under the incoming instrumental. Swappable so the backend (ONNX, Core ML, …) can change
/// without touching the cache or playback layers.
protocol StemSeparating: Sendable {
    /// Separates `inputURL` and writes stem files, returning their paths. CPU-heavy + slow —
    /// callers run it off the main actor as an offline, cache-once job.
    func separate(inputURL: URL, vocalsOut: URL, accompanimentOut: URL) throws -> StemPaths
}

/// HT-Demucs FT "vocals specialist" run via ONNX Runtime (CoreML execution provider when present,
/// else CPU). Mirrors the model's reference pipeline: decode → 44.1 kHz stereo → 7.8 s windows with
/// 25% overlap → take the vocals source (index 3) → overlap-add → accompaniment = mix − vocals.
final class OnnxStemSeparator: StemSeparating {
    private let modelURL: URL

    private let sampleRate = 44_100.0
    private let segment = 343_980          // 7.8 s @ 44.1 kHz — the model's fixed input length
    private let channels = 2
    private let sources = 4                // [drums, bass, other, vocals]
    private let vocalsIndex = 3

    init(modelURL: URL) {
        self.modelURL = modelURL
    }

    func separate(inputURL: URL, vocalsOut: URL, accompanimentOut: URL) throws -> StemPaths {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw StemSeparationError.modelMissing
        }

        let (left, right, frames) = try decodePlanar(inputURL)
        guard frames > 0 else { throw StemSeparationError.decode("no audio frames") }

        // ONNX Runtime session — prefer the CoreML EP (Neural Engine) when available, else CPU.
        let session: ORTSession
        do {
            let env = try ORTEnv(loggingLevel: .warning)
            let options = try ORTSessionOptions()
            if ORTIsCoreMLExecutionProviderAvailable() {
                try? options.appendCoreMLExecutionProvider(with: ORTCoreMLExecutionProviderOptions())
            }
            session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: options)
        } catch {
            throw StemSeparationError.inference("session: \(error)")
        }

        var vocL = [Float](repeating: 0, count: frames)
        var vocR = [Float](repeating: 0, count: frames)
        var weight = [Float](repeating: 0, count: frames)

        let overlap = segment / 4
        let stride = segment - overlap
        let window = transitionWindow(segment: segment, fade: overlap)

        var start = 0
        while start < frames {
            let length = min(segment, frames - start)

            // Build the input tensor: shape (1, 2, segment), planar [ch0…, ch1…], zero-padded.
            var input = [Float](repeating: 0, count: channels * segment)
            for i in 0..<length {
                input[i] = left[start + i]
                input[segment + i] = right[start + i]
            }
            let inputData = input.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress, length: $0.count) }
            let stems: ORTValue
            do {
                let inputValue = try ORTValue(tensorData: inputData, elementType: .float,
                                              shape: [1, NSNumber(value: channels), NSNumber(value: segment)])
                let outputs = try session.run(withInputs: ["mix": inputValue],
                                              outputNames: ["stems"], runOptions: nil)
                guard let out = outputs["stems"] else { throw StemSeparationError.inference("no 'stems' output") }
                stems = out
            } catch let e as StemSeparationError {
                throw e
            } catch {
                throw StemSeparationError.inference("run: \(error)")
            }

            // Output shape (1, 4, 2, segment); take vocals source (index 3) and overlap-add it in.
            let outData = try stems.tensorData()
            (outData as Data).withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let f = raw.bindMemory(to: Float.self)
                let vocBase = (vocalsIndex * channels) * segment
                for i in 0..<length {
                    let w = window[i]
                    vocL[start + i] += f[vocBase + i] * w
                    vocR[start + i] += f[vocBase + segment + i] * w
                    weight[start + i] += w
                }
            }

            start += stride
        }

        // Normalize the overlap-add, then derive accompaniment as (mix − vocals).
        var accL = [Float](repeating: 0, count: frames)
        var accR = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            if weight[i] > 0 { vocL[i] /= weight[i]; vocR[i] /= weight[i] }
            accL[i] = left[i] - vocL[i]
            accR[i] = right[i] - vocR[i]
        }

        try writeStereo(vocalsOut, left: vocL, right: vocR)
        try writeStereo(accompanimentOut, left: accL, right: accR)
        return StemPaths(vocals: vocalsOut, accompaniment: accompanimentOut)
    }

    // MARK: - Audio I/O

    /// Decodes `url` to 44.1 kHz stereo, returning planar left/right float arrays.
    private func decodePlanar(_ url: URL) throws -> (left: [Float], right: [Float], frames: Int) {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw StemSeparationError.decode("\(error)") }
        let inFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0, let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frameCount) else {
            throw StemSeparationError.decode("buffer alloc")
        }
        do { try file.read(into: inBuffer) } catch { throw StemSeparationError.decode("\(error)") }

        let isReady = inFormat.sampleRate == sampleRate
            && inFormat.channelCount == 2
            && inFormat.commonFormat == .pcmFormatFloat32
            && !inFormat.isInterleaved
        let buffer: AVAudioPCMBuffer
        if isReady {
            buffer = inBuffer
        } else {
            guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                             channels: 2, interleaved: false),
                  let converter = AVAudioConverter(from: inFormat, to: target) else {
                throw StemSeparationError.decode("converter")
            }
            let capacity = AVAudioFrameCount(Double(inBuffer.frameLength) * sampleRate / inFormat.sampleRate) + 4096
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
                throw StemSeparationError.decode("out buffer")
            }
            var consumed = false
            var convError: NSError?
            converter.convert(to: outBuffer, error: &convError) { _, status in
                if consumed { status.pointee = .endOfStream; return nil }
                consumed = true; status.pointee = .haveData; return inBuffer
            }
            if let convError { throw StemSeparationError.decode("\(convError)") }
            buffer = outBuffer
        }

        let frames = Int(buffer.frameLength)
        guard let channelData = buffer.floatChannelData else { throw StemSeparationError.decode("no channel data") }
        let left = Array(UnsafeBufferPointer(start: channelData[0], count: frames))
        let right = buffer.format.channelCount > 1
            ? Array(UnsafeBufferPointer(start: channelData[1], count: frames))
            : left
        return (left, right, frames)
    }

    /// Writes a stereo float `.caf` from planar channel arrays.
    private func writeStereo(_ url: URL, left: [Float], right: [Float]) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 2, interleaved: false) else {
            throw StemSeparationError.write("format")
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            let frames = AVAudioFrameCount(left.count)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
                throw StemSeparationError.write("buffer")
            }
            buffer.frameLength = frames
            let channelData = buffer.floatChannelData!
            left.withUnsafeBufferPointer { channelData[0].update(from: $0.baseAddress!, count: left.count) }
            right.withUnsafeBufferPointer { channelData[1].update(from: $0.baseAddress!, count: right.count) }
            try file.write(from: buffer)
        } catch let e as StemSeparationError {
            throw e
        } catch {
            throw StemSeparationError.write("\(error)")
        }
    }

    /// Linear fade-in/out window of length `segment`, fading over `fade` samples at each end, so
    /// overlapping chunks cross-blend cleanly under overlap-add normalization.
    private func transitionWindow(segment: Int, fade: Int) -> [Float] {
        var window = [Float](repeating: 1, count: segment)
        guard fade > 1, fade * 2 <= segment else { return window }
        for i in 0..<fade {
            let g = Float(i) / Float(fade - 1)
            window[i] = g
            window[segment - 1 - i] = g
        }
        return window
    }
}
