/// Shared HT-Demucs FT vocals-specialist window contract used by every stem backend
/// (ORT today, Core ML `.mlpackage` candidate in the Phase 3a spike).
///
/// Keeping these numbers in ContinuityCore means Linux CI can pin the overlap-add /
/// quality harness without importing AVFoundation or onnxruntime. Backends that
/// disagree with this contract are not A/B-comparable under `StemSeparationBudget`.
public enum StemWindowSpec {
    /// Model sample rate. Decode + encode always resample to this.
    public static let sampleRate: Double = 44_100

    /// Fixed input length the exported ONNX / Core ML graphs expect (~7.8 s).
    public static let segmentFrames = 343_980

    /// Overlap as a fraction of `segmentFrames` (Demucs `apply_model` default = 0.25).
    public static let overlapFraction: Double = 0.25

    public static var overlapFrames: Int { segmentFrames / 4 }

    public static var strideFrames: Int { segmentFrames - overlapFrames }

    public static let channelCount = 2

    /// Full Demucs source count even for the vocals specialist (other rows are weak by-products).
    public static let sourceCount = 4

    /// Index of the vocals row in `[drums, bass, other, vocals]`.
    public static let vocalsSourceIndex = 3

    /// ONNX / Core ML tensor names for the StemSplitio vocals-specialist export.
    public static let mixInputName = "mix"
    public static let stemsOutputName = "stems"

    /// Soft cap matching the production separator — transitions only need song-length stems.
    public static let maxSeparationSeconds: Double = 1_800
}
