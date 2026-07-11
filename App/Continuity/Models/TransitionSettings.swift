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
    /// Gapless playback: treat a track's last audible moment as its end (skip trailing silence),
    /// and start incoming tracks at their first audible moment. Opt-out; on by default.
    var trimSilenceEnabled: Bool = true
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

/// A named bundle of transition settings for one-tap application in the settings UI.
struct TransitionPreset: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let settings: TransitionSettings
}

extension TransitionSettings {
    /// Built-in starting points, from most seamless to a hard cut.
    static let presets: [TransitionPreset] = [
        TransitionPreset(name: "Smooth", settings: TransitionSettings(
            durationSeconds: 12, curve: .equalPower, beatmatchEnabled: true,
            bassSwapEnabled: true, harmonicMixingEnabled: true, vocalMode: .duck)),
        TransitionPreset(name: "Club", settings: TransitionSettings(
            durationSeconds: 8, curve: .smooth, beatmatchEnabled: true,
            bassSwapEnabled: true, harmonicMixingEnabled: true, vocalMode: .instrumentalOverlap)),
        TransitionPreset(name: "Quick", settings: TransitionSettings(
            durationSeconds: 4, curve: .equalPower, beatmatchEnabled: true,
            bassSwapEnabled: true, harmonicMixingEnabled: true, vocalMode: .hardSwap)),
        TransitionPreset(name: "Radio", settings: TransitionSettings(
            durationSeconds: 2, curve: .equalPower, beatmatchEnabled: false,
            bassSwapEnabled: false, harmonicMixingEnabled: true, vocalMode: .hardSwap)),
        TransitionPreset(name: "Cut", settings: TransitionSettings(
            durationSeconds: 0, curve: .linear, beatmatchEnabled: false,
            bassSwapEnabled: false, harmonicMixingEnabled: true, vocalMode: .hardSwap)),
    ]

    /// Name of the built-in preset matching these settings exactly, if any (for highlighting).
    var matchingPresetName: String? {
        TransitionSettings.presets.first { $0.settings == self }?.name
    }
}
