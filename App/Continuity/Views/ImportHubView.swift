import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Ingest
import Domain
import ContinuityCore

/// The one "+" destination: every way music gets into the library, on a single sheet.
///
/// - **Paste a link** — YouTube video/playlist, Spotify playlist/album/track, SoundCloud
///   set/track. Classified locally by `LinkImporter`; a connected account for that service makes
///   the import go through the official API (full-length and private lists), otherwise the
///   anonymous page scrape is used.
/// - **Your libraries** — Spotify / YouTube / SoundCloud sign-in (OAuth, `ServiceAuthManager`)
///   with a playlist picker per connected account, plus the on-device Apple Music library.
/// - **Files** — audio files or a whole folder from the Files picker.
///
/// Spotify, Apple Music and SoundCloud contribute **metadata only**; each song's audio is
/// re-sourced from YouTube by the ingest pipeline (their own audio is DRM-locked / not ours to
/// stream). YouTube items ingest directly.
struct ImportHubView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(PreparationQueue.self) private var prepQueue

    @State private var linkText = ""
    @State private var linkError: String?
    /// True while a pasted collection is being resolved (page/API fetch + track creation).
    @State private var isImportingLink = false

    @State private var showingFilePicker = false
    @State private var isImportingFiles = false
    /// Account-level failures (sign-in cancelled, provider refused) show as an alert, since they
    /// aren't about the link field.
    @State private var accountError: String?

    private var trimmedLink: String {
        linkText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var detected: LinkImporter.Link? {
        LinkImporter.classify(trimmedLink)
    }

    var body: some View {
        NavigationStack {
            Form {
                linkSection
                librariesSection
                filesSection
            }
            .navigationTitle("Add Music")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isImportingLink || isImportingFiles)
                }
            }
            .navigationDestination(for: MusicService.self) { service in
                ServicePlaylistPickerView(service: service) { dismiss() }
            }
            .navigationDestination(for: AppleMusicDestination.self) { _ in
                AppleMusicImportView { dismiss() }
            }
        }
        // Files OR a folder: folders are scanned recursively for music (audio type + song-sized)
        // and imported in bulk into "Local Files". iOS sandboxing means the app can't read the
        // Files "music folder" unprompted; a folder grant through this picker is the sanctioned way.
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.audio, .folder],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            isImportingFiles = true
            Task {
                _ = await prepQueue.importLocalFiles(urls, in: modelContext)
                isImportingFiles = false
                dismiss()
            }
        }
        .alert(
            "Couldn't Connect",
            isPresented: Binding(get: { accountError != nil }, set: { if !$0 { accountError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(accountError ?? "")
        }
    }

    // MARK: - Link

    private var linkSection: some View {
        Section {
            TextField("YouTube, Spotify or SoundCloud link", text: $linkText, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .lineLimit(1...3)
                .onChange(of: linkText) { linkError = nil }

            Button(action: importLink) {
                HStack {
                    if isImportingLink {
                        ProgressView()
                        Text("Importing…")
                    } else {
                        Label(
                            (detected?.isPlaylistImport ?? false) ? "Import Playlist" : "Add",
                            systemImage: (detected?.isPlaylistImport ?? false) ? "music.note.list" : "arrow.down.circle.fill"
                        )
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .disabled(trimmedLink.isEmpty || isImportingLink)
            .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
            .listRowBackground(Color.clear)
        } header: {
            Text("Paste a Link")
        } footer: {
            linkFooter
        }
    }

    @ViewBuilder
    private var linkFooter: some View {
        if let linkError {
            Label(linkError, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.footnote)
        } else {
            switch detected {
            case .spotify(let link)? where link.isCollection:
                Text(viaAccountNote(.spotify, "Spotify \(link.kind.rawValue) — each song is matched to YouTube for audio and imported as a new playlist."))
            case .spotify?:
                Text(viaAccountNote(.spotify, "Spotify track — matched to YouTube for audio and added to “From Spotify”."))
            case .soundcloud(let link)? where link.kind == .track:
                Text(viaAccountNote(.soundcloud, "SoundCloud track — matched to YouTube for audio and added to “From SoundCloud”."))
            case .soundcloud?:
                Text(viaAccountNote(.soundcloud, "SoundCloud set — each track is matched to YouTube for audio and imported as a new playlist."))
            case .youtubePlaylist?:
                Text(viaAccountNote(.youtube, "YouTube playlist — every video is imported as a new playlist."))
            case .youtubeVideo?:
                Text("YouTube video — added to “From YouTube”.")
            case nil:
                Text("Playlists, albums and songs from YouTube, Spotify or SoundCloud. Connect an account below to import private playlists and your likes.")
            }
        }
    }

    /// Appends how the import will run for this service, so "why did my private playlist fail"
    /// is answered before the tap.
    private func viaAccountNote(_ service: MusicService, _ base: String) -> String {
        prepQueue.serviceAuth.isConnected(service)
            ? base + " Imported through your connected \(service.displayName) account."
            : base
    }

    /// Routes the pasted link through the shared importer, or shows an inline error. Shows the
    /// spinner while resolving, dismisses on success, and maps failures to a cause-specific
    /// message (so a transient network blip doesn't read as "private").
    private func importLink() {
        guard let link = detected else {
            linkError = "Couldn't find a YouTube, Spotify or SoundCloud link in that text."
            return
        }
        isImportingLink = true
        linkError = nil
        let source = trimmedLink
        Task {
            defer { isImportingLink = false }
            do {
                try await LinkImporter.run(link, sourceURL: source, queue: prepQueue, in: modelContext)
                dismiss()
            } catch {
                linkError = LinkImporter.errorMessage(error, noun: link.noun)
            }
        }
    }

    // MARK: - Libraries

    private var librariesSection: some View {
        Section {
            ForEach(MusicService.allCases) { service in
                ConnectedServiceRow(service: service) { error in
                    accountError = LinkImporter.errorMessage(error, noun: "account")
                }
            }
            NavigationLink(value: AppleMusicDestination()) {
                ServiceRowLabel(
                    title: "Apple Music",
                    symbol: "music.note",
                    tint: .pink,
                    status: appleMusicStatus
                )
            }
        } header: {
            Text("Your Libraries")
        } footer: {
            Text("Connect an account to browse and import its playlists and likes. Spotify, SoundCloud and Apple Music songs are matched to YouTube for audio — their own files are protected and can't be mixed.")
        }
    }

    private var appleMusicStatus: String {
        switch prepQueue.appleMusicAccess {
        case .authorized: return "On this device"
        case .denied: return "Access denied — fix in Settings"
        case .notDetermined: return "On this device"
        }
    }

    // MARK: - Files

    private var filesSection: some View {
        Section {
            Button {
                showingFilePicker = true
            } label: {
                HStack {
                    ServiceRowLabel(
                        title: "Audio Files or Folder",
                        symbol: "folder.fill",
                        tint: .blue,
                        status: "MP3, M4A, WAV, FLAC and more"
                    )
                    Spacer()
                    if isImportingFiles {
                        ProgressView()
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isImportingFiles)
        } header: {
            Text("Files")
        } footer: {
            Text("Pick songs, or a whole folder to import everything in it. Imported into “Local Files”.")
        }
    }
}

/// `navigationDestination` token for the Apple Music picker (it has no `MusicService` case).
private struct AppleMusicDestination: Hashable {}

/// One connected-account row: shows status; a tap connects (sign-in) or, once connected, opens
/// the playlist picker. Disconnect lives in the swipe/context menu.
private struct ConnectedServiceRow: View {
    let service: MusicService
    let onError: (Error) -> Void

    @Environment(PreparationQueue.self) private var prepQueue

    private var auth: ServiceAuthManager { prepQueue.serviceAuth }
    private var isConnected: Bool { auth.isConnected(service) }
    private var isConfigured: Bool { auth.isConfigured(service) }
    private var isSigningIn: Bool { auth.signingIn.contains(service) }

    var body: some View {
        Group {
            if isConnected {
                NavigationLink(value: service) {
                    label
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { auth.signOut(service) } label: {
                        Label("Disconnect", systemImage: "person.crop.circle.badge.xmark")
                    }
                }
                .contextMenu {
                    Button(role: .destructive) { auth.signOut(service) } label: {
                        Label("Disconnect \(service.displayName)", systemImage: "person.crop.circle.badge.xmark")
                    }
                }
            } else {
                Button(action: connect) {
                    HStack {
                        label
                        Spacer()
                        if isSigningIn {
                            ProgressView()
                        } else if isConfigured {
                            Text("Connect")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isConfigured || isSigningIn)
            }
        }
    }

    private var label: some View {
        ServiceRowLabel(title: service.displayName, symbol: symbol, tint: tint, status: status)
    }

    private var status: String {
        if isConnected { return "Connected · playlists and likes" }
        if isSigningIn { return "Signing in…" }
        if !isConfigured { return "Sign-in not set up in this build · links still work" }
        return "Not connected · links still work"
    }

    private var symbol: String {
        switch service {
        case .spotify: return "waveform.circle.fill"
        case .youtube: return "play.rectangle.fill"
        case .soundcloud: return "cloud.fill"
        }
    }

    private var tint: Color {
        switch service {
        case .spotify: return .green
        case .youtube: return .red
        case .soundcloud: return .orange
        }
    }

    private func connect() {
        Task {
            do {
                try await auth.signIn(service)
            } catch {
                onError(error)
            }
        }
    }
}

/// Icon + title + status line shared by every row on the hub, so the four sources read as one list.
private struct ServiceRowLabel: View {
    let title: String
    let symbol: String
    let tint: Color
    let status: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}
