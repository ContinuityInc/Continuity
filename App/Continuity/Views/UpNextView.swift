import SwiftUI
import Playback
import Domain
import ContinuityCore

/// The queue page (below Now Playing): what plays next, with drag-to-reorder and
/// swipe-to-remove, plus the Flow toggle that reorders the upcoming tracks into a
/// key/tempo-compatible DJ sequence.
struct UpNextView: View {
    @Environment(Player.self) private var player
    @Environment(MainPagerState.self) private var pagerState
    // Persisted as a mode label; toggling ON reorders once, toggling OFF is not an undo.
    @AppStorage("flowMode.v1") private var flowMode = false

    var body: some View {
        // Capture once: upcomingTracks allocates a fresh array slice per access, and body
        // read it twice (emptiness check + list).
        let upcoming = player.upcomingTracks
        return NavigationStack {
            Group {
                if upcoming.isEmpty {
                    ContentUnavailableView("Nothing up next", systemImage: "list.bullet")
                } else {
                    queueList(upcoming)
                }
            }
            .navigationTitle("Up Next")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if pagerState.page == .upNext {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            pagerState.goToNowPlaying()
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .accessibilityLabel("Now Playing")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Toggle("Flow", systemImage: "wand.and.stars", isOn: $flowMode)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
            }
            .onChange(of: flowMode) { _, isOn in
                if isOn { applyFlowOrdering() }
            }
        }
    }

    private func queueList(_ upcoming: [Track]) -> some View {
        List {
            Section {
                ForEach(upcoming) { track in
                    row(track)
                }
                .onMove { player.moveUpcoming(fromOffsets: $0, toOffset: $1) }
                .onDelete { player.removeUpcoming(atOffsets: $0) }
            } footer: {
                Text("Flow orders what's next by key and tempo, like a DJ set.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
    }

    /// Same 44pt artwork + title/artist treatment as the library's track rows.
    private func row(_ track: Track) -> some View {
        HStack(spacing: 12) {
            RemoteArtworkView(url: track.artworkURL, symbol: track.artworkSymbol,
                              seed: track.gradientSeed, cornerRadius: 8)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).lineLimit(1)
                Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    /// Reorders only the upcoming tracks. The current track is passed as the chain's anchor —
    /// so the first pick is compatible with what's playing — but it never moves:
    /// replaceUpcoming keeps it in place and we drop its id from the returned order.
    private func applyFlowOrdering() {
        guard let current = player.currentTrack else { return }
        let tracks = [current] + player.upcomingTracks
        let items = tracks.map { FlowItem(id: $0.id, bpm: $0.bpm, camelotCode: $0.camelotCode) }
        let ordered = FlowOrdering.order(items, startingAt: current.id)
        let byID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        player.replaceUpcoming(with: ordered.filter { $0 != current.id }.compactMap { byID[$0] })
    }
}
