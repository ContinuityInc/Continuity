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
                            AlbumBackdrop(url: player.currentTrack?.artworkURL,
                                          seed: player.currentTrack?.gradientSeed ?? 0)
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
