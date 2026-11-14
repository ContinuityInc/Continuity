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

/// Memory budgets (MB) gating separation — the ORT session load (~600 MB transient: fp16→fp32
/// upcast + protobuf parse) plus the first window's attention arena (up to ~1.7 GB for the 7.8 s
/// segment) is the single biggest allocation in the app. Sized from the jetsam RCA estimates;
/// tune against the mem[] breadcrumbs from a real device run.
enum StemSeparationBudget {
    /// Headroom required to START a separation (session load + first-window peak + margin).
    /// Scales up on low-RAM / thermal tiers so Air-class devices don't open ORT into a hitch.
    static var requiredStartMB: Int { AdaptiveQuality.stemRequiredStartMB() }
    /// Mid-track floor: abort before the next window if headroom falls below this.
    static var windowFloorMB: Int { AdaptiveQuality.stemWindowFloorMB }
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
/// The whole pipeline **streams** through `StemStreamingEngine`: decode, inference, overlap-add,
/// and stem encoding all run chunk-by-chunk, so peak memory is O(segment) — a few tens of MB —
/// regardless of track length. The previous whole-file implementation held ~7 full-length float
/// buffers and jetsammed real devices on long tracks (an hour of 44.1 kHz stereo ≈ >1 GB) while
/// the simulator's host RAM masked it.
final class OnnxStemSeparator: StemSeparating {
    // com.continuity.app matches every other logger in the app — one Console filter sees all.
    private static let log = Logger(subsystem: "com.continuity.app", category: "StemSeparator")

    /// Runs one model window: input is planar (1, 2, segment) mix samples; returns the planar
    /// (2, segment) vocals output. Seam so tests can exercise the streaming pipeline without the
    /// 158 MB ONNX model.
    typealias WindowInference = StemStreamingEngine.WindowInference

    private let modelURL: URL?
    private let inference: WindowInference?

    private var segment: Int { StemWindowSpec.segmentFrames }
    private var channels: Int { StemWindowSpec.channelCount }
    private var vocalsIndex: Int { StemWindowSpec.vocalsSourceIndex }

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

    /// Drops the cached session, returning its weights/arenas to the OS. Called when the
    /// separation queue drains: the session is worth caching *between back-to-back tracks*,
    /// but holding hundreds of MB of transformer weights under live playback + UI for the
    /// rest of the process lifetime is exactly the jetsam margin long sessions die on.
    static func releaseSession() {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        let hadSession = cachedSession != nil
        cachedSession = nil
        // Budget-card anchor: RSS after weights/arenas are dropped (pairs with load begin/ready).
        if hadSession { MemoryFootprint.breadcrumb("ort session drain") }
    }

    /// Set on a system memory warning; the streaming loop checks it before each window and
    /// bails, deleting the partial stems. The track keeps playing without stems and re-enters
    /// separation on a later `ensureStems` pass. Cleared when the next separation starts.
    nonisolated(unsafe) private static var abortRequested = false
    private static let abortLock = NSLock()

    static var isAbortRequested: Bool {
        abortLock.lock(); defer { abortLock.unlock() }
        return abortRequested
    }

    static func requestAbort() {
        abortLock.lock(); abortRequested = true; abortLock.unlock()
    }

    static func clearAbort() {
        abortLock.lock(); abortRequested = false; abortLock.unlock()
    }

    private static func sharedSession(modelURL: URL) throws -> ORTSession {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        if let cached = cachedSession, cached.path == modelURL.path { return cached.session }
        // Last-chance gate immediately before the load peak — callers also check, but download
        // / queue wait can leave headroom far below requiredStartMB by the time we get here.
        let headroom = MemoryFootprint.headroomMB
        guard headroom > StemSeparationBudget.requiredStartMB else {
            throw StemSeparationError.inference(
                "session load deferred: \(headroom) MB headroom < \(StemSeparationBudget.requiredStartMB) MB")
        }
        do {
            MemoryFootprint.breadcrumb("ort session load begin")
            let env = try ORTEnv(loggingLevel: .warning)
            let options = try ORTSessionOptions()
            // Cap thread fan-out: default parallel arenas on a phone balloon RSS toward the
            // ~3.4 GB per-process jetsam limit when loading HT-Demucs. One intra-op thread is
            // plenty for an offline cache-once job.
            try options.setIntraOpNumThreads(1)
            try options.addConfigEntry(withKey: "session.intra_op.allow_spinning", value: "0")
            // Prepacking rewrites weights into kernel-friendly layouts as ADDITIONAL copies —
            // for an 85M-param transformer that's hundreds of MB of duplicated RSS for a
            // marginal speedup on an offline cache-once job. Keeping the originals only.
            try options.addConfigEntry(withKey: "session.disable_prepacking", value: "1")
            // NO graph optimization. Measured on device (mem breadcrumbs): session creation
            // alone blew through >3.3 GB of headroom and jetsammed the app before "ort session
            // ready". Mechanism: this model stores fp16 weights behind per-weight Cast nodes,
            // and load-time constant folding materializes an fp32 copy of EVERY weight while
            // the protobuf and the fp16 originals are still resident — several full copies of
            // an 85M-param model at once. Skipping optimization trades some per-window CPU
            // (fine for an offline cache-once job) for a load peak that actually fits.
            try options.setGraphOptimizationLevel(ORTGraphOptimizationLevel.none)
            // HARD RULE: CPU EP only. Never add the CoreML execution provider here — session
            // creation alone jetsammed past the per-process limit (~3.4 GB). A real Core ML
            // `.mlpackage` path lives in `CoreMLStemSeparator` (Phase 3a spike), not ORT EP.
            let session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: options)
            cachedSession = (modelURL.path, session)
            MemoryFootprint.breadcrumb("ort session ready")
            return session
        } catch {
            throw StemSeparationError.inference("session: \(error)")
        }
    }

    func separate(inputURL: URL, vocalsOut: URL, accompanimentOut: URL) throws -> StemPaths {
        Self.clearAbort()   // a stale warning must not kill this fresh attempt
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

        return try StemStreamingEngine.separate(
            inputURL: inputURL,
            vocalsOut: vocalsOut,
            accompanimentOut: accompanimentOut,
            runWindow: runWindow,
            shouldAbort: { Self.isAbortRequested },
            onWindow: { windowCount in
                if windowCount % 10 == 0 {
                    MemoryFootprint.breadcrumb("window \(windowCount)")
                }
            })
    }

    /// Wraps the ORT session as a per-window inference closure. Output shape (1, 4, 2, segment);
    /// returns just the vocals source (index 3) as planar (2, segment).
    private static func ortInference(session: ORTSession, segment: Int,
                                     channels: Int, vocalsIndex: Int) -> WindowInference {
        // Shrink the CPU arena back after every Run: the transformer's attention intermediates
        // spike the arena to its high-water mark, and by default ORT never returns that memory
        // between windows — it sits on top of live playback for the whole track (jetsam margin).
        // Re-growing per window costs a little CPU; an offline cache-once job can afford it.
        let runOptions = try? ORTRunOptions()
        try? runOptions?.addConfigEntry(withKey: "memory.enable_memory_arena_shrinkage", value: "cpu:0")
        let mixName = StemWindowSpec.mixInputName
        let stemsName = StemWindowSpec.stemsOutputName
        return { input in
            let inputData = input.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress, length: $0.count) }
            do {
                let inputValue = try ORTValue(tensorData: inputData, elementType: .float,
                                              shape: [1, NSNumber(value: channels), NSNumber(value: segment)])
                let outputs = try session.run(withInputs: [mixName: inputValue],
                                              outputNames: [stemsName], runOptions: runOptions)
                guard let out = outputs[stemsName] else { throw StemSeparationError.inference("no '\(stemsName)' output") }
                let outData = try out.tensorData() as Data
                let vocBase = (vocalsIndex * channels) * segment
                let count = channels * segment
                let neededBytes = (vocBase + count) * MemoryLayout<Float>.size
                guard outData.count >= neededBytes else {
                    throw StemSeparationError.inference(
                        "short stems tensor: \(outData.count) bytes, need \(neededBytes)")
                }
                return outData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    let f = raw.bindMemory(to: Float.self)
                    // Count was checked above; baseAddress is non-nil for a non-empty buffer.
                    return Array(UnsafeBufferPointer(start: f.baseAddress! + vocBase, count: count))
                }
            } catch let e as StemSeparationError {
                throw e
            } catch {
                throw StemSeparationError.inference("run: \(error)")
            }
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
