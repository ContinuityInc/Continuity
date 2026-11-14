import SwiftUI
import SwiftData
import Ingest
import Domain
import ContinuityCore

// MARK: - Model

/// Drives the catalog search page: debounced iTunes Search queries (cheap while typing),
/// Core ranking + explicit artist-lookup upgrades on submit/settle, result lists, and a
/// music-vocabulary suggestion engine (`CatalogAutocorrect`) that learns from catalog results
/// plus the user's library. Input uses the system keyboard; suggestions sit above the results
/// and never replace it.
@Observable
@MainActor
final class CatalogSearchModel {
    /// Bound to the search field. Space applies a confident music-vocabulary correction when
    /// the finished word is unknown; every change re-arms the debounced catalog query.
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            handleQueryEdit(from: oldValue, to: query)
        }
    }

    private(set) var songs: [CatalogSong] = []
    private(set) var albums: [CatalogAlbum] = []
    private(set) var isSearching = false
    /// Primary Search failure (blocks empty results). Cleared on the next successful query.
    private(set) var errorMessage: String?
    /// Add/import failure while results are on screen. Separate so it can't cover the lists
    /// until the next keystroke the way `errorMessage` used to.
    private(set) var actionError: String?

    /// Songs already added / albums already imported this session (drives the ✓ badges).
    private(set) var addedSongIDs: Set<Int> = []
    private(set) var importedAlbumIDs: Set<Int> = []
    private(set) var importingAlbumIDs: Set<Int> = []

    private var autocorrect = CatalogAutocorrect()
    private let catalog = MusicCatalog()
    private var searchTask: Task<Void, Never>?
    /// Guards re-entrant `query` writes when space-bar correction rewrites the finished word.
    private var isApplyingCorrection = false

    /// The word currently being typed (after the last space) — what suggestions complete.
    private var partialWord: String {
        query.hasSuffix(" ") ? "" : String(query.split(separator: " ").last ?? "")
    }

    /// Suggestion-bar candidates for the in-progress word.
    var suggestions: [String] {
        autocorrect.suggestions(for: partialWord, limit: 3)
    }

    /// Seeds the vocabulary from the user's own library so their music's words are trusted
    /// from the first keystroke (heavier weight than transient catalog hits).
    func seedVocabulary(titles: [String]) {
        autocorrect.learn(phrases: titles, weight: 5)
    }

    /// Replaces the in-progress word with a tapped suggestion and searches immediately.
    func accept(suggestion: String) {
        query = String(query.dropLast(partialWord.count)) + suggestion + " "
        searchNow()
    }

    func clear() {
        query = ""
        actionError = nil
    }

    func dismissActionError() {
        actionError = nil
    }

    // MARK: Query edits

    private func handleQueryEdit(from oldValue: String, to newValue: String) {
        if isApplyingCorrection {
            scheduleSearch()
            return
        }
        // Trailing space just typed: confident music-vocab repair on the finished word
        // (system autocorrect is disabled on the field so English doesn't fight artist names).
        if newValue.hasSuffix(" "),
           newValue.count == oldValue.count + 1,
           String(newValue.dropLast()) == oldValue {
            let word = String(oldValue.split(separator: " ").last ?? "")
            if !word.isEmpty, let fixed = autocorrect.correction(for: word), fixed != word.lowercased() {
                isApplyingCorrection = true
                query = String(oldValue.dropLast(word.count)) + fixed + " "
                isApplyingCorrection = false
                return
            }
        }
        scheduleSearch()
    }

    // MARK: Searching

    /// Debounced live search — 350 ms pause → cheap primary Search (2 GETs). After results
    /// settle another ~900 ms without typing, run the explicit upgrade pass. Artist lookups
    /// never ride every keystroke (Apple Search ≈ 20 calls/min).
    private func scheduleSearch() {
        searchTask?.cancel()
        let term = query
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await self?.run(term: term, upgrade: false)
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled, self?.query == term else { return }
            await self?.run(term: term, upgrade: true)
        }
    }

    /// Keyboard submit — full upgrade immediately (variants + cached artist lookups).
    func searchNow() {
        searchTask?.cancel()
        let term = query
        searchTask = Task { [weak self] in
            await self?.run(term: term, upgrade: true)
        }
    }

    private func run(term: String, upgrade: Bool) async {
        let trimmed = term.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            songs = []; albums = []; errorMessage = nil; isSearching = false
            return
        }
        isSearching = true
        defer { isSearching = false }
        do {
            let results = try await catalog.search(trimmed, upgrade: upgrade)
            guard !Task.isCancelled, term == query else { return }   // stale response
            songs = results.songs
            albums = results.albums
            errorMessage = nil
            actionError = nil
            // Every result set teaches the suggestion engine the vocabulary being explored.
            autocorrect.learn(phrases:
                results.songs.map(\.title) + results.songs.map(\.artist)
                + results.albums.map(\.title) + results.albums.map(\.artist))
        } catch {
            guard term == query else { return }
            // Upgrades are best-effort inside MusicCatalog; only primary Search failures
            // reach here. Keep any already-shown cheap results instead of wiping them.
            if !upgrade || (songs.isEmpty && albums.isEmpty) {
                errorMessage = LinkImporter.errorMessage(error, noun: "search")
            }
        }
    }

    // MARK: Adding to the library

    func add(song: CatalogSong, queue: PreparationQueue, context: ModelContext) {
        guard !addedSongIDs.contains(song.id) else { return }
        queue.addCatalogSong(song, in: context)
        addedSongIDs.insert(song.id)
    }

    func importAlbum(_ album: CatalogAlbum, queue: PreparationQueue, context: ModelContext) {
        guard !importedAlbumIDs.contains(album.id), !importingAlbumIDs.contains(album.id) else { return }
        importingAlbumIDs.insert(album.id)
        Task {
            defer { importingAlbumIDs.remove(album.id) }
            do {
                try await queue.importCatalogAlbum(album, in: context)
                importedAlbumIDs.insert(album.id)
            } catch {
                actionError = LinkImporter.errorMessage(error, noun: "album")
            }
        }
    }
}

// MARK: - Page

/// Full-screen catalog search: glass search field (system keyboard), optional music-vocabulary
/// suggestions, and results split into two always-equal halves (songs / albums).
struct SearchView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(PreparationQueue.self) private var prepQueue

    @State private var model = CatalogSearchModel()
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            header(query: $model.query)
            SuggestionBar(model: model)
            if let actionError = model.actionError {
                Button {
                    model.dismissActionError()
                } label: {
                    Label(actionError, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .continuityGlass(cornerRadius: 12, interactive: true)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
                .accessibilityLabel(actionError)
                .accessibilityHint("Dismisses the error")
            }
            resultsSplit
        }
        // Duo inner / mirrored wide windows: keep the field, suggestions, and result
        // halves at phone-readable width (CLAUDE.md Duo invariant). A full-bleed
        // fullScreenCover otherwise stretches chrome across ~900 pt.
        .frame(maxWidth: CGFloat(DuoLayout.readableColumnMaxWidth))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
        .task {
            // One-shot seed, fetching only the two strings we read — @Query here hydrated
            // every Track (beatTimes arrays included) and kept a live subscription re-firing
            // on any library change for as long as search stayed open.
            var descriptor = FetchDescriptor<Track>()
            descriptor.propertiesToFetch = [\.title, \.artist]
            let tracks = (try? modelContext.fetch(descriptor)) ?? []
            model.seedVocabulary(titles: tracks.map(\.title) + tracks.map(\.artist))
            searchFocused = true
        }
    }

    // MARK: Search field

    private func header(query: Binding<String>) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search", text: query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($searchFocused)
                    .onSubmit { model.searchNow() }
                    .accessibilityLabel("Search")
                    .accessibilityHint("Searches songs and albums. Activate Search on the keyboard to submit.")
            }
            .font(.body)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .continuityGlassCapsule()
            .frame(maxWidth: .infinity, alignment: .leading)

            if !model.query.isEmpty {
                Button {
                    model.clear()
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Clear search")
            }
            Button("Done") {
                searchFocused = false
                dismiss()
            }
            .fontWeight(.semibold)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Results

    /// Two flexible children in a VStack split the leftover space exactly in half — the
    /// halves stay equal no matter how many results either side has.
    private var resultsSplit: some View {
        VStack(spacing: 0) {
            resultHalf(title: "Songs", count: model.songs.count) {
                ForEach(model.songs) { song in
                    SongResultRow(song: song, added: model.addedSongIDs.contains(song.id)) {
                        model.add(song: song, queue: prepQueue, context: modelContext)
                    }
                }
            }
            Divider()
            resultHalf(title: "Albums", count: model.albums.count) {
                ForEach(model.albums) { album in
                    AlbumResultRow(
                        album: album,
                        imported: model.importedAlbumIDs.contains(album.id),
                        importing: model.importingAlbumIDs.contains(album.id)
                    ) {
                        model.importAlbum(album, queue: prepQueue, context: modelContext)
                    }
                }
            }
        }
        .overlay {
            if let message = model.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .padding(10)
                    .continuityGlass(cornerRadius: 12)
                    .padding()
            }
        }
    }

    @ViewBuilder
    private func resultHalf<Rows: View>(title: String, count: Int, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                if model.isSearching {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            if count == 0 {
                Text(model.query.isEmpty ? "Type to search the catalog" : "No \(title.lowercased()) found")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) { rows() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Suggestion bar

/// Leaf: music-vocabulary completions for the in-progress word. Sits under the field and
/// above results — never a custom key grid. Invalidates on keystroke without rebuilding the
/// result halves' chrome.
private struct SuggestionBar: View {
    let model: CatalogSearchModel

    var body: some View {
        HStack(spacing: 6) {
            let suggestions = model.suggestions
            if suggestions.isEmpty {
                // Fixed height so the results pane never jumps as suggestions come and go.
                Color.clear.frame(height: 32)
            } else {
                ForEach(suggestions, id: \.self) { word in
                    Button {
                        model.accept(suggestion: word)
                    } label: {
                        Text(word)
                            .font(.subheadline)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .frame(height: 32)
                            .continuityGlass(cornerRadius: 8, interactive: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(word)
                    .accessibilityHint("Accepts search suggestion")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }
}

// MARK: - Result rows

private struct SongResultRow: View {
    let song: CatalogSong
    let added: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            CatalogArtwork(url: song.artworkURL)
            VStack(alignment: .leading, spacing: 1) {
                Text(song.title).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(song.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(action: action) {
                Image(systemName: added ? "checkmark.circle.fill" : "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(added ? Color.green : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(added)
            .accessibilityLabel(added ? "Added" : "Add \(song.title)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}

private struct AlbumResultRow: View {
    let album: CatalogAlbum
    let imported: Bool
    let importing: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            CatalogArtwork(url: album.artworkURL)
            VStack(alignment: .leading, spacing: 1) {
                Text(album.title).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if importing {
                ProgressView().controlSize(.small)
            } else {
                Button(action: action) {
                    Image(systemName: imported ? "checkmark.circle.fill" : "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(imported ? Color.green : Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(imported)
                .accessibilityLabel(imported ? "Imported" : "Import \(album.title)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var subtitle: String {
        var parts = [album.artist]
        if let year = album.releaseYear { parts.append(String(year)) }
        if album.trackCount > 0 { parts.append("\(album.trackCount) tracks") }
        return parts.joined(separator: " · ")
    }
}

private struct CatalogArtwork: View {
    let url: URL?

    var body: some View {
        Group {
            if let url {
                // Same shared decode + bounded cache as library artwork: search results scroll,
                // and `AsyncImage` re-fetched and re-decoded every row that came back on screen.
                CachedArtworkImage(url: url, cornerRadius: 8, cropsLetterbox: false) {
                    placeholder
                }
            } else {
                placeholder
            }
        }
        .frame(width: 44, height: 44)
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 8).fill(.quaternary)
            .overlay { Image(systemName: "music.note").foregroundStyle(.secondary) }
    }
}
