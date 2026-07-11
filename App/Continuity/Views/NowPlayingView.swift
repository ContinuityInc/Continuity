import SwiftUI

/// Full-screen Now Playing UI (Apple Music / Spotify style): large artwork, scrubber, and a
/// Liquid Glass transport. The "transition" chip near the top is a teaser for the flagship
/// feature; it becomes interactive once the engine lands in M2+.
struct NowPlayingView: View {
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss

    @State private var isEditing = false
    @State private var scrubValue: Double = 0
    @State private var showingTransitionSettings = false

    var body: some View {
        VStack(spacing: 24) {
            grabberSpacer

            transitionChip

            if let track = player.currentTrack {
                RemoteArtworkView(url: track.artworkURL, symbol: track.artworkSymbol, seed: track.gradientSeed, cornerRadius: 28)
                    .frame(maxWidth: 320)
                    .aspectRatio(1, contentMode: .fit)
                    .shadow(color: .black.opacity(0.25), radius: 24, y: 12)
                    .padding(.horizontal, 32)

                VStack(spacing: 4) {
                    Text(track.title).font(.title2.bold()).lineLimit(1)
                    Text(track.artist).font(.title3).foregroundStyle(.secondary).lineLimit(1)
                    if let meta = analysisLabel(for: track) {
                        Text(meta)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                }
            }

            if player.isTransitioning, let next = player.incomingTrack {
                blendIndicator(next: next)
            }

            scrubber
            transport

            Spacer(minLength: 0)
        }
        .padding(.top, 12)
        .animation(.easeInOut, value: player.isTransitioning)
        .background(backdrop)
        // Tapping the transition chip opens the live transition settings.
        .sheet(isPresented: $showingTransitionSettings) {
            TransitionSettingsView()
        }
    }

    private var grabberSpacer: some View {
        Color.clear.frame(height: 8)
    }

    /// Live blend meter shown while a transition is in flight — the flagship feature made visible.
    private func blendIndicator(next: Track) -> some View {
        VStack(spacing: 6) {
            Label("Blending into \(next.title)", systemImage: "arrow.triangle.merge")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            ProgressView(value: min(max(player.transitionProgress, 0), 1))
                .tint(.primary)
        }
        .padding(.horizontal, 40)
        .transition(.opacity)
    }

    /// "124 BPM · 8A" once tempo/key analysis is available — or a "Demo tone" note for the
    /// synthesized sample tracks so they're not mistaken for real playback.
    private func analysisLabel(for track: Track) -> String? {
        if track.isDemo { return "Demo tone" }
        var parts: [String] = []
        if let bpm = track.bpm, bpm > 0 { parts.append("\(Int(bpm.rounded())) BPM") }
        if let camelot = track.camelotCode { parts.append(camelot) }
        if track.hasStems { parts.append("stems") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var transitionChip: some View {
        // Reads live from the Player so the chip reflects edits made in the settings sheet.
        Button {
            showingTransitionSettings = true
        } label: {
            Label(
                "\(Int(player.transitionSettings.durationSeconds))s · \(player.transitionSettings.curve.rawValue)",
                systemImage: "wand.and.stars"
            )
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .continuityGlass(cornerRadius: 20)
        }
        .buttonStyle(.plain)
    }

    private var scrubber: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { isEditing ? scrubValue : player.position },
                    set: { scrubValue = $0 }
                ),
                in: 0...max(player.duration, 0.1),
                onEditingChanged: { editing in
                    if editing {
                        isEditing = true
                        scrubValue = player.position
                    } else {
                        player.seek(to: scrubValue)
                        isEditing = false
                    }
                }
            )
            HStack {
                Text(Theme.time(isEditing ? scrubValue : player.position))
                Spacer()
                Text(Theme.time(player.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 32)
    }

    private var transport: some View {
        HStack(spacing: 28) {
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.title)
            }
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 34))
                    .frame(width: 76, height: 76)
            }
            .buttonStyle(.glassProminent)
            .clipShape(Circle())
            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.title)
            }
        }
        .tint(.primary)
    }

    private var backdrop: some View {
        Group {
            if let track = player.currentTrack {
                Theme.gradient(seed: track.gradientSeed)
                    .opacity(0.22)
                    .ignoresSafeArea()
            }
        }
    }
}
