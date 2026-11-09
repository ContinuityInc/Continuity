import SwiftUI
import Ingest
import Playback

/// Library page in the vertical shell (above Now Playing): browse/add/delete playlists,
/// with a mini player that jumps back to the home page.
struct LibrarySheetView: View {
    @State private var showingAdd = false
    @State private var showingSearch = false
    @State private var showingDownloads = false

    var body: some View {
        NavigationStack {
            LibraryView()
                .miniPlayerDock()
                .navigationTitle("Continuity")
                .navigationBarTitleDisplayMode(.inline)
                // Keep the bar visible so its background runs under the status bar (the
                // pager restores safe-area insets; without `.visible` the scroll-edge
                // treatment can collapse the bar into a hairline above the grid).
                .toolbarBackground(.visible, for: .navigationBar)
                .restorePagerSafeArea()
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        DownloadsToolbarButton(showingDownloads: $showingDownloads)
                    }
                    // Every action is a primaryAction so nothing collapses into a dead "…"
                    // overflow menu (secondaryAction items did, and looked broken).
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showingSearch = true
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .accessibilityLabel("Search music")
                    }
                    // One "+" for every way in: links, connected accounts, Apple Music, files.
                    // The hub sorts out which path a paste or tap takes (`ImportHubView`).
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showingAdd = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Add music")
                    }
                }
        }
        .sheet(isPresented: $showingAdd) {
            ImportHubView()
        }
        .sheet(isPresented: $showingDownloads) {
            DownloadsView()
        }
        // Full-screen: the page owns its whole layout (pill / results / custom keyboard).
        .fullScreenCover(isPresented: $showingSearch) {
            SearchView()
        }
    }
}

/// Isolated so byte-level download progress only invalidates this control, not the library grid.
private struct DownloadsToolbarButton: View {
    @Environment(PreparationQueue.self) private var prepQueue
    @Binding var showingDownloads: Bool

    var body: some View {
        let count = prepQueue.ingestJobs.count
        // Toolbar buttons get a tight width proposal; without fixedSize the count wraps
        // inside the capsule (e.g. "480" → "48" / "0"), which is the mangled purple badge.
        let badge = count > 99 ? "99+" : "\(count)"
        return Button {
            showingDownloads = true
        } label: {
            Image(systemName: count == 0 ? "arrow.down.circle" : "arrow.down.circle.fill")
                .overlay(alignment: .topTrailing) {
                    if count > 0 {
                        Text(badge)
                            .font(.system(size: 9, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, count >= 10 ? 4 : 0)
                            .frame(minWidth: 14, minHeight: 14)
                            .background(.tint, in: Capsule())
                            .lineLimit(1)
                            .fixedSize()
                            .offset(x: 8, y: -8)
                            .accessibilityHidden(true)
                    }
                }
                // Keep the trailing badge inside the tap target; otherwise it clips
                // against the nav title and looks like stacked fragments.
                .padding(.trailing, count > 0 ? 10 : 0)
                .padding(.top, count > 0 ? 6 : 0)
        }
        .accessibilityLabel(count == 0 ? "Downloads" : "Downloads, \(count) in progress")
    }
}
