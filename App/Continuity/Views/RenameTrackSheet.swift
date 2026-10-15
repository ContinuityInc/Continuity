import SwiftUI
import SwiftData
import Playback
import Domain
import ContinuityCore

/// Edits a track's display title and artist. Presented from the "Rename" context-menu action
/// on every track row (playlist detail, search results, Up Next).
///
/// Only the display fields change: the YouTube ID / search query that identify the track to
/// ingest and sync stay untouched, so a renamed song keeps its audio, stems and analysis.
struct RenameTrackSheet: View {
    let track: Track
    @Environment(Player.self) private var player
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var artist: String
    @FocusState private var focusedField: Field?

    private enum Field { case title, artist }

    init(track: Track) {
        self.track = track
        _title = State(initialValue: track.title)
        _artist = State(initialValue: track.artist)
    }

    /// The edit as it would be saved, or nil when the title is blank.
    private var pendingEdit: TrackRename.Edit? {
        TrackRename.normalized(title: title, artist: artist)
    }

    private var canSave: Bool {
        guard let edit = pendingEdit else { return false }
        return TrackRename.isChange(edit, fromTitle: track.title, artist: track.artist)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                        .focused($focusedField, equals: .title)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .artist }
                    TextField("Artist", text: $artist)
                        .focused($focusedField, equals: .artist)
                        .submitLabel(.done)
                        .onSubmit { if canSave { save() } }
                } footer: {
                    if pendingEdit == nil {
                        Text("A song needs a title.")
                    } else if !track.isDemo {
                        Text("Changes only how the song is shown — its audio and analysis stay the same.")
                    }
                }
            }
            .navigationTitle("Rename Song")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
            .onAppear { focusedField = .title }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        guard track.rename(title: title, artist: artist) else {
            dismiss()
            return
        }
        try? modelContext.save()
        // The lock screen doesn't observe the model — only the player can republish it.
        player.refreshNowPlayingMetadata(for: track)
        dismiss()
    }
}

extension View {
    /// Presents `RenameTrackSheet` for the bound track; clearing the binding dismisses it.
    func renameTrackSheet(for track: Binding<Track?>) -> some View {
        sheet(item: track) { RenameTrackSheet(track: $0) }
    }
}
