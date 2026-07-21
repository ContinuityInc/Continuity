import SwiftUI
import ContinuityCore
import Ingest

/// Sheet for importing playlists out of the user's Apple Music library.
///
/// **Metadata only.** Apple Music audio is DRM-protected and can't feed our engine, so an
/// imported playlist keeps each song's title + artist and the ingest pipeline re-sources the
/// recording from YouTube — the same trade the Spotify importer makes.
struct AppleMusicImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(PreparationQueue.self) private var prepQueue
    @Environment(\.openURL) private var openURL

    /// What the sheet is currently showing. Access state and load state are one enum because
    /// they're mutually exclusive — there's no "denied but also listing playlists".
    private enum Phase {
        case askingPermission
        case denied
        case loading
        case loaded([AppleMusicPlaylistContents])
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var selection: Set<String> = []
    @State private var isImporting = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Apple Music")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .disabled(isImporting)
                    }
                }
        }
        .task { await start() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .askingPermission, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .denied:
            message(
                symbol: "lock.fill",
                title: "No Access to Apple Music",
                detail: "Continuity needs permission to read your library. Enable Media & Apple Music in Settings."
            ) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.glassProminent)
            }

        case .failed(let reason):
            message(symbol: "exclamationmark.triangle.fill", title: "Couldn't Read Library", detail: reason) {
                Button("Try Again") { Task { await load() } }
                    .buttonStyle(.glassProminent)
            }

        case .loaded(let playlists) where playlists.isEmpty:
            message(
                symbol: "music.note.list",
                title: "No Playlists",
                detail: "Playlists you create in the Music app will show up here."
            ) { EmptyView() }

        case .loaded(let playlists):
            playlistList(playlists)
        }
    }

    private func playlistList(_ playlists: [AppleMusicPlaylistContents]) -> some View {
        List {
            Section {
                ForEach(playlists) { playlist in
                    Button {
                        toggle(playlist.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(playlist.name ?? "Untitled Playlist")
                                    .foregroundStyle(.primary)
                                Text("\(playlist.tracks.count) songs")
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
                Text("Songs are matched to YouTube for audio — Apple Music's own files are protected and can't be mixed.")
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

    private var importLabel: String {
        selection.count <= 1 ? "Import Playlist" : "Import \(selection.count) Playlists"
    }

    /// Shared empty/error layout so the three non-list states look like one screen.
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

    /// Prompts on first open, then loads. Re-opening after a grant skips straight to loading.
    private func start() async {
        switch prepQueue.appleMusicAccess {
        case .authorized:
            await load()
        case .denied:
            phase = .denied
        case .notDetermined:
            phase = .askingPermission
            let granted = await prepQueue.requestAppleMusicAccess()
            if granted == .authorized { await load() } else { phase = .denied }
        }
    }

    private func load() async {
        phase = .loading
        do {
            phase = .loaded(try await prepQueue.appleMusicPlaylists())
        } catch {
            phase = .failed("Your library couldn't be read. Try again in a moment.")
        }
    }

    /// Imports every checked playlist. A single failure doesn't abandon the rest — the sheet
    /// stays open only if nothing at all got imported.
    private func importSelected() {
        guard case .loaded(let playlists) = phase else { return }
        let picked = playlists.filter { selection.contains($0.id) }
        guard !picked.isEmpty else { return }

        isImporting = true
        Task {
            defer { isImporting = false }
            var imported = 0
            for playlist in picked {
                do {
                    try await prepQueue.importAppleMusicPlaylist(playlist, in: modelContext)
                    imported += 1
                } catch {
                    continue
                }
            }
            if imported > 0 {
                dismiss()
            } else {
                phase = .failed("Those playlists couldn't be imported.")
            }
        }
    }
}
