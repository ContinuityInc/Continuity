import SwiftUI
import Playback
import Domain

/// Full-screen Now Playing UI (Apple Music / Spotify style): large artwork, scrubber, and a
/// Liquid Glass transport. The "transition" chip near the top is a teaser for the flagship
/// feature; it becomes interactive once the engine lands in M2+.
struct NowPlayingView: View {
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss

    @State private var isEditing = false
    @State private var scrubValue: Double = 0
    @State private var showingTransitionSettings = false
    @State private var showingUpNext = false

    var body: some View {
        VStack(spacing: 24) {
            grabberSpacer

            // Transition settings + queue, side by side: both shape what plays next.
            HStack(spacing: 10) {
                transitionChip
                upNextButton
            }

            if let track = player.currentTrack {
                RemoteArtworkView(url: track.artworkURL, symbol: track.artworkSymbol, seed: track.gradientSeed, cornerRadius: 28, cropsLetterbox: true)
                    .frame(maxWidth: 300)
                    .aspectRatio(1, contentMode: .fit)
                    // Playing = full size with a lifted shadow; paused = drawn back, like a record
                    // easing off the platter. The signature "is it playing?" glance cue.
                    .scaleEffect(player.isPlaying ? 1 : 0.84)
                    .shadow(color: .black.opacity(0.45),
                            radius: player.isPlaying ? 32 : 16,
                            y: player.isPlaying ? 18 : 8)
                    .animation(.spring(response: 0.45, dampingFraction: 0.72), value: player.isPlaying)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 6)

                VStack(spacing: 4) {
                    Text(track.title).font(.title2.bold()).foregroundStyle(.white).lineLimit(1)
                    Text(track.artist).font(.title3).foregroundStyle(.white.opacity(0.72)).lineLimit(1)
                    if let meta = analysisLabel(for: track) {
                        Text(meta)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.6))
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
        .sheet(isPresented: $showingUpNext) {
            UpNextView()
                .presentationDetents([.medium, .large])
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
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
            ProgressView(value: min(max(player.transitionProgress, 0), 1))
                .tint(.white)
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
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .continuityGlass(cornerRadius: 20)
        }
        .buttonStyle(.plain)
    }

    /// Glass sibling of the transition chip, opening the Up Next queue sheet.
    private var upNextButton: some View {
        Button {
            showingUpNext = true
        } label: {
            Image(systemName: "list.bullet")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .continuityGlass(cornerRadius: 20)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Up Next")
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
            .tint(.white)
            HStack {
                Text(Theme.time(isEditing ? scrubValue : player.position))
                Spacer()
                Text(Theme.time(player.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.65))
        }
        .padding(.horizontal, 32)
    }

    private var transport: some View {
        HStack(spacing: 28) {
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.title)
            }
            // Accent play disc — same treatment as the minimal home so both surfaces share a look.
            Button { player.togglePlayPause() } label: {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [Color.accentColor, Color.accentColor.opacity(0.78)],
                            startPoint: .top, endPoint: .bottom))
                        .frame(width: 78, height: 78)
                        .shadow(color: Color.accentColor.opacity(0.5), radius: 16, y: 5)
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                        .offset(x: player.isPlaying ? 0 : 2)
                }
            }
            .buttonStyle(.plain)
            VStack(spacing: 4) {
                Button { player.next() } label: {
                    Image(systemName: "forward.fill").font(.title)
                }
                .disabled(player.skipsRemaining == 0)
                .opacity(player.skipsRemaining == 0 ? 0.35 : 1)
                Text("\(player.skipsRemaining)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .tint(.white)
    }

    private var backdrop: some View {
        Group {
            if let track = player.currentTrack {
                AlbumBackdrop(url: track.artworkURL, seed: track.gradientSeed)
            } else {
                Color.black.ignoresSafeArea()
            }
        }
    }
}
