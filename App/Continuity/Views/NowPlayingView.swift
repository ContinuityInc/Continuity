import SwiftUI
import Playback
import Domain

/// THE Now Playing screen — the app's home page in `MainPagerView` and the only now-playing
/// surface (the old mini-player-expanded sheet is gone; the mini player jumps here instead).
/// Large artwork, title/artist + analysis meta, the live transition visualization, scrubber,
/// the ring transport, and a transition-settings chip. Library and Up Next are sticky vertical
/// neighbors (scroll up / down), with chevron affordances for discoverability.
struct NowPlayingView: View {
    @Environment(Player.self) private var player
    @Environment(MainPagerState.self) private var pagerState

    @State private var showingTransitionSettings = false

    var body: some View {
        // No backdrop here: MainPagerView supplies AlbumBackdrop as the page BACKGROUND
        // (behind the safe-area padding) so the blur fills the physical screen.
        VStack(spacing: 20) {
            // Top spacer clears the Library chevron overlay; bottom one reserves the band the
            // vote bar + Up Next chevron overlays float in, so the column never collides.
            Spacer(minLength: 44)

            if let track = player.currentTrack {
                artworkTile(for: track)
            }

            trackLabel

            // Live blend graph while a transition is in flight, or a preview + countdown of
            // the next scheduled blend.
            TransitionSection()

            if player.currentTrack != nil {
                ScrubberBar()
            }

            transport
                .padding(.top, 2)

            transitionChip

            Spacer(minLength: 96)
        }
        .padding(.horizontal, 24)
        // Greedy on purpose: the backdrop used to be the layer that stretched this page to
        // full height; without it the column hugs its content and the page collapses to a
        // centered band (with the chevron overlays piling onto the transport).
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut, value: player.isTransitioning)
        .overlay(alignment: .top) {
            pageChevron(
                system: "chevron.compact.up",
                label: "Library",
                accessibility: "Library"
            ) {
                pagerState.go(to: .library)
            }
            .padding(.top, 8)
        }
        .overlay(alignment: .bottom) {
            pageChevron(
                system: "chevron.compact.down",
                label: "Up Next",
                accessibility: "Up Next",
                labelAboveIcon: true
            ) {
                pagerState.go(to: .upNext)
            }
            .padding(.bottom, 12)
        }
        // Transient thumbs for the blend in flight (or just finished) — floats above the Up
        // Next chevron so the centered column never reflows when it appears.
        .overlay(alignment: .bottom) {
            TransitionVoteBar()
                .padding(.bottom, 72)
        }
        .sheet(isPresented: $showingTransitionSettings) {
            TransitionSettingsView()
        }
    }

    // MARK: Artwork

    private func artworkTile(for track: Track) -> some View {
        RemoteArtworkView(url: track.artworkURL, symbol: track.artworkSymbol, seed: track.gradientSeed, cornerRadius: 28, cropsLetterbox: true)
            .frame(maxWidth: 280)
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
    }

    // MARK: Now-playing label

    /// Title/artist plus the analysis meta line; a quiet "Not Playing" when nothing's staged.
    @ViewBuilder private var trackLabel: some View {
        VStack(spacing: 4) {
            if let track = player.currentTrack {
                Text(track.title).font(.title2.bold()).foregroundStyle(.white)
                Text(track.artist).font(.title3).foregroundStyle(.white.opacity(0.72))
                if let meta = analysisLabel(for: track) {
                    Text(meta)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.top, 2)
                }
            } else {
                Text("Not Playing")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
            }
        }
        .lineLimit(1)
        .multilineTextAlignment(.center)
        .shadow(color: .black.opacity(0.4), radius: 10, y: 3)
        .animation(.easeInOut(duration: 0.3), value: player.currentTrack?.id)
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

    // MARK: Transport

    /// Bare 60pt glyphs around the big ring disc, skip budget as a pill under Next.
    private var transport: some View {
        HStack(spacing: 48) {
            // Previous — unlimited, so no counter.
            controlGlyph("backward.fill") { player.previous() }

            playButton

            // Next — spends one of the limited forward skips; the remaining count rides below it.
            skipGated(controlGlyph("forward.fill") { player.next() }, disabledOpacity: 0.3)
                .overlay(alignment: .bottom) { skipBadge.offset(y: 30) }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
    }

    /// Shared forward-skip budget wiring: Next greys out and locks once the budget is spent.
    private func skipGated<V: View>(_ next: V, disabledOpacity: Double) -> some View {
        next
            .disabled(player.skipsRemaining == 0)
            .opacity(player.skipsRemaining == 0 ? disabledOpacity : 1)
    }

    private var discGradient: LinearGradient {
        LinearGradient(
            colors: [Color.accentColor, Color.accentColor.opacity(0.78)],
            startPoint: .top, endPoint: .bottom)
    }

    private func playPauseGlyph(size: CGFloat) -> some View {
        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(.white)
            .contentTransition(.symbolEffect(.replace))
            .offset(x: player.isPlaying ? 0 : 2)   // optically centre the play triangle
    }

    /// Play/pause: accent disc with a soft glow, wrapped by a thin track-progress ring.
    private var playButton: some View {
        Button {
            player.togglePlayPause()
        } label: {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.16), lineWidth: 3)
                TrackProgressRing()
                Circle()
                    .fill(discGradient)
                    .padding(9)
                    .shadow(color: Color.accentColor.opacity(0.55), radius: 18, y: 6)
                playPauseGlyph(size: 34)
            }
            .frame(width: 108, height: 108)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
    }

    /// A plain white transport glyph with a comfortable tap target.
    private func controlGlyph(_ system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 30, weight: .medium))
                .frame(width: 60, height: 60)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    /// Remaining forward skips, as a subtle glass pill under Next.
    private var skipBadge: some View {
        Text("\(player.skipsRemaining)")
            .font(.caption.weight(.bold).monospacedDigit())
            .foregroundStyle(.white.opacity(0.9))
            .padding(.vertical, 3)
            .padding(.horizontal, 9)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
            .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
            .accessibilityLabel("\(player.skipsRemaining) skips remaining")
    }

    // MARK: Transition settings chip

    /// Opens the live transition configuration. Reads from the Player so the label reflects
    /// edits made in the settings sheet the moment it closes.
    private var transitionChip: some View {
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
            .frame(height: 34)
            .continuityGlass(cornerRadius: 20, interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Transition settings")
    }

    // MARK: Page chevrons

    /// Subtle scroll affordances — replace the old corner sheet buttons, and stay tappable for
    /// VoiceOver / discoverability when the swipe gesture isn't obvious.
    private func pageChevron(
        system: String,
        label: String,
        accessibility: String,
        labelAboveIcon: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            let icon = Image(systemName: system)
                .font(.title2.weight(.semibold))
            let text = Text(label)
                .font(.caption2.weight(.semibold))
            Group {
                if labelAboveIcon {
                    VStack(spacing: 2) { text; icon }
                } else {
                    VStack(spacing: 2) { icon; text }
                }
            }
            .foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibility)
    }
}

// MARK: - 20 Hz leaf views

/// These leaves are the ONLY readers of `player.position` on this screen. @Observable tracks
/// dependencies per view body, so confining the 20 Hz playback ticks to these tiny bodies keeps
/// the rest of the page — including the full-screen backdrop — from re-evaluating twenty times
/// a second (the render churn identified in the playback jetsam RCA).
private struct TrackProgressRing: View {
    @Environment(Player.self) private var player

    var body: some View {
        // displayProgress morphs across blends, so the ring glides into the next song.
        let progress = player.displayProgress
        Circle()
            .trim(from: 0, to: progress)
            .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .animation(.linear(duration: 0.25), value: progress)
    }
}

private struct ScrubberBar: View {
    @Environment(Player.self) private var player
    @State private var isEditing = false
    @State private var scrubValue: Double = 0

    var body: some View {
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
        .padding(.horizontal, 8)
    }
}

/// Leaf: the screen's only reader of the 20 Hz-derived blend state.
private struct TransitionSection: View {
    @Environment(Player.self) private var player

    var body: some View {
        if player.isTransitioning, let next = player.incomingTrack, let current = player.currentTrack {
            TransitionVisualizationView(
                settings: player.transitionSettings,
                outgoing: current,
                incoming: next,
                isLive: true,
                liveProgress: min(max(player.transitionProgress, 0), 1),
                secondsUntil: nil
            )
            .transition(.opacity)
        } else if let current = player.currentTrack, let next = player.upcomingTracks.first {
            TransitionVisualizationView(
                settings: player.transitionSettings,
                outgoing: current,
                incoming: next,
                isLive: false,
                liveProgress: 0,
                secondsUntil: player.secondsUntilTransition
            )
            .transition(.opacity)
        }
    }
}
