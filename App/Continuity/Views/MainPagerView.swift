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
                    // background AFTER the padding: it fills the whole page frame, so the
                    // status-bar / home-indicator bands show the page's own surface color
                    // instead of the pager's black.
                    LibrarySheetView()
                        .padding(.top, insets.top)
                        .padding(.bottom, insets.bottom)
                        .background(Color(uiColor: .systemGroupedBackground))
                        .containerRelativeFrame(.vertical)
                        .id(MainPagerState.Page.library)
                    // Backdrop as a page BACKGROUND behind the padding: backgrounds cover the
                    // full padded frame, so the blurred art fills the physical screen —
                    // including the status-bar and home-indicator bands — with no reliance on
                    // safe-area piercing (which doesn't survive inside scroll content; it left
                    // a black band up top). Content keeps additive insets for the chevrons.
                    NowPlayingView(mode: .home)
                        .padding(.top, insets.top)
                        .padding(.bottom, insets.bottom)
                        .background {
                            // The gradient dissolves into the neighbors' opaque background as
                            // the user pages, killing the hard seam. The fade overlay is a
                            // separate leaf view so per-frame `scrollFraction` reads never
                            // invalidate the heavy backdrop / now-playing bodies (jetsam RCA).
                            ZStack {
                                AlbumBackdrop(url: player.currentTrack?.artworkURL,
                                              seed: player.currentTrack?.gradientSeed ?? 0)
                                NowPlayingBackgroundFade()
                            }
                        }
                        .containerRelativeFrame(.vertical)
                        .id(MainPagerState.Page.nowPlaying)
                    UpNextView()
                        .padding(.top, insets.top)
                        .padding(.bottom, insets.bottom)
                        .background(Color(uiColor: .systemGroupedBackground))
                        .containerRelativeFrame(.vertical)
                        .id(MainPagerState.Page.upNext)
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            // Continuous scroll signal for the now-playing → neighbor background crossfade.
            // 1.0 = now-playing centered, 0.0 = library, 2.0 = up-next. Only the tiny
            // `NowPlayingBackgroundFade` leaf reads this, so heavy views don't re-render per frame.
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y
            } action: { _, offsetY in
                guard pageHeight > 0 else { return }
                pagerState.scrollFraction = offsetY / pageHeight
            }
            .scrollPosition(id: pageBinding)
            .scrollIndicators(.hidden)
            // Three equal pages → center lands on Now Playing (the home screen).
            .defaultScrollAnchor(.center)
            .background(Color.black)
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

/// Leaf overlay that dissolves the now-playing album gradient into the neighbors' opaque
/// `systemGroupedBackground` as the user pages, so there's no hard seam. Isolated as its own
/// `View` reading `MainPagerState.scrollFraction` from the environment: because the state is
/// `@Observable`, only this tiny view re-evaluates per scroll frame — the `AlbumBackdrop` and
/// `NowPlayingView` never see `scrollFraction` and so aren't invalidated (jetsam RCA).
private struct NowPlayingBackgroundFade: View {
    @Environment(MainPagerState.self) private var pagerState

    var body: some View {
        // Distance from the now-playing page center: 0 at rest (full gradient), 1 at a neighbor.
        let progress = min(1, abs(pagerState.scrollFraction - 1))
        // The revealed neighbor sits ABOVE when paging to Library (fraction < 1) and BELOW when
        // paging to Up Next — so the neighbor's opaque background abuts the now-playing page at
        // its top or bottom edge respectively. A *uniform* tint (the old approach) darkened the
        // whole backdrop evenly, leaving a crisp step at that page boundary: half-darkened
        // gradient meeting the neighbor's solid fill. Instead dissolve the backdrop into the
        // neighbor's background from the abutting edge inward, as a soft vertical ramp — the
        // boundary is background-on-background (no seam) and the fall-off into the gradient is
        // continuous (no crisp internal line). At rest (progress 0) every stop is clear, so the
        // full artwork gradient shows untouched.
        let towardLibrary = pagerState.scrollFraction < 1
        let neighbor = Color(uiColor: .systemGroupedBackground)
        LinearGradient(
            stops: [
                .init(color: neighbor.opacity(progress), location: 0),
                .init(color: neighbor.opacity(progress * 0.5), location: 0.28),
                .init(color: .clear, location: 0.6),
            ],
            startPoint: towardLibrary ? .top : .bottom,
            endPoint: towardLibrary ? .bottom : .top
        )
        .ignoresSafeArea()
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

    /// Continuous vertical scroll position of the pager, in pages: 1.0 = now-playing centered,
    /// 0.0 = library fully shown, 2.0 = up-next fully shown. Updated every scroll frame; read
    /// only by `NowPlayingBackgroundFade` so heavier views aren't invalidated per tick.
    var scrollFraction: CGFloat = 1

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
