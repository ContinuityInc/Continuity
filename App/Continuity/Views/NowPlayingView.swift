import SwiftUI
import Playback
import Domain

/// The one Now Playing surface, in two modes so both feel like the same room:
/// `.home` is the app's deliberately minimal root — title/artist over the blurred-art backdrop
/// and a progress-ring play disc. Library and Up Next are sticky vertical neighbors in
/// `MainPagerView` (scroll up / down), with chevron affordances for discoverability.
/// `.sheet` is the full detail view — large artwork, transition + queue chips, scrubber, and a
/// live blend meter while a transition is in flight.
struct NowPlayingView: View {
    enum Mode { case home, sheet }
    let mode: Mode

    @Environment(Player.self) private var player
    @Environment(MainPagerState.self) private var pagerState

    // Sheet-mode scrubber state.
    @State private var isEditing = false
    @State private var scrubValue: Double = 0
    @State private var showingTransitionSettings = false
    // Sheet mode opens the queue as a sheet; home uses the vertical pager instead.
    @State private var showingUpNext = false

    var body: some View {
        layout
            .sheet(isPresented: $showingUpNext) {
                UpNextView()
                    .presentationDetents([.medium, .large])
            }
    }

    @ViewBuilder private var layout: some View {
        switch mode {
        case .home: homeLayout
        case .sheet: sheetLayout
        }
    }

    // MARK: Home layout (minimal root)

    private var homeLayout: some View {
        ZStack {
            backdrop

            // Title/artist + transport, as one vertically-centred column.
            VStack(spacing: 34) {
                trackLabel
                transport
            }
            .padding(.horizontal, 24)
        }
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
    }

    // MARK: Sheet layout (full detail)

    private var sheetLayout: some View {
        VStack(spacing: 24) {
            grabberSpacer

            // Transition settings + queue, side by side: both shape what plays next.
            HStack(spacing: 10) {
                transitionChip
                sheetUpNextButton
            }

            if let track = player.currentTrack {
                artworkTile(for: track)
            }
            trackLabel

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

    // MARK: Backdrop

    /// The current track's album art, blurred edge-to-edge behind a depth scrim (black when idle).
    private var backdrop: some View {
        Group {
            if let track = player.currentTrack {
                AlbumBackdrop(url: track.artworkURL, seed: track.gradientSeed)
            } else {
                Color.black.ignoresSafeArea()
            }
        }
    }

    // MARK: Artwork (sheet only)

    private func artworkTile(for track: Track) -> some View {
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
    }

    // MARK: Now-playing label

    /// One label, two voices: home keeps it quiet so the controls stay the focus; the sheet
    /// goes bigger and adds the analysis meta line (and hides entirely when nothing's staged).
    @ViewBuilder private var trackLabel: some View {
        switch mode {
        case .home:
            VStack(spacing: 5) {
                Text(player.currentTrack?.title ?? "Not Playing")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                Text(player.currentTrack?.artist ?? " ")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.72))
            }
            .lineLimit(1)
            .multilineTextAlignment(.center)
            .shadow(color: .black.opacity(0.4), radius: 10, y: 3)
            .animation(.easeInOut(duration: 0.3), value: player.currentTrack?.id)
        case .sheet:
            if let track = player.currentTrack {
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
        }
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

    /// How far through the track we are (0…1), drives the home ring around Play.
    private var progress: Double {
        guard player.duration > 0 else { return 0 }
        return min(max(player.position / player.duration, 0), 1)
    }

    /// One transport, two densities: home = bare 60pt glyphs around the big ring disc, skip
    /// budget as a pill under Next; sheet = title glyphs around the compact disc, skip budget
    /// as a count below. The accent disc and skip-budget wiring are shared.
    @ViewBuilder private var transport: some View {
        switch mode {
        case .home:
            HStack(spacing: 48) {
                // Previous — unlimited, so no counter.
                controlGlyph("backward.fill") { player.previous() }

                homePlayButton

                // Next — spends one of the limited forward skips; the remaining count rides below it.
                skipGated(controlGlyph("forward.fill") { player.next() }, disabledOpacity: 0.3)
                    .overlay(alignment: .bottom) { skipBadge.offset(y: 30) }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
        case .sheet:
            HStack(spacing: 28) {
                Button { player.previous() } label: {
                    Image(systemName: "backward.fill").font(.title)
                }
                sheetPlayButton
                VStack(spacing: 4) {
                    skipGated(
                        Button { player.next() } label: {
                            Image(systemName: "forward.fill").font(.title)
                        },
                        disabledOpacity: 0.35
                    )
                    Text("\(player.skipsRemaining)")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .tint(.white)
        }
    }

    /// Shared forward-skip budget wiring: Next greys out and locks once the budget is spent.
    private func skipGated<V: View>(_ next: V, disabledOpacity: Double) -> some View {
        next
            .disabled(player.skipsRemaining == 0)
            .opacity(player.skipsRemaining == 0 ? disabledOpacity : 1)
    }

    /// The accent gradient both play discs share, so the two surfaces read as one control.
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

    /// Home play/pause: accent disc with a soft glow, wrapped by a thin track-progress ring.
    private var homePlayButton: some View {
        Button {
            player.togglePlayPause()
        } label: {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.16), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.25), value: progress)
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

    /// Sheet play/pause: the same accent disc, compact and ringless.
    private var sheetPlayButton: some View {
        Button { player.togglePlayPause() } label: {
            ZStack {
                Circle()
                    .fill(discGradient)
                    .frame(width: 78, height: 78)
                    .shadow(color: Color.accentColor.opacity(0.5), radius: 16, y: 5)
                playPauseGlyph(size: 32)
            }
        }
        .buttonStyle(.plain)
    }

    /// A plain white transport glyph with a comfortable tap target (home).
    private func controlGlyph(_ system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 30, weight: .medium))
                .frame(width: 60, height: 60)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    /// Remaining forward skips, as a subtle glass pill under Next (home).
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

    // MARK: Page chevrons (home only)

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

    // MARK: Chips (sheet only)

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
            // Fixed height keeps the chip and its icon-only sibling identical — text and glyph
            // have different intrinsic heights, so padding alone misaligns the pair.
            .frame(height: 34)
            .continuityGlass(cornerRadius: 20)
        }
        .buttonStyle(.plain)
    }

    /// Glass sibling of the transition chip, opening the Up Next queue sheet.
    private var sheetUpNextButton: some View {
        Button {
            showingUpNext = true
        } label: {
            Image(systemName: "list.bullet")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .continuityGlass(cornerRadius: 20)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Up Next")
    }

    // MARK: Blend indicator (sheet only)

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

    // MARK: Scrubber (sheet only)

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
}
