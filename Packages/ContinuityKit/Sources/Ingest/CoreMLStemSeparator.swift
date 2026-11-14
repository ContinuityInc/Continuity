import ContinuityCore
import CoreML
import Foundation
import os

/// Phase 3a spike: HT-Demucs FT vocals specialist as a real Core ML `.mlpackage`.
///
/// **Not wired into `PreparationQueue`.** Production still uses `OnnxStemSeparator` until a
/// device A/B under `StemSeparationBudget` proves lower peak RSS *and* acceptable vocal quality.
///
/// Hard rules for this type:
/// - Never an ORT CoreML execution provider — this loads an `.mlpackage` via `MLModel`.
/// - Default compute units are `.cpuAndGPU`. Community HTDemucs conversions report incorrect
///   output on `.all` / ANE; the Mac harness must verify numerical parity before trusting ANE.
/// - Same window contract as ORT (`StemWindowSpec`) and the same abort / release-session /
///   window-floor semantics as `OnnxStemSeparator`.
final class CoreMLStemSeparator: StemSeparating {
    private static let log = Logger(subsystem: "com.continuity.app", category: "CoreMLStemSeparator")

    private let modelURL: URL?
    private let inference: StemStreamingEngine.WindowInference?
    private let computeUnits: MLComputeUnits

    /// Process-wide compiled model cache — mirrors ORT's session cache so back-to-back tracks
    /// don't re-pay compile cost, then `releaseSession()` drops it when the stem queue drains.
    private static let sessionLock = NSLock()
    nonisolated(unsafe) private static var cachedModel: (path: String, model: MLModel)?

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

    static func releaseSession() {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        cachedModel = nil
    }

    init(modelURL: URL, computeUnits: MLComputeUnits = .cpuAndGPU) {
        self.modelURL = modelURL
        self.inference = nil
        self.computeUnits = computeUnits
    }

    /// Test / harness seam: bypass Core ML entirely (same shape as ORT's fake-inference init).
    init(inference: @escaping StemStreamingEngine.WindowInference) {
        self.modelURL = nil
        self.inference = inference
        self.computeUnits = .cpuOnly
    }

    func separate(inputURL: URL, vocalsOut: URL, accompanimentOut: URL) throws -> StemPaths {
        Self.clearAbort()
        let runWindow: StemStreamingEngine.WindowInference
        if let inference {
            runWindow = inference
        } else {
            guard let modelURL, FileManager.default.fileExists(atPath: modelURL.path) else {
                throw StemSeparationError.modelMissing
            }
            let model = try Self.sharedModel(modelURL: modelURL, computeUnits: computeUnits)
            runWindow = Self.coreMLInference(model: model)
        }

        return try StemStreamingEngine.separate(
            inputURL: inputURL,
            vocalsOut: vocalsOut,
            accompanimentOut: accompanimentOut,
            runWindow: runWindow,
            shouldAbort: { Self.isAbortRequested },
            onWindow: { windowCount in
                if windowCount % 10 == 0 {
                    MemoryFootprint.breadcrumb("coreml window \(windowCount)")
                }
            })
    }

    private static func sharedModel(modelURL: URL, computeUnits: MLComputeUnits) throws -> MLModel {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        if let cached = cachedModel, cached.path == modelURL.path { return cached.model }

        let headroom = MemoryFootprint.headroomMB
        guard headroom > StemSeparationBudget.requiredStartMB else {
            throw StemSeparationError.inference(
                "coreml load deferred: \(headroom) MB headroom < \(StemSeparationBudget.requiredStartMB) MB")
        }
        do {
            MemoryFootprint.breadcrumb("coreml model load begin")
            let config = MLModelConfiguration()
            config.computeUnits = computeUnits
            let model = try MLModel(contentsOf: modelURL, configuration: config)
            cachedModel = (modelURL.path, model)
            MemoryFootprint.breadcrumb("coreml model ready units=\(String(describing: computeUnits))")
            return model
        } catch {
            throw StemSeparationError.inference("coreml session: \(error)")
        }
    }

    /// Input planar `(1, 2, segment)` mix → planar `(2, segment)` vocals (source index 3).
    private static func coreMLInference(model: MLModel) -> StemStreamingEngine.WindowInference {
        let segment = StemWindowSpec.segmentFrames
        let channels = StemWindowSpec.channelCount
        let vocalsIndex = StemWindowSpec.vocalsSourceIndex
        let mixName = StemWindowSpec.mixInputName
        let stemsName = StemWindowSpec.stemsOutputName

        return { input in
            do {
                let shape: [NSNumber] = [1, NSNumber(value: channels), NSNumber(value: segment)]
                let array = try MLMultiArray(shape: shape, dataType: .float32)
                let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: input.count)
                for i in 0..<input.count { ptr[i] = input[i] }

                let provider = try MLDictionaryFeatureProvider(
                    dictionary: [mixName: MLFeatureValue(multiArray: array)])
                let out = try model.prediction(from: provider)
                // Accept Continuity names first; fall back to community converter names
                // (`sources` / flattened [1,8,T] from john-rocky / dexxdean exports).
                let stems = out.featureValue(for: stemsName)?.multiArrayValue
                    ?? out.featureValue(for: "sources")?.multiArrayValue
                guard let stems else {
                    throw StemSeparationError.inference("coreml: missing '\(stemsName)'/sources output")
                }

                let count = channels * segment
                let outPtr = stems.dataPointer.bindMemory(to: Float.self, capacity: stems.count)
                // (1, 4, 2, segment) planar — vocals at source index 3.
                let vocBase = vocalsIndex * channels * segment
                if stems.count >= vocBase + count {
                    return Array(UnsafeBufferPointer(start: outPtr + vocBase, count: count))
                }
                // Flattened (1, 8, segment): source s channel c → index s*2+c.
                let flatBase = vocalsIndex * channels * segment
                if stems.count >= flatBase + count {
                    return Array(UnsafeBufferPointer(start: outPtr + flatBase, count: count))
                }
                throw StemSeparationError.inference(
                    "coreml short stems: \(stems.count) floats, need ≥\(vocBase + count)")
            } catch let e as StemSeparationError {
                throw e
            } catch {
                throw StemSeparationError.inference("coreml run: \(error)")
            }
        }
    }
}

/// Application Support store for a converted `.mlpackage` (spike only — not downloaded yet).
/// Production continues to use `StemModelStore` (ONNX). Phase 3b would decide packaging
/// (bundled vs on-demand) after RSS wins.
enum CoreMLStemModelStore {
    static let packageName = "htdemucs_ft_vocals.mlpackage"

    static let directory: URL = {
        var dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StemModelCoreML", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }()

    static var localURL: URL { directory.appendingPathComponent(packageName) }
    static var isPresent: Bool {
        FileManager.default.fileExists(atPath: localURL.path)
    }
}
