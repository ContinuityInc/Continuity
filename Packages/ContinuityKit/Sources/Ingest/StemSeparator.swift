import Foundation
import AVFoundation
import ContinuityCore
import OnnxRuntimeBindings
import os

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

/// HT-Demucs FT "vocals specialist" run via ONNX Runtime (CPU execution provider — see the
/// session comment for why CoreML is banned on device). Mirrors the model's reference pipeline:
/// decode → 44.1 kHz stereo → 7.8 s windows with 25% overlap → take the vocals source (index 3)
/// → overlap-add → accompaniment = mix − vocals.
///
/// The whole pipeline **streams**: decode, inference, overlap-add, and stem encoding all run
/// chunk-by-chunk, so peak memory is O(segment) — a few tens of MB — regardless of track length.
/// The previous whole-file implementation held ~7 full-length float buffers and jetsammed real
/// devices on long tracks (an hour of 44.1 kHz stereo ≈ >1 GB) while the simulator's host RAM
/// masked it.
final class OnnxStemSeparator: StemSeparating {
    private static let log = Logger(subsystem: "com.sanylax.continuity", category: "StemSeparator")

    /// Runs one model window: input is planar (1, 2, segment) mix samples; returns the planar
    /// (2, segment) vocals output. Seam so tests can exercise the streaming pipeline without the
    /// 158 MB ONNX model.
    typealias WindowInference = @Sendable ([Float]) throws -> [Float]

    private let modelURL: URL?
    private let inference: WindowInference?

    private let sampleRate = 44_100.0
    let segment = 343_980                  // 7.8 s @ 44.1 kHz — the model's fixed input length
    private let channels = 2
    private let sources = 4                // [drums, bass, other, vocals]
    private let vocalsIndex = 3

    /// Backstop against pathological inputs (multi-hour mixes): separation is truncated here.
    /// Bounds disk + CPU-hours; the streaming pipeline already bounds memory. Transitions only
    /// ever need stems near track edges of *songs* — a 30-min+ input is a mix/podcast where
    /// vocal-aware transitions matter less than staying alive.
    private let maxSeparationSeconds: Double = 1_800

    init(modelURL: URL) {
        self.modelURL = modelURL
        self.inference = nil
    }

    /// Test seam: bypasses ONNX entirely and runs `inference` per window.
    init(inference: @escaping WindowInference) {
        self.modelURL = nil
        self.inference = inference
    }

    /// One process-wide session: rebuilding it per track re-pays model load for zero benefit.
    private static let sessionLock = NSLock()
    nonisolated(unsafe) private static var cachedSession: (path: String, session: ORTSession)?

    private static func sharedSession(modelURL: URL) throws -> ORTSession {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        if let cached = cachedSession, cached.path == modelURL.path { return cached.session }
        do {
            let env = try ORTEnv(loggingLevel: .warning)
            let options = try ORTSessionOptions()
            // Cap thread fan-out: default parallel arenas on a phone balloon RSS toward the
            // ~3.4 GB per-process jetsam limit when loading HT-Demucs. One intra-op thread is
            // plenty for an offline cache-once job.
            try options.setIntraOpNumThreads(1)
            try options.addConfigEntry(withKey: "session.intra_op.allow_spinning", value: "0")
            let session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: options)
            cachedSession = (modelURL.path, session)
            return session
        } catch {
            throw StemSeparationError.inference("session: \(error)")
        }
    }

    func separate(inputURL: URL, vocalsOut: URL, accompanimentOut: URL) throws -> StemPaths {
        // ONNX Runtime session, CPU EP everywhere. The CoreML EP jetsammed real devices:
        // converting/compiling the 85M-param HT-Demucs transformer at session creation ballooned
        // the app past the per-process limit (~3.4 GB observed on iPhone 17 Pro — JetsamEvent
        // reason=per-process-limit) before a single window ran. CPU EP peaks a few hundred MB;
        // separation is an offline cache-once job, so slower-but-alive wins. Revisit via a real
        // Core ML (mlpackage) conversion if on-device speed ever matters more.
        // The session is cached: model load + graph init is expensive and identical per track.
        let runWindow: WindowInference
        if let inference {
            runWindow = inference
        } else {
            guard let modelURL, FileManager.default.fileExists(atPath: modelURL.path) else {
                throw StemSeparationError.modelMissing
            }
            let session = try Self.sharedSession(modelURL: modelURL)
            runWindow = Self.ortInference(session: session, segment: segment,
                                          channels: channels, vocalsIndex: vocalsIndex)
        }

        let decoder = try StreamingStereoDecoder(url: inputURL, sampleRate: sampleRate)
        let maxFrames = Int(maxSeparationSeconds * sampleRate)

        let vocalsFile = try openStemFile(vocalsOut)
        let accFile = try openStemFile(accompanimentOut)
        do {
            let frames = try runStreaming(decoder: decoder, runWindow: runWindow, maxFrames: maxFrames,
                                          vocalsFile: vocalsFile, accFile: accFile)
            guard frames > 0 else { throw StemSeparationError.decode("no audio frames") }
        } catch {
            // Don't leave truncated stems behind — a half-written cache entry would be linked as
            // if complete.
            try? FileManager.default.removeItem(at: vocalsOut)
            try? FileManager.default.removeItem(at: accompanimentOut)
            throw error
        }
        return StemPaths(vocals: vocalsOut, accompaniment: accompanimentOut)
    }

    /// The streaming core: pull decoded frames just far enough to run the next window, run
    /// inference, overlap-add, then flush every finalized frame (vocals + derived accompaniment)
    /// straight to the encoders. Pending state never exceeds ~segment + stride frames.
    private func runStreaming(decoder: StreamingStereoDecoder, runWindow: WindowInference,
                              maxFrames: Int, vocalsFile: AVAudioFile, accFile: AVAudioFile) throws -> Int {
        let ola = StreamingOverlapAdd(channels: channels, segment: segment, overlap: segment / 4)
        let stride = ola.stride

        // Un-flushed mix frames [flushed, flushed + mix count) — needed both as model input and
        // to derive accompaniment = mix − vocals after normalization.
        var mixL = [Float](), mixR = [Float]()
        var flushed = 0
        var decodedEnd = 0
        var atEOF = false
        var input = [Float](repeating: 0, count: channels * segment)

        var start = 0
        while true {
            // Decode ahead through the end of this window (or EOF / the length cap).
            while !atEOF && decodedEnd < start + segment {
                if let chunk = try decoder.next() {
                    var takeCount = chunk.left.count
                    if decodedEnd + takeCount >= maxFrames {
                        takeCount = maxFrames - decodedEnd
                        atEOF = true
                        Self.log.warning("separation truncated at \(self.maxSeparationSeconds, privacy: .public)s cap")
                    }
                    mixL.append(contentsOf: chunk.left.prefix(takeCount))
                    mixR.append(contentsOf: chunk.right.prefix(takeCount))
                    decodedEnd += takeCount
                } else {
                    atEOF = true
                }
            }
            if start >= decodedEnd { break }   // fully processed (or empty input)

            // Build the input tensor: shape (1, 2, segment), planar [ch0…, ch1…], zero-padded.
            let length = min(segment, decodedEnd - start)
            let offset = start - flushed
            for i in 0..<length {
                input[i] = mixL[offset + i]
                input[segment + i] = mixR[offset + i]
            }
            for i in length..<segment {
                input[i] = 0
                input[segment + i] = 0
            }

            let vocals = try runWindow(input)
            guard vocals.count >= channels * segment else {
                throw StemSeparationError.inference("short vocals output: \(vocals.count)")
            }
            ola.add(start: start, length: length) { c, i in vocals[c * segment + i] }

            start += stride

            // Everything before the next window's start is final: normalize, derive
            // accompaniment, and stream both out.
            let finalUpTo = min(start, decodedEnd)
            if finalUpTo > flushed {
                let voc = ola.drain(upTo: finalUpTo)
                let n = finalUpTo - flushed
                var accL = [Float](repeating: 0, count: n)
                var accR = [Float](repeating: 0, count: n)
                for i in 0..<n {
                    accL[i] = mixL[i] - voc[0][i]
                    accR[i] = mixR[i] - voc[1][i]
                }
                try append(to: vocalsFile, left: voc[0], right: voc[1])
                try append(to: accFile, left: accL, right: accR)
                mixL.removeFirst(n)
                mixR.removeFirst(n)
                flushed = finalUpTo
            }
            if atEOF && start >= decodedEnd { break }
        }
        return decodedEnd
    }

    /// Wraps the ORT session as a per-window inference closure. Output shape (1, 4, 2, segment);
    /// returns just the vocals source (index 3) as planar (2, segment).
    private static func ortInference(session: ORTSession, segment: Int,
                                     channels: Int, vocalsIndex: Int) -> WindowInference {
        { input in
            let inputData = input.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress, length: $0.count) }
            do {
                let inputValue = try ORTValue(tensorData: inputData, elementType: .float,
                                              shape: [1, NSNumber(value: channels), NSNumber(value: segment)])
                let outputs = try session.run(withInputs: ["mix": inputValue],
                                              outputNames: ["stems"], runOptions: nil)
                guard let out = outputs["stems"] else { throw StemSeparationError.inference("no 'stems' output") }
                let outData = try out.tensorData()
                let vocBase = (vocalsIndex * channels) * segment
                let count = channels * segment
                return (outData as Data).withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    let f = raw.bindMemory(to: Float.self)
                    return Array(UnsafeBufferPointer(start: f.baseAddress! + vocBase, count: count))
                }
            } catch let e as StemSeparationError {
                throw e
            } catch {
                throw StemSeparationError.inference("run: \(error)")
            }
        }
    }

    // MARK: - Audio I/O

    /// Opens a stem output file for incremental appends.
    private func openStemFile(_ url: URL) throws -> AVAudioFile {
        // AAC at 128 kbps, matched to the (~128 kbps) source's fidelity — a stem can't carry
        // more information than the mix it was separated from. This keeps a 1000-song stem
        // cache in single-digit GB; float32 PCM was ~140 MB per track (~140 GB per 1000).
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]
        do {
            return try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw StemSeparationError.write("open: \(error)")
        }
    }

    /// Appends planar stereo frames to an open stem file.
    private func append(to file: AVAudioFile, left: [Float], right: [Float]) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 2, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(left.count)) else {
            throw StemSeparationError.write("buffer")
        }
        buffer.frameLength = AVAudioFrameCount(left.count)
        guard let channelData = buffer.floatChannelData else { throw StemSeparationError.write("channel data") }
        left.withUnsafeBufferPointer { channelData[0].update(from: $0.baseAddress!, count: left.count) }
        right.withUnsafeBufferPointer { channelData[1].update(from: $0.baseAddress!, count: right.count) }
        do {
            try file.write(from: buffer)
        } catch {
            throw StemSeparationError.write("\(error)")
        }
    }
}

/// Decodes an audio file to 44.1 kHz stereo float chunks incrementally — never the whole file.
/// Uses a persistent pull-mode `AVAudioConverter` when the source needs sample-rate / channel /
/// format conversion.
final class StreamingStereoDecoder {
    private let file: AVAudioFile
    private let converter: AVAudioConverter?
    private let readChunk: AVAudioPCMBuffer     // in the file's processing format
    private let outBuffer: AVAudioPCMBuffer     // 44.1 kHz stereo float32 planar
    private var fileAtEnd = false
    private var converterDone = false
    private var pendingReadError: Error?

    /// ~256k frames per read (~2 MB stereo float) — same chunking philosophy as TrackAnalyzer.
    private static let chunkFrames: AVAudioFrameCount = 1 << 18

    init(url: URL, sampleRate: Double) throws {
        do { file = try AVAudioFile(forReading: url) } catch {
            throw StemSeparationError.decode("\(error)")
        }
        let inFormat = file.processingFormat
        guard file.length > 0 else { throw StemSeparationError.decode("empty file") }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 2, interleaved: false) else {
            throw StemSeparationError.decode("format")
        }
        guard let readChunk = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: Self.chunkFrames),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: Self.chunkFrames) else {
            throw StemSeparationError.decode("buffer alloc")
        }
        self.readChunk = readChunk
        self.outBuffer = outBuffer

        let isReady = inFormat.sampleRate == sampleRate
            && inFormat.channelCount == 2
            && inFormat.commonFormat == .pcmFormatFloat32
            && !inFormat.isInterleaved
        if isReady {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: inFormat, to: target) else {
                throw StemSeparationError.decode("converter")
            }
            self.converter = converter
        }
    }

    /// Returns the next decoded stereo chunk, or nil at end of stream.
    func next() throws -> (left: [Float], right: [Float])? {
        if let converter {
            guard !converterDone else { return nil }
            outBuffer.frameLength = 0
            var convError: NSError?
            let status = converter.convert(to: outBuffer, error: &convError) { [weak self] _, outStatus in
                guard let self else { outStatus.pointee = .endOfStream; return nil }
                // AVAudioFile.read at exact EOF throws ("nilError") instead of returning 0
                // frames — check the position first, in both decode paths.
                if self.fileAtEnd || self.file.framePosition >= self.file.length {
                    self.fileAtEnd = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                self.readChunk.frameLength = 0
                do {
                    try self.file.read(into: self.readChunk, frameCount: Self.chunkFrames)
                } catch {
                    self.pendingReadError = error
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if self.readChunk.frameLength == 0 {
                    self.fileAtEnd = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return self.readChunk
            }
            if let pendingReadError { throw StemSeparationError.decode("\(pendingReadError)") }
            if let convError { throw StemSeparationError.decode("\(convError)") }
            if status == .endOfStream || status == .error { converterDone = true }
            if outBuffer.frameLength == 0 {
                converterDone = true
                return nil
            }
            return Self.planar(outBuffer)
        } else {
            guard !fileAtEnd, file.framePosition < file.length else {
                fileAtEnd = true
                return nil
            }
            readChunk.frameLength = 0
            do { try file.read(into: readChunk, frameCount: Self.chunkFrames) } catch {
                throw StemSeparationError.decode("\(error)")
            }
            if readChunk.frameLength == 0 {
                fileAtEnd = true
                return nil
            }
            return Self.planar(readChunk)
        }
    }

    private static func planar(_ buffer: AVAudioPCMBuffer) -> (left: [Float], right: [Float])? {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channelData = buffer.floatChannelData else { return nil }
        let left = Array(UnsafeBufferPointer(start: channelData[0], count: frames))
        let right = buffer.format.channelCount > 1
            ? Array(UnsafeBufferPointer(start: channelData[1], count: frames))
            : left
        return (left, right)
    }
}
