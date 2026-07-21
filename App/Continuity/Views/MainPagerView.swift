import SwiftUI
import Playback

/// Vertical three-page shell: Library ↑, Now Playing (home), Up Next ↓.
/// Sticky paging — one full screen at a time via `scrollTargetBehavior(.paging)`.
/// From home, scroll up for Library and down for Up Next. Nested library/queue lists keep
/// their own scroll; jump home via the mini player, chevrons, or starting playback.
struct MainPagerView: View {
    @State private var pagerState = MainPagerState()
    @Environment(Player.self) private var player

    var body: some View {
        // Full-screen pages: the pager ignores the safe area so each page tiles exactly one
        // screen (no neighbor bleed into the status-bar / home-indicator bands); the measured
        // insets are re-applied per page below.
        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            let pageHeight = proxy.size.height
            ScrollView(.vertical) {
                // Every page gets HARD insets (the pager hides the window safe area, and
                // neither NavigationStack bars nor safe-area piercing behave inside scroll
                // content); full-bleed surfaces are provided as page BACKGROUNDS behind the
                // padding, which cover the whole page frame including the bars.
                VStack(spacing: 0) {
                    // The pages are transparent: a single shared `PagerBackdrop` behind the whole
                    // scroll content supplies every page's surface (flat `systemGroupedBackground`
                    // for Library/Up Next, the album gradient over Now Playing, and the gradient
                    // bleeding halfway into each neighbor). Because that one layer scrolls with the
                    // content, the gradient is continuous across page boundaries — no per-page
                    // seam, no per-frame crossfade state.
                    LibrarySheetView()
                        .padding(.top, insets.top)
                        .padding(.bottom, insets.bottom)
                        .containerRelativeFrame(.vertical)
                        .id(MainPagerState.Page.library)
                    NowPlayingView(mode: .home)
                        .padding(.top, insets.top)
                        .padding(.bottom, insets.bottom)
                        .containerRelativeFrame(.vertical)
                        .id(MainPagerState.Page.nowPlaying)
                    UpNextView()
                        .padding(.top, insets.top)
                        .padding(.bottom, insets.bottom)
                        .containerRelativeFrame(.vertical)
                        .id(MainPagerState.Page.upNext)
                }
                .scrollTargetLayout()
                // One shared backdrop behind all three pages, sized to the full content height
                // (three pages). Static and position-based, so it needs no per-scroll-frame state.
                .background {
                    PagerBackdrop(url: player.currentTrack?.artworkURL,
                                  seed: player.currentTrack?.gradientSeed ?? 0,
                                  pageHeight: pageHeight)
                }
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: pageBinding)
            .scrollIndicators(.hidden)
            // Three equal pages → center lands on Now Playing (the home screen).
            .defaultScrollAnchor(.center)
            // Matches the backdrop's flat fill so overscroll doesn't flash black in light mode.
            .background(Color(uiColor: .systemGroupedBackground))
            .ignoresSafeArea()
        }
        .environment(pagerState)
    }

    /// Bridges `MainPagerState` ↔ `scrollPosition` so chrome (mini player, chevrons, play)
    /// can jump pages programmatically and stay in sync with user scrolling.
    private var pageBinding: Binding<MainPagerState.Page?> {
        Binding(
            get: { pagerState.page },
            set: { newValue in
                if let newValue {
                    pagerState.page = newValue
                }
            }
        )
    }
}

/// Single shared backdrop behind the whole three-page scroll content. It renders the
/// now-playing album gradient at full strength over the center page and bleeds a muted band of
/// the gradient's edge colors halfway into the Library (above) and Up Next (below) pages before
/// settling into the flat `systemGroupedBackground`, so paging between screens never hits a flat
/// wall. Position-based and static: it scrolls WITH the content, so the gradient stays continuous
/// across page boundaries with no seam — and it needs no per-scroll-frame state (the old
/// `scrollFraction` crossfade is gone), keeping heavy views off the per-tick invalidation path.
private struct PagerBackdrop: View {
    let url: URL?
    let seed: Int
    /// One page's height; the backdrop spans three of these (Library, Now Playing, Up Next).
    let pageHeight: CGFloat

    /// Resolved palette for the current artwork; nil until the async render lands. Shares the
    /// per-URL cache with `AlbumBackdrop`, so resolving it here is a cheap cache hit after the
    /// first fetch — and yields the exact same edge colors the backdrop draws.
    @State private var style: BackdropStyle?

    var body: some View {
        let flat = Color(uiColor: .systemGroupedBackground)
        // Edge colors the neighbor extensions continue from the now-playing gradient. While the
        // artwork palette is still resolving (or absent, for demo tracks), fall back to the
        // deterministic seed palette — the same source `AlbumBackdrop` falls back to — so the
        // bleed is ALWAYS present and roughly matches, never a flat gap that pops when art lands.
        let palette = Theme.gradientColors(seed: seed)
        let topEdge = style?.colors.first ?? palette.first ?? flat
        let bottomEdge = style?.colors.last ?? palette.last ?? flat
        // The extensions must meet the backdrop's RENDERED edge, not its raw palette: `AlbumBackdrop`
        // scrims its gradient by black at 0.30 (top) / 0.35 (bottom), so darken the extension
        // endpoints by the same factors to kill the brightness seam at the page boundary. The top
        // edge also carries a 55% blurred-art tint that this flat extension only approximates, so a
        // faint softness may remain at the top boundary (acceptable); the bottom is an exact match.
        let topEdgeScrimmed = topEdge.darkened(by: 0.30)
        let bottomEdgeScrimmed = bottomEdge.darkened(by: 0.35)

        // Tuned for dark mode (primary usage): the extensions are muted edge colors fading out by
        // each neighbor's midpoint, so library/queue text stays legible over them.
        // Light mode may need tuning — the systemGroupedBackground is near-white there.
        ZStack(alignment: .top) {
            // Base flat fill across the full content height (the far halves of the neighbors).
            flat

            // Top extension into the Library page's bottom half [0.5h, 1.0h]: flat at the Library
            // midpoint continuing up to the gradient's TOP edge color at the page boundary.
            LinearGradient(colors: [flat, topEdgeScrimmed], startPoint: .top, endPoint: .bottom)
                .frame(height: pageHeight * 0.5)
                .offset(y: pageHeight * 0.5)

            // Now-playing gradient at FULL strength over the center page [1.0h, 2.0h] — reuses
            // `AlbumBackdrop`, so the now-playing look is unchanged from before.
            AlbumBackdrop(url: url, seed: seed)
                .frame(height: pageHeight)
                .offset(y: pageHeight)

            // Bottom extension into the Up Next page's top half [2.0h, 2.5h]: the gradient's
            // BOTTOM edge color at the page boundary fading to flat by the Up Next midpoint.
            LinearGradient(colors: [bottomEdgeScrimmed, flat], startPoint: .top, endPoint: .bottom)
                .frame(height: pageHeight * 0.5)
                .offset(y: pageHeight * 2)
        }
        .frame(height: pageHeight * 3, alignment: .top)
        .task(id: url) {
            guard let url else { style = nil; return }
            style = await BackdropRenderer.style(for: url)
        }
    }
}

private extension Color {
    /// Mixes the color toward black by `fraction` (0 = unchanged, 1 = black), preserving alpha.
    /// Used to reproduce `AlbumBackdrop`'s black scrim on the flat bleed extensions so their
    /// boundary color matches the composited backdrop edge. Falls back to the original color if
    /// the components can't be resolved.
    func darkened(by fraction: CGFloat) -> Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a) else { return self }
        let scale = 1 - fraction
        return Color(.sRGB, red: r * scale, green: g * scale, blue: b * scale, opacity: a)
    }
}

/// Shared page selection for the vertical shell — injected so library/queue chrome can jump home.
@Observable
@MainActor
final class MainPagerState {
    enum Page: Int, Hashable, CaseIterable {
        case library = 0
        case nowPlaying = 1
        case upNext = 2
    }

    var page: Page = .nowPlaying

    func goToNowPlaying() {
        withAnimation(.snappy(duration: 0.35)) {
            page = .nowPlaying
        }
    }

    func go(to page: Page) {
        withAnimation(.snappy(duration: 0.35)) {
            self.page = page
        }
    }
}
