import Foundation
import ContinuityCore

/// User-facing configuration for the transition engine. M0 only exposes duration + curve in
/// the UI; the remaining switches are wired up across M2–M4. Importing `ContinuityCore` here
/// is deliberate — it links the verified, unit-tested core into the app target.
public struct TransitionSettings: Codable, Equatable, Sendable {
    /// How vocals from the two tracks overlap during a blend.
    public enum VocalMode: String, Codable, CaseIterable, Sendable {
        case hardSwap          // cut outgoing vocals at the swap point
        case duck              // fade outgoing vocals under the incoming track
        case instrumentalOverlap // only overlap instrumentals; vocals never clash (needs stems)

        public var label: String {
            switch self {
            case .hardSwap: return "Hard Swap"
            case .duck: return "Duck"
            case .instrumentalOverlap: return "Instrumental Overlap"
            }
        }
    }

    /// Length of the blend in seconds.
    public var durationSeconds: Double = 8
    /// Crossfade shape (from the verified ContinuityCore curves).
    public var curve: CrossfadeCurve = .equalPower
    /// Gapless playback: treat a track's last audible moment as its end (skip trailing silence),
    /// and start incoming tracks at their first audible moment. Opt-out; on by default.
    public var trimSilenceEnabled: Bool = true
    /// Tempo-sync + beat-align the incoming track to the outgoing one.
    public var beatmatchEnabled: Bool = true
    /// Fade the incoming track's low end in over the blend so the two basslines don't stack
    /// into low-end mud (a low-shelf "bass swap").
    public var bassSwapEnabled: Bool = true
    /// Restrict/queue toward harmonically compatible keys.
    public var harmonicMixingEnabled: Bool = true
    /// How to handle overlapping vocals.
    public var vocalMode: VocalMode = .duck
    /// Level tracks to a common loudness so blends don't lurch between quiet and loud masters.
    public var loudnessLevelingEnabled: Bool = true

    /// Memberwise init, public so other modules (and the presets) can build settings directly.
    public init(
        durationSeconds: Double = 8,
        curve: CrossfadeCurve = .equalPower,
        trimSilenceEnabled: Bool = true,
        beatmatchEnabled: Bool = true,
        bassSwapEnabled: Bool = true,
        harmonicMixingEnabled: Bool = true,
        vocalMode: VocalMode = .duck,
        loudnessLevelingEnabled: Bool = true
    ) {
        self.durationSeconds = durationSeconds
        self.curve = curve
        self.trimSilenceEnabled = trimSilenceEnabled
        self.beatmatchEnabled = beatmatchEnabled
        self.bassSwapEnabled = bassSwapEnabled
        self.harmonicMixingEnabled = harmonicMixingEnabled
        self.vocalMode = vocalMode
        self.loudnessLevelingEnabled = loudnessLevelingEnabled
    }

    public static let `default` = TransitionSettings()
}

extension TransitionSettings {
    private enum CodingKeys: String, CodingKey {
        case durationSeconds, curve, trimSilenceEnabled, beatmatchEnabled, bassSwapEnabled,
             harmonicMixingEnabled, vocalMode, loudnessLevelingEnabled
    }

    /// Field-by-field decoding with defaults, so settings saved by an older build survive new
    /// fields being added (a strict decode would throw and reset everything to defaults).
    public init(from decoder: Decoder) throws {
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
    public static func loadPersisted() -> TransitionSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(TransitionSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    /// Saves for the next launch. Cheap (a small JSON blob) — called on every edit.
    public func persist() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}

extension TransitionSettings {
    /// The engine-side mapping for `TransitionFeedback.simplificationLevel`: each notch backs a
    /// downvoted pair's blend off toward a plain short fade. The ladder drops the most audible
    /// artifacts first — key shifting, then tempo warping, then everything but the crossfade.
    /// Level 0 (and anything unrecognized) returns the settings unchanged.
    public func simplified(level: Int) -> TransitionSettings {
        var s = self
        if level >= 1 {
            s.harmonicMixingEnabled = false
            s.durationSeconds = min(s.durationSeconds, 8)
        }
        if level >= 2 {
            s.beatmatchEnabled = false
            s.durationSeconds = min(s.durationSeconds, 5)
        }
        if level >= 3 {
            s.bassSwapEnabled = false
            s.vocalMode = .hardSwap
            s.durationSeconds = min(s.durationSeconds, 2)
        }
        return s
    }
}

/// A named bundle of transition settings for one-tap application in the settings UI.
public struct TransitionPreset: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    public let settings: TransitionSettings

    public init(name: String, settings: TransitionSettings) {
        self.name = name
        self.settings = settings
    }
}

extension TransitionSettings {
    /// Built-in starting points, from most seamless to a hard cut.
    public static let presets: [TransitionPreset] = [
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
    public var matchingPresetName: String? {
        TransitionSettings.presets.first { $0.settings == self }?.name
    }
}
