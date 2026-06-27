import SwiftUI
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
                        }
                        Slider(
                            value: $player.transitionSettings.durationSeconds,
                            in: 0...16,
                            step: 1
                        )
                    }
                    .accessibilityElement(children: .combine)

                    // Curve picker, mapping the verified ContinuityCore enum to friendly labels.
                    Picker("Curve", selection: $player.transitionSettings.curve) {
                        ForEach(CrossfadeCurve.allCases, id: \.self) { curve in
                            Text(displayName(for: curve)).tag(curve)
                        }
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("Crossfade")
                } footer: {
                    Text("0s = hard cut. Equal Power keeps perceived loudness steady through the blend.")
                }

                // MARK: Mixing (present but disabled — full vision, wired up in M3/M4)
                Section {
                    // Beatmatching — M3
                    Toggle("Beatmatching", isOn: $player.transitionSettings.beatmatchEnabled)
                        .disabled(true)

                    // Harmonic mixing — M3
                    Toggle("Harmonic Mixing", isOn: $player.transitionSettings.harmonicMixingEnabled)
                        .disabled(true)

                    // Vocal handling — M4 (stem-aware)
                    Picker("Vocals", selection: $player.transitionSettings.vocalMode) {
                        ForEach(TransitionSettings.VocalMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(true)
                } header: {
                    Text("Mixing (coming soon)")
                } footer: {
                    Text("Beatmatching and harmonic mixing arrive in M3. Stem-aware vocals arrive in M4.")
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
