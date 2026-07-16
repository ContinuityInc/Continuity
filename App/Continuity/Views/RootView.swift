import SwiftUI
import UIKit
import Ingest
import Playback
import Domain
import SwiftData

/// Top-level shell: the app always opens onto the minimal Now Playing screen, resuming the
/// previous session's song (or staging COMË N GO on first launch). The library lives in a
/// sheet behind its corner button.
struct RootView: View {
    @Environment(Player.self) private var player
    @Environment(PreparationQueue.self) private var prepQueue
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    /// Link awaiting user confirmation (from the URL scheme, a shared https URL, or the clipboard).
    @State private var pendingImport: PendingLinkImport?
    @State private var importError: String?
    /// Debounce: a clipboard URL is offered at most once, even across launches.
    @AppStorage("lastOfferedClipboardURL") private var lastOfferedClipboardURL = ""
    /// Last pasteboard generation we inspected — gates the banner-triggering reads below.
    @AppStorage("lastCheckedPasteboardChange") private var lastCheckedPasteboardChange = -1

    var body: some View {
        MinimalNowPlayingView()
            // On launch: drop cached files orphaned by deletions, resume unfinished ingestion,
            // then bring back the previous playback session (or stage the first-run track).
            .task {
                // Sync-driven deletions must clear the live queue before models are destroyed.
                prepQueue.onTracksDeleted = { [weak player] ids in
                    player?.handleDeleted(trackIDs: ids)
                }
                // Stems are prepared just-in-time for the play-queue neighborhood, not eagerly
                // for the whole library (CPU-hours + gigabytes). Wire before restore so the
                // restored session's tracks get their stems going immediately.
                player.onUpcomingTracks = { [weak prepQueue] tracks in
                    prepQueue?.ensureStems(for: tracks, in: modelContext)
                }
                LibraryCleanup.sweepOrphanedFiles(in: modelContext)
                prepQueue.resumePreparation(in: modelContext)
                restorePlaybackSession()
                // Launch-time polling pass over source-backed playlists (per-playlist opt-out).
                prepQueue.autoSyncIfNeeded(in: modelContext)
            }
            .onOpenURL(perform: handleIncomingLink)
            // `initial: true` covers cold launch; later .active transitions cover foregrounding.
            .onChange(of: scenePhase, initial: true) { _, phase in
                if phase == .active {
                    // Explicit share beats a stale clipboard hit for the confirmation slot.
                    consumePendingSharedURL()
                    checkClipboardForImportableLink()
                }
            }
            .alert(
                Text(pendingImport.map { "Import from \($0.link.sourceName)?" } ?? "Import?"),
                isPresented: Binding(
                    get: { pendingImport != nil },
                    set: { if !$0 { pendingImport = nil } }
                ),
                presenting: pendingImport
            ) { pending in
                Button("Import") { startImport(pending) }
                Button("Cancel", role: .cancel) {}
            } message: { pending in
                Text(pending.host)
            }
            .alert(
                "Import Failed",
                isPresented: Binding(
                    get: { importError != nil },
                    set: { if !$0 { importError = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError ?? "")
            }
    }

    // MARK: - Link handling

    /// `continuity://import?url=<encoded target>` carries the real link; a directly-shared
    /// http(s) URL *is* the link. Anything unclassifiable is silently ignored.
    private func handleIncomingLink(_ url: URL) {
        let raw: String
        if url.scheme?.lowercased() == "continuity" {
            guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let target = comps.queryItems?.first(where: { $0.name == "url" })?.value,
                  !target.isEmpty else { return }
            raw = target
        } else {
            raw = url.absoluteString
        }
        guard let link = LinkImporter.classify(raw) else { return }
        offer(link, rawURL: raw)
    }

    /// Picks up a URL stashed by the share extension (written to group defaults because the
    /// extension can't talk to the app directly). Read-and-clear so each share is offered once.
    private func consumePendingSharedURL() {
        guard pendingImport == nil else { return }
        // Nil suite (missing app-group entitlement) degrades to a no-op rather than crashing.
        guard let defaults = UserDefaults(suiteName: "group.com.continuity.app") else { return }
        guard let payload = defaults.dictionary(forKey: "pendingSharedURL.v1"),
              let raw = payload["url"] as? String else { return }
        defaults.removeObject(forKey: "pendingSharedURL.v1")
        guard let link = LinkImporter.classify(raw) else { return }
        offer(link, rawURL: raw)
    }

    /// Offers to import a YouTube/Spotify link sitting on the clipboard. Pattern detection is
    /// banner-free; the one `.string` read (only after detection says it's a URL) shows the
    /// iOS paste notice, which is acceptable for a confirmed hit.
    private func checkClipboardForImportableLink() {
        guard pendingImport == nil else { return }   // don't stomp a link-open confirmation
        let pasteboard = UIPasteboard.general
        // changeCount is banner-free: inspect each clipboard generation once, else the
        // `.string` read below would flash the paste banner on every foreground.
        guard pasteboard.changeCount != lastCheckedPasteboardChange else { return }
        lastCheckedPasteboardChange = pasteboard.changeCount
        guard pasteboard.hasStrings || pasteboard.hasURLs else { return }
        Task {
            guard let patterns = try? await pasteboard.detectedPatterns(for: [\.probableWebURL]),
                  patterns.contains(\.probableWebURL),
                  let raw = (pasteboard.string ?? pasteboard.url?.absoluteString)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  raw != lastOfferedClipboardURL,
                  let link = LinkImporter.classify(raw) else { return }
            lastOfferedClipboardURL = raw
            offer(link, rawURL: raw)
        }
    }

    private func offer(_ link: LinkImporter.Link, rawURL: String) {
        // First confirmation wins — replacing the item under a presented alert would leave it
        // showing (and importing) stale captured data. Covers the async clipboard task racing
        // a link-open, and a second link-open while the alert is up.
        guard pendingImport == nil else { return }
        let host = URLComponents(string: rawURL.contains("://") ? rawURL : "https://" + rawURL)?
            .host ?? link.sourceName
        pendingImport = PendingLinkImport(link: link, rawURL: rawURL, host: host)
    }

    /// Same import path AddMusicView uses; failures surface in the "Import Failed" alert.
    private func startImport(_ pending: PendingLinkImport) {
        Task {
            do {
                try await LinkImporter.run(
                    pending.link, sourceURL: pending.rawURL, queue: prepQueue, in: modelContext
                )
            } catch {
                importError = LinkImporter.errorMessage(error, noun: pending.link.noun)
            }
        }
    }

    // MARK: - Session restore

    /// Restores the persisted session — same song, position, skip budget, and history — or, on a
    /// fresh install, stages COMË N GO paused at the start of its playlist.
    private func restorePlaybackSession() {
        guard player.currentTrack == nil else { return }   // already playing (e.g. state restore re-entry)
        let tracks = (try? modelContext.fetch(FetchDescriptor<Track>())) ?? []

        if let state = PlaybackStateStore.load() {
            let byID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
            player.restore(state, resolving: byID)
            if player.currentTrack != nil { return }
            // Every persisted track was deleted — fall through to the first-run seed.
        }

        // First launch (or an emptied library): COMË N GO is always the first song. Prefer the
        // real ingested track over the demo of the same name; queue its whole playlist from there.
        let candidates = tracks.filter { $0.title.localizedCaseInsensitiveContains("COMË N GO") }
        guard let seed = candidates.first(where: { !$0.isDemo }) ?? candidates.first,
              let playlist = seed.playlist else { return }
        let queue = playlist.orderedTracks
        guard let index = queue.firstIndex(where: { $0.id == seed.id }) else { return }
        player.prepare(tracks: queue, startAt: index)
    }
}

/// A classified link waiting for the user's "Import" confirmation.
private struct PendingLinkImport: Identifiable {
    let id = UUID()
    let link: LinkImporter.Link
    let rawURL: String
    let host: String
}
