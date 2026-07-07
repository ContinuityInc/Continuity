import Foundation
import ContinuityCore

/// User-facing configuration for the transition engine. M0 only exposes duration + curve in
/// the UI; the remaining switches are wired up across M2–M4. Importing `ContinuityCore` here
/// is deliberate — it links the verified, unit-tested core into the app target.
struct TransitionSettings: Codable, Equatable, Sendable {
    /// How vocals from the two tracks overlap during a blend.
    enum VocalMode: String, Codable, CaseIterable, Sendable {
        case hardSwap          // cut outgoing vocals at the swap point
        case duck              // fade outgoing vocals under the incoming track
        case instrumentalOverlap // only overlap instrumentals; vocals never clash (needs stems)

        var label: String {
            switch self {
            case .hardSwap: return "Hard Swap"
            case .duck: return "Duck"
            case .instrumentalOverlap: return "Instrumental Overlap"
            }
        }
    }

    /// Length of the blend in seconds.
    var durationSeconds: Double = 8
    /// Crossfade shape (from the verified ContinuityCore curves).
    var curve: CrossfadeCurve = .equalPower
    /// Tempo-sync + beat-align the incoming track to the outgoing one.
    var beatmatchEnabled: Bool = true
    /// Fade the incoming track's low end in over the blend so the two basslines don't stack
    /// into low-end mud (a low-shelf "bass swap").
    var bassSwapEnabled: Bool = true
    /// Restrict/queue toward harmonically compatible keys.
    var harmonicMixingEnabled: Bool = true
    /// How to handle overlapping vocals.
    var vocalMode: VocalMode = .duck

    static let `default` = TransitionSettings()
}
