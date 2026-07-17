import SwiftUI
import Playback
import Domain
import ContinuityCore

/// Settings screen for the transition engine. Presented as a sheet from the Now Playing
/// "transition chip". M0 actively wires up Crossfade duration + curve; the mixing controls
/// are shown (so the full vision is visible) but disabled until the engine lands in M3/M4.
struct TransitionSettingsView: View {
    // The Player is the single source of truth for the live transition settings.
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // `@Bindable` lets us bind Form controls straight at `player.transitionSettings`.
        @Bindable var player = player

        NavigationStack {
            Form {
                // MARK: Presets — one-tap starting points
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(TransitionSettings.presets) { preset in
                                let isActive = player.transitionSettings.matchingPresetName == preset.name
                                Button {
                                    player.transitionSettings = preset.settings
                                } label: {
                                    Text(preset.name)
                                        .font(.subheadline.weight(.medium))
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 8)
                                        .background(
                                            isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                                            in: Capsule()
                                        )
                                        .foregroundStyle(isActive ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                } header: {
                    Text("Presets")
                } footer: {
                    Text("A starting point — tweak anything below and the highlight clears.")
                }

                // MARK: Crossfade (live — actively edits player.transitionSettings)
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        // Duration label + value, e.g. "Crossfade  8s".
                        HStack {
                            Text("Crossfade")
                            Spacer()
                            Text("\(Int(player.transitionSettings.durationSeconds))s")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .accessibilityHidden(true)
                        }
                        .accessibilityHidden(true)
                        Slider(
                            value: $player.transitionSettings.durationSeconds,
                            in: 0...16,
                            step: 1
                        )
                        // Keep the Slider its own accessibility element — `.combine` on the
                        // VStack collapsed the adjustable trait and blocked VoiceOver swipe-to-change.
                        .accessibilityLabel("Crossfade")
                        .accessibilityValue("\(Int(player.transitionSettings.durationSeconds)) seconds")
                    }

                    // Curve picker, mapping the verified ContinuityCore enum to friendly labels.
                    Picker("Curve", selection: $player.transitionSettings.curve) {
                        ForEach(CrossfadeCurve.allCases, id: \.self) { curve in
                            Text(displayName(for: curve)).tag(curve)
                        }
                    }
                    .pickerStyle(.menu)

                    // Gapless — trim trailing/leading silence so blends never fade into dead air.
                    Toggle("Trim Silence", isOn: $player.transitionSettings.trimSilenceEnabled)
                } header: {
                    Text("Crossfade")
                } footer: {
                    Text("0s = hard cut. Equal Power keeps perceived loudness steady through the blend. Trim Silence starts the transition from the last audible moment instead of fading into a silent tail.")
                }

                // MARK: Mixing
                Section {
                    // Beatmatching — tempo-matches AND beat-aligns tracks with a detected BPM/grid.
                    Toggle("Beatmatching", isOn: $player.transitionSettings.beatmatchEnabled)

                    // Bass swap — fades the incoming low end in so basslines don't stack.
                    Toggle("Bass Swap", isOn: $player.transitionSettings.bassSwapEnabled)

                    // Loudness leveling — every track meets the blend at a common loudness.
                    Toggle("Loudness Leveling", isOn: $player.transitionSettings.loudnessLevelingEnabled)

                    // Harmonic mixing — nudges the incoming track into a Camelot-compatible key.
                    Toggle("Harmonic Mixing", isOn: $player.transitionSettings.harmonicMixingEnabled)

                    // Vocal handling — M4: how vocals overlap (applies once a track's stems exist).
                    Picker("Vocals", selection: $player.transitionSettings.vocalMode) {
                        ForEach(TransitionSettings.VocalMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("Mixing")
                } footer: {
                    Text("Beatmatching tempo-matches and beat-aligns tracks with a detected grid. Bass swap fades the incoming low end in so basslines don't clash. Harmonic mixing nudges the incoming track up to a semitone into a compatible key. Vocal handling shapes how vocals overlap once stems are separated.")
                }
            }
            .navigationTitle("Transition")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// Friendly display names for the raw `CrossfadeCurve` cases.
    private func displayName(for curve: CrossfadeCurve) -> String {
        switch curve {
        case .linear: return "Linear"
        case .equalPower: return "Equal Power"
        case .smooth: return "Smooth"
        }
    }
}
