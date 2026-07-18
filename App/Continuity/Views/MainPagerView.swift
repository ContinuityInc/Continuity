import SwiftUI

/// Vertical three-page shell: Library ↑, Now Playing (home), Up Next ↓.
/// Sticky paging — one full screen at a time via `scrollTargetBehavior(.paging)`.
/// From home, scroll up for Library and down for Up Next. Nested library/queue lists keep
/// their own scroll; jump home via the mini player, chevrons, or starting playback.
struct MainPagerView: View {
    @State private var pagerState = MainPagerState()

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                LibrarySheetView()
                    .containerRelativeFrame(.vertical)
                    .id(MainPagerState.Page.library)
                NowPlayingView(mode: .home)
                    .containerRelativeFrame(.vertical)
                    .id(MainPagerState.Page.nowPlaying)
                UpNextView()
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
        // Pages are sized to the safe-area height, but scroll content draws edge-to-edge —
        // so the status-bar / home-indicator bands showed slivers of the neighboring pages.
        // Clip to the safe-area frame and paint the exposed bands black so exactly one page
        // is ever visible.
        .clipped()
        .background(Color.black.ignoresSafeArea())
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
