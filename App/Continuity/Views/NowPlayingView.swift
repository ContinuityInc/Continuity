import SwiftUI

/// Full-screen Now Playing UI (Apple Music / Spotify style): large artwork, scrubber, and a
/// Liquid Glass transport. The "transition" chip near the top is a teaser for the flagship
/// feature; it becomes interactive once the engine lands in M2+.
struct NowPlayingView: View {
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss

    @State private var isEditing = false
    @State private var scrubValue: Double = 0

    private let settings = TransitionSettings.default

    var body: some View {
        VStack(spacing: 24) {
            grabberSpacer

            transitionChip

            if let track = player.currentTrack {
                ArtworkView(symbol: track.artworkSymbol, seed: track.gradientSeed, cornerRadius: 28)
                    .frame(maxWidth: 320)
                    .aspectRatio(1, contentMode: .fit)
                    .shadow(color: .black.opacity(0.25), radius: 24, y: 12)
                    .padding(.horizontal, 32)

                VStack(spacing: 4) {
                    Text(track.title).font(.title2.bold()).lineLimit(1)
                    Text(track.artist).font(.title3).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            scrubber
            transport

            Spacer(minLength: 0)
        }
        .padding(.top, 12)
        .background(backdrop)
    }

    private var grabberSpacer: some View {
        Color.clear.frame(height: 8)
    }

    private var transitionChip: some View {
        Label("\(Int(settings.durationSeconds))s · \(settings.curve.rawValue)", systemImage: "wand.and.stars")
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .continuityGlass(cornerRadius: 20)
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
