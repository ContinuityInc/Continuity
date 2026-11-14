import SwiftUI
import Ingest
import ContinuityCore

/// Picks playlists out of a connected Spotify / YouTube / SoundCloud account and imports them.
/// Pushed from the import hub; `onDone` dismisses the whole hub after a successful import.
///
/// Reads through the service's official API (`PreparationQueue.connectedPlaylists`), so private
/// playlists and the account's likes are listed. Spotify and SoundCloud contribute metadata only
/// (audio is re-sourced from YouTube); YouTube items ingest directly.
struct ServicePlaylistPickerView: View {
    let service: MusicService
    let onDone: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(PreparationQueue.self) private var prepQueue

    private enum Phase {
        case loading
        case loaded([ServicePlaylistSummary])
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var selection: Set<String> = []
    @State private var isImporting = false

    var body: some View {
        content
            .navigationTitle(service.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView("Loading your \(service.displayName) library…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let reason):
            message(symbol: "exclamationmark.triangle.fill", title: "Couldn't Load Library", detail: reason) {
                Button("Try Again") { Task { await load() } }
                    .buttonStyle(.glassProminent)
            }

        case .loaded(let playlists) where playlists.isEmpty:
            message(
                symbol: "music.note.list",
                title: "No Playlists",
                detail: "Playlists you create on \(service.displayName) will show up here."
            ) { EmptyView() }

        case .loaded(let playlists):
            playlistList(playlists)
        }
    }

    private func playlistList(_ playlists: [ServicePlaylistSummary]) -> some View {
        List {
            Section {
                ForEach(playlists) { playlist in
                    Button {
                        toggle(playlist.id)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: playlist.kind == .likes ? "heart.fill" : (playlist.kind == .album ? "opticaldisc" : "music.note.list"))
                                .foregroundStyle(playlist.kind == .likes ? .pink : .secondary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(playlist.name)
                                    .foregroundStyle(.primary)
                                Text(detail(for: playlist))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if selection.contains(playlist.id) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                if service == .youtube {
                    Text("Videos are downloaded directly from YouTube.")
                } else {
                    Text("Songs are matched to YouTube for audio — \(service.displayName)'s own streams are protected and can't be mixed.")
                }
            }

            Section {
                Button(action: importSelected) {
                    HStack {
                        if isImporting {
                            ProgressView()
                            Text("Importing…")
                        } else {
                            Label(importLabel, systemImage: "square.and.arrow.down")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .disabled(selection.isEmpty || isImporting)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    private func detail(for playlist: ServicePlaylistSummary) -> String {
        var parts: [String] = []
        if let count = playlist.trackCount { parts.append("\(count) \(service == .youtube ? "videos" : "songs")") }
        if let owner = playlist.ownerName, !owner.isEmpty { parts.append(owner) }
        if playlist.kind == .likes { parts.append("Your likes") }
        return parts.isEmpty ? (playlist.kind == .album ? "Album" : "Playlist") : parts.joined(separator: " · ")
    }

    private var importLabel: String {
        selection.count <= 1 ? "Import Playlist" : "Import \(selection.count) Playlists"
    }

    /// Shared empty/error layout so the non-list states look like one screen.
    private func message<Action: View>(
        symbol: String,
        title: String,
        detail: String,
        @ViewBuilder action: () -> Action
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            action()
                .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func load() async {
        phase = .loading
        do {
            phase = .loaded(try await prepQueue.connectedPlaylists(for: service))
        } catch {
            phase = .failed(LinkImporter.errorMessage(error, noun: "library"))
        }
    }

    /// Imports every checked playlist. A single failure doesn't abandon the rest — the screen
    /// stays only if nothing at all got imported.
    private func importSelected() {
        guard case .loaded(let playlists) = phase else { return }
        let picked = playlists.filter { selection.contains($0.id) }
        guard !picked.isEmpty else { return }

        isImporting = true
        Task {
            defer { isImporting = false }
            var imported = 0
            var lastError: Error?
            for playlist in picked {
                do {
                    try await prepQueue.importConnectedPlaylist(playlist, in: modelContext)
                    imported += 1
                } catch {
                    lastError = error
                    continue
                }
            }
            if imported > 0 {
                onDone()
            } else {
                phase = .failed(lastError.map { LinkImporter.errorMessage($0, noun: "playlist") } ?? "Those playlists couldn't be imported.")
            }
        }
    }
}
