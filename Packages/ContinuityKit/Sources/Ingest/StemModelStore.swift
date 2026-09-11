import Foundation

/// Ensures the stem-separation ONNX model is on disk (downloaded once from HuggingFace), returning
/// its local URL. The model is ~158 MB so it's fetched lazily into the cache, not bundled in the app.
enum StemModelStore {
    /// HT-Demucs FT "vocals specialist", fp16 weights (~158 MB), MIT-licensed.
    static let remoteURL = URL(string: "https://huggingface.co/StemSplitio/htdemucs-ft-vocals-onnx/resolve/main/htdemucs_ft_vocals_fp16weights.onnx")!
    static let fileName = "htdemucs_ft_vocals_fp16weights.onnx"

    /// Memoized like the other cache directories — `localURL` and `isDownloaded` read it, and
    /// as a computed property each read ran a `createDirectory` + `setResourceValues` pair.
    static let directory: URL = {
        // Application Support, not Caches: the OS evicts Caches under storage pressure, and a
        // silently re-downloaded 158 MB model at play time is both a delay and a memory/network
        // spike stacked exactly on playback start (see the jetsam RCA). Excluded from backup —
        // large and re-derivable.
        var dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StemModel", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }()

    /// Floor for "this file is plausibly the model" (it is ~158 MB). Anything under this is a
    /// truncated transfer or an error page served with a 200 — never something to hand to ONNX
    /// Runtime as a protobuf.
    private static let minimumPlausibleBytes: Int64 = 100_000_000

    /// Pre-move location (Caches). Checked once so existing installs don't re-download.
    private static var legacyURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StemModel", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    static var localURL: URL { directory.appendingPathComponent(fileName) }
    static var isDownloaded: Bool { FileManager.default.fileExists(atPath: localURL.path) }

    /// Returns the local model URL, downloading it first if needed.
    ///
    /// The download is validated before it is committed. A network path change mid-transfer —
    /// a cell/Wi-Fi handoff while walking, which is exactly when this 158 MB fetch is most
    /// likely to be interrupted — can land a short file, and a captive portal can answer with
    /// an HTML page under a 200. Either one, cached as "the model", is then fed to ONNX Runtime
    /// as a protobuf on every future separation and fails (or worse) forever.
    static func ensureModel() async throws -> URL {
        if isDownloaded {
            if isPlausibleModel(at: localURL) { return localURL }
            // An earlier run cached something that isn't the model. Drop it and re-fetch.
            try? FileManager.default.removeItem(at: localURL)
        }
        // Migrate a surviving Caches copy instead of re-downloading it.
        if FileManager.default.fileExists(atPath: legacyURL.path),
           isPlausibleModel(at: legacyURL),
           (try? FileManager.default.moveItem(at: legacyURL, to: localURL)) != nil {
            return localURL
        }
        let (temp, response) = try await URLSession.shared.download(from: remoteURL)
        defer { try? FileManager.default.removeItem(at: temp) }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw StemSeparationError.inference("model download HTTP \(http.statusCode)")
        }
        let downloadedBytes = fileSize(at: temp)
        // Short of what the server promised means the transfer was cut off. Larger is fine —
        // a content-encoded response decodes bigger than its declared length.
        let expected = response.expectedContentLength
        if expected > 0, downloadedBytes < expected {
            throw StemSeparationError.inference(
                "model download truncated: \(downloadedBytes) of \(expected) bytes")
        }
        guard downloadedBytes >= minimumPlausibleBytes else {
            throw StemSeparationError.inference("model download too small: \(downloadedBytes) bytes")
        }
        do {
            try FileManager.default.moveItem(at: temp, to: localURL)
        } catch {
            // Another concurrent download may have won the race.
            if isDownloaded { return localURL }
            throw StemSeparationError.inference("model move: \(error)")
        }
        return localURL
    }

    private static func isPlausibleModel(at url: URL) -> Bool {
        fileSize(at: url) >= minimumPlausibleBytes
    }

    private static func fileSize(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }
}
