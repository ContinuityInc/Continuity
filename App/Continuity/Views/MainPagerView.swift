import SwiftUI

/// Vertical three-page shell: Library ↑, Now Playing (home), Up Next ↓.
/// Sticky paging — one full screen at a time via `scrollTargetBehavior(.paging)`.
/// From home, scroll up for Library and down for Up Next. Nested library/queue lists keep
/// their own scroll; jump home via the mini player, chevrons, or starting playback.
struct MainPagerView: View {
    @State private var pagerState = MainPagerState()

    var body: some View {
        // Full-screen pages: the pager ignores the safe area so each page tiles exactly one
        // screen (no neighbor bleed into the status-bar / home-indicator bands), and the real
        // insets are re-injected per page with safeAreaPadding — *additive* safe area, so nav
        // bars, lists, and chevrons inset correctly while full-bleed layers (AlbumBackdrop's
        // ignoresSafeArea) still escape to the screen edges.
        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            ScrollView(.vertical) {
                // Two inset strategies on purpose: the NavigationStack pages need HARD padding —
                // their bars position from the real window safe area, which this full-screen
                // pager ignores, so additive safeAreaPadding leaves the title/toolbar under the
                // status bar. Now Playing keeps safeAreaPadding: its content is pure SwiftUI
                // (chevrons/labels respect it) and its backdrop must escape to full bleed via
                // ignoresSafeArea, which hard padding would block.
                VStack(spacing: 0) {
                    LibrarySheetView()
                        .padding(.top, insets.top)
                        .padding(.bottom, insets.bottom)
                        .containerRelativeFrame(.vertical)
                        .id(MainPagerState.Page.library)
                    NowPlayingView(mode: .home)
                        .safeAreaPadding(insets)
                        .containerRelativeFrame(.vertical)
                        .id(MainPagerState.Page.nowPlaying)
                    UpNextView()
                        .padding(.top, insets.top)
                        .padding(.bottom, insets.bottom)
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
