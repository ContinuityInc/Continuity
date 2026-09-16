import SwiftUI
import Playback

/// Compact Liquid Glass now-playing bar docked above the bottom safe area.
/// The whole bar is one button that jumps the pager home to Now Playing; play/pause and
/// skip stay as inner buttons, which win the tap on their own frames.
struct MiniPlayerView: View {
    @Environment(Player.self) private var player
    @Environment(MainPagerState.self) private var pagerState

    var body: some View {
        Button {
            pagerState.goToNowPlaying()
        } label: {
            barContent
        }
        .buttonStyle(.plain)
        .accessibilityLabel(player.currentTrack.map { "\($0.title) by \($0.artist)" } ?? "Now Playing")
        .accessibilityHint("Opens Now Playing")
    }

    private var barContent: some View {
        HStack(spacing: 12) {
            if let track = player.currentTrack {
                RemoteArtworkView(url: track.artworkURL, symbol: track.artworkSymbol, seed: track.gradientSeed, cornerRadius: 8)
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Next")
                .disabled(player.skipsRemaining == 0)
                .opacity(player.skipsRemaining == 0 ? 0.35 : 1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .continuityGlass(cornerRadius: 18, interactive: true)
        // The glass shape is the tap target — without this, only the bar's subviews hit-test.
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        // Thin play-progress line hugging the bottom edge of the glass bar.
        .overlay(alignment: .bottomLeading) {
            MiniProgressLine()
        }
    }
}

/// The bottom dock every library screen shares: the mini player while something is staged, or
/// a plain chevron back to Now Playing when idle.
///
/// Attach it PER SCREEN (library root and each pushed destination) via `.miniPlayerDock()`:
/// a `safeAreaInset` added outside the NavigationStack does not reach pushed destinations, so
/// their lists scrolled underneath the bar (the "mini player covers the last row" bug).
struct MiniPlayerDock: View {
    @Environment(Player.self) private var player
    @Environment(MainPagerState.self) private var pagerState

    var body: some View {
        if player.currentTrack != nil {
            MiniPlayerView()
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
        } else {
            Button {
                pagerState.goToNowPlaying()
            } label: {
                Image(systemName: "chevron.compact.down")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Now Playing")
        }
    }
}

extension View {
    /// Docks the shared mini player above this screen's bottom edge and insets its scroll
    /// content by the dock's height. Apply to each screen inside the library NavigationStack.
    func miniPlayerDock() -> some View {
        safeAreaInset(edge: .bottom) { MiniPlayerDock() }
    }
}

/// Leaf view: the mini player's only `player.position` reader, so the 20 Hz playback ticks
/// re-evaluate just this line — not the whole bar (artwork row included) inside the
/// always-mounted library page.
private struct MiniProgressLine: View {
    @Environment(Player.self) private var player

    var body: some View {
        // displayProgress morphs across blends, so the line glides into the next song.
        let progress = player.displayProgress
        GeometryReader { geo in
            Capsule()
                .fill(Color.accentColor)
                .frame(width: max(0, geo.size.width * progress), height: 2.5)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(height: 2.5)
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
        .allowsHitTesting(false)
    }
}
