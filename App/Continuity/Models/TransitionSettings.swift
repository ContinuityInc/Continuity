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
    /// Level tracks to a common loudness so blends don't lurch between quiet and loud masters.
    var loudnessLevelingEnabled: Bool = true

    static let `default` = TransitionSettings()
}

extension TransitionSettings {
    private enum CodingKeys: String, CodingKey {
        case durationSeconds, curve, trimSilenceEnabled, beatmatchEnabled, bassSwapEnabled,
             harmonicMixingEnabled, vocalMode, loudnessLevelingEnabled
    }

    /// Field-by-field decoding with defaults, so settings saved by an older build survive new
    /// fields being added (a strict decode would throw and reset everything to defaults).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TransitionSettings.default
        durationSeconds = (try? c.decodeIfPresent(Double.self, forKey: .durationSeconds)) ?? nil ?? d.durationSeconds
        curve = (try? c.decodeIfPresent(CrossfadeCurve.self, forKey: .curve)) ?? nil ?? d.curve
        trimSilenceEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .trimSilenceEnabled)) ?? nil ?? d.trimSilenceEnabled
        beatmatchEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .beatmatchEnabled)) ?? nil ?? d.beatmatchEnabled
        bassSwapEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .bassSwapEnabled)) ?? nil ?? d.bassSwapEnabled
        harmonicMixingEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .harmonicMixingEnabled)) ?? nil ?? d.harmonicMixingEnabled
        vocalMode = (try? c.decodeIfPresent(VocalMode.self, forKey: .vocalMode)) ?? nil ?? d.vocalMode
        loudnessLevelingEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .loudnessLevelingEnabled)) ?? nil ?? d.loudnessLevelingEnabled
    }

    private static let defaultsKey = "transitionSettings.v1"

    /// The persisted settings from the last session, or defaults on first launch / decode failure
    /// (e.g. after a schema change — defaults beat crashing or half-applied state).
    static func loadPersisted() -> TransitionSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(TransitionSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    /// Saves for the next launch. Cheap (a small JSON blob) — called on every edit.
    func persist() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
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
