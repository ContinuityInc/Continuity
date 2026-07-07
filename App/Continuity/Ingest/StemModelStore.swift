import Foundation

/// Ensures the stem-separation ONNX model is on disk (downloaded once from HuggingFace), returning
/// its local URL. The model is ~158 MB so it's fetched lazily into the cache, not bundled in the app.
enum StemModelStore {
    /// HT-Demucs FT "vocals specialist", fp16 weights (~158 MB), MIT-licensed.
    static let remoteURL = URL(string: "https://huggingface.co/StemSplitio/htdemucs-ft-vocals-onnx/resolve/main/htdemucs_ft_vocals_fp16weights.onnx")!
    static let fileName = "htdemucs_ft_vocals_fp16weights.onnx"

    static var directory: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StemModel", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var localURL: URL { directory.appendingPathComponent(fileName) }
    static var isDownloaded: Bool { FileManager.default.fileExists(atPath: localURL.path) }

    /// Returns the local model URL, downloading it first if needed.
    static func ensureModel() async throws -> URL {
        if isDownloaded { return localURL }
        let (temp, response) = try await URLSession.shared.download(from: remoteURL)
        defer { try? FileManager.default.removeItem(at: temp) }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw StemSeparationError.inference("model download HTTP \(http.statusCode)")
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
}
