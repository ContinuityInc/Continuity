import SwiftUI
import SwiftData
import Ingest
import Domain
import ContinuityCore

// MARK: - Model

/// Drives the catalog search page: debounced iTunes-catalog queries, the two result lists,
/// and the keyboard's autocorrect engine (which learns its vocabulary from the catalog
/// results themselves plus the user's library, so corrections favor real music words).
@Observable
@MainActor
final class CatalogSearchModel {
    private(set) var query = ""
    private(set) var songs: [CatalogSong] = []
    private(set) var albums: [CatalogAlbum] = []
    private(set) var isSearching = false
    private(set) var errorMessage: String?

    /// Songs already added / albums already imported this session (drives the ✓ badges).
    private(set) var addedSongIDs: Set<Int> = []
    private(set) var importedAlbumIDs: Set<Int> = []
    private(set) var importingAlbumIDs: Set<Int> = []

    private var autocorrect = CatalogAutocorrect()
    private let catalog = MusicCatalog()
    private var searchTask: Task<Void, Never>?

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

    // MARK: Keyboard input

    func type(_ text: String) {
        query += text
        scheduleSearch()
    }

    func backspace() {
        guard !query.isEmpty else { return }
        query.removeLast()
        scheduleSearch()
    }

    /// Space applies the confident autocorrect to the word just finished (like a system
    /// keyboard), except against the music vocabulary instead of English.
    func space() {
        let word = partialWord
        if let fixed = autocorrect.correction(for: word), !word.isEmpty {
            query = String(query.dropLast(word.count)) + fixed
        }
        query += " "
        scheduleSearch()
    }

    /// Replaces the in-progress word with a tapped suggestion and searches immediately.
    func accept(suggestion: String) {
        query = String(query.dropLast(partialWord.count)) + suggestion + " "
        searchNow()
    }

    func clear() {
        query = ""
        scheduleSearch()
    }

    // MARK: Searching

    /// Debounced live search — every keystroke re-arms it, so only pauses in typing hit the
    /// network.
    private func scheduleSearch() {
        searchTask?.cancel()
        let term = query
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await self?.run(term: term)
        }
    }

    func searchNow() {
        searchTask?.cancel()
        let term = query
        searchTask = Task { [weak self] in
            await self?.run(term: term)
        }
    }

    private func run(term: String) async {
        let trimmed = term.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            songs = []; albums = []; errorMessage = nil; isSearching = false
            return
        }
        isSearching = true
        defer { isSearching = false }
        do {
            let results = try await catalog.search(trimmed)
            guard !Task.isCancelled, term == query else { return }   // stale response
            songs = results.songs
            albums = results.albums
            errorMessage = nil
            // Every result set teaches the keyboard the vocabulary the user is exploring.
            autocorrect.learn(phrases:
                results.songs.map(\.title) + results.songs.map(\.artist)
                + results.albums.map(\.title) + results.albums.map(\.artist))
        } catch {
            guard term == query else { return }
            errorMessage = LinkImporter.errorMessage(error, noun: "search")
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
                errorMessage = LinkImporter.errorMessage(error, noun: "album")
            }
        }
    }
}

// MARK: - Page

/// Full-screen catalog search: expanding pill search bar up top, results split into two
/// always-equal halves (songs / albums), and the app's own catalog-tuned keyboard at the
/// bottom — the system keyboard never appears (there is no focused text field).
struct SearchView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(PreparationQueue.self) private var prepQueue

    @State private var model = CatalogSearchModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            resultsSplit
            MusicKeyboardView(model: model)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .task {
            // One-shot seed, fetching only the two strings we read — @Query here hydrated
            // every Track (beatTimes arrays included) and kept a live subscription re-firing
            // on any library change for as long as search stayed open.
            var descriptor = FetchDescriptor<Track>()
            descriptor.propertiesToFetch = [\.title, \.artist]
            let tracks = (try? modelContext.fetch(descriptor)) ?? []
            model.seedVocabulary(titles: tracks.map(\.title) + tracks.map(\.artist))
        }
    }

    // MARK: Search pill

    private var header: some View {
        HStack(spacing: 10) {
            // The pill hugs its content — a compact circle-ish pill when empty that grows
            // with the text (fixedSize gives it its natural width inside the leading slot).
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                if model.query.isEmpty {
                    Text("Search")
                        .foregroundStyle(.tertiary)
                } else {
                    Text(model.query)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                // Blinking caret — this is a live input surface, just not a system one.
                Caret()
            }
            .font(.body)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.thinMaterial, in: Capsule())
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.snappy(duration: 0.2), value: model.query)

            if !model.query.isEmpty {
                Button {
                    model.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Clear search")
            }
            Button("Done") { dismiss() }
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
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
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

/// Blinking text caret for the pill (purely cosmetic — input comes from the custom keyboard).
private struct Caret: View {
    @State private var visible = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.accentColor)
            .frame(width: 2, height: 20)
            .opacity(visible ? 1 : 0)
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(530))
                    withAnimation(.easeInOut(duration: 0.15)) { visible.toggle() }
                }
            }
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
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                .overlay { Image(systemName: "music.note").foregroundStyle(.secondary) }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Custom keyboard

/// The app's own keyboard: a QWERTY grid rendered in SwiftUI (the system keyboard never
/// appears). Its suggestion bar and space-bar autocorrect run against the catalog vocabulary
/// via `CatalogAutocorrect`, so it repairs toward music words, not English ones.
private struct MusicKeyboardView: View {
    let model: CatalogSearchModel
    @State private var showNumbers = false

    private static let letterRows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
    private static let numberRows = ["1234567890", "-'&.,?!/", "@:;()$#"]

    private let haptic = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        VStack(spacing: 7) {
            // Leaf view: suggestions change on every keystroke; inlined, they re-built the
            // entire ~40-button key grid per keypress instead of just this bar.
            SuggestionBar(model: model, haptic: haptic)
            ForEach(showNumbers ? Self.numberRows : Self.letterRows, id: \.self) { row in
                keyRow(row)
            }
            bottomRow
        }
        .padding(.horizontal, 4)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(.regularMaterial)
    }

    private func keyRow(_ characters: String) -> some View {
        HStack(spacing: 5) {
            ForEach(Array(characters), id: \.self) { character in
                key(String(character)) {
                    model.type(String(character))
                }
            }
        }
        // Center shorter rows (like the system keyboard's a…l row).
        .padding(.horizontal, characters.count < 10 ? 14 : 0)
    }

    private var bottomRow: some View {
        // Space is the only flexible key; the modifiers keep fixed widths like the system
        // keyboard's bottom row.
        HStack(spacing: 5) {
            key(showNumbers ? "abc" : "123", width: 56) {
                showNumbers.toggle()
            }
            key("space") {
                model.space()
            }
            key(symbol: "delete.left", width: 52) {
                model.backspace()
            }
            key(symbol: "magnifyingglass", width: 52, prominent: true) {
                model.searchNow()
            }
        }
    }

    private func key(_ label: String = "", symbol: String? = nil, width: CGFloat? = nil,
                     prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            haptic.impactOccurred()
            action()
        } label: {
            Group {
                if let symbol {
                    Image(systemName: symbol)
                } else {
                    Text(label)
                }
            }
            .font(label.count > 1 ? .subheadline : .title3)
            .frame(maxWidth: width ?? .infinity)
            .frame(width: width, height: 42)
            .background(
                prominent ? AnyShapeStyle(Color.accentColor.opacity(0.85)) : AnyShapeStyle(.thinMaterial),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
        // Holding backspace repeats, like the real thing.
        .buttonRepeatBehavior(symbol == "delete.left" ? .enabled : .disabled)
    }
}

/// Leaf: the keyboard's only per-keystroke invalidation surface (see MusicKeyboardView.body).
private struct SuggestionBar: View {
    let model: CatalogSearchModel
    let haptic: UIImpactFeedbackGenerator

    var body: some View {
        HStack(spacing: 6) {
            let suggestions = model.suggestions
            if suggestions.isEmpty {
                // Fixed height so the keyboard never jumps as suggestions come and go.
                Color.clear.frame(height: 32)
            } else {
                ForEach(suggestions, id: \.self) { word in
                    Button {
                        haptic.impactOccurred()
                        model.accept(suggestion: word)
                    } label: {
                        Text(word)
                            .font(.subheadline)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .frame(height: 32)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 4)
    }
}
