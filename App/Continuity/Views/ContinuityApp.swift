import SwiftUI
import Ingest
import Playback
import Domain
import SwiftData
import os

@main
struct ContinuityApp: App {
    let container: ModelContainer
    @State private var player = Player()
    /// Drives YouTube ingestion (resolve → download → ready) for newly added tracks.
    @State private var prepQueue = PreparationQueue()

    init() {
        // First: arm crash forensics (dirty-session marker + MetricKit) before anything that
        // could itself crash. Cheap — one small file write and a subscriber registration.
        CrashDiagnostics.shared.start()
        Self.configureURLCache()
        let schema = Schema([Playlist.self, Track.self, TransitionVote.self])
        // Pin the store to the app container. `groupContainer` defaults to `.automatic`,
        // which (with our share-extension app group entitlement) put SwiftData in the
        // group container — unused by the extension, noisy on first launch, and desynced
        // from the `UserDefaults.standard` seed flag.
        Self.migrateStoreOutOfAppGroupIfNeeded()
        let container = Self.makeContainer(schema: schema)
        // Seeding latches a defaults flag; doing it into the throwaway in-memory library would
        // leave the real store unseeded once it opens again.
        if !LibraryStore.isDegraded {
            SampleData.seed(into: container.mainContext)
        }
        self.container = container
    }

    /// Opens the persistent library, degrading instead of crashing when it can't.
    ///
    /// This used to `fatalError` on any failure, and the failure modes here are persistent —
    /// a schema migration SwiftData can't perform, a damaged store, a full disk — so one bad
    /// store meant a crash on every launch with no way back in short of deleting the app (and
    /// with it every downloaded song). Now: one retry for a transient I/O failure, then an
    /// in-memory library for this launch. The on-disk store is left exactly as it was, so a
    /// build that fixes the cause opens it again; `LibraryStore.isDegraded` keeps destructive
    /// maintenance (the orphan-file sweep) from treating the empty stand-in as the truth.
    private static func makeContainer(schema: Schema) -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            groupContainer: .none
        )
        var lastError: Error?
        for attempt in 1...2 {
            do {
                return try ModelContainer(for: schema, configurations: configuration)
            } catch {
                lastError = error
                Logger.crash.fault("library store open failed (attempt \(attempt, privacy: .public)): \(String(describing: error), privacy: .public)")
            }
        }
        LibraryStore.markDegraded(reason: lastError.map { String(describing: $0) } ?? "unknown error")
        do {
            let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            return try ModelContainer(for: schema, configurations: memory)
        } catch {
            // An in-memory store failing means the schema itself is unusable — nothing to fall back to.
            fatalError("Failed to create even an in-memory ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(player)
                .environment(prepQueue)
        }
        .modelContainer(container)
    }

    /// The app is artwork-heavy: every library row, the mini player, Now Playing and the
    /// backdrop all pull covers over the network. The default shared cache is small enough that
    /// scrolling a library re-downloads thumbnails it fetched seconds earlier, so size it for
    /// the working set. (Decoded images are cached separately and bounded by
    /// `ArtworkImageStore`; this is the encoded-bytes tier underneath it.)
    private static func configureURLCache() {
        URLCache.shared = URLCache(
            memoryCapacity: 16 * 1024 * 1024,
            diskCapacity: 256 * 1024 * 1024
        )
    }

    /// One-time move of an existing app-group SwiftData store into Application Support so
    /// libraries built before `groupContainer: .none` aren't orphaned beside an empty new store.
    ///
    /// Latched in defaults once it has run: resolving the app-group container URL and probing
    /// for the legacy store is filesystem work on every cold launch, forever, to answer a
    /// question that can only change once.
    private static func migrateStoreOutOfAppGroupIfNeeded() {
        let migrationKey = "didMigrateStoreOutOfAppGroup.v1"
        if UserDefaults.standard.bool(forKey: migrationKey) { return }
        defer { UserDefaults.standard.set(true, forKey: migrationKey) }
        let fm = FileManager.default
        guard let groupRoot = fm.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.sanylax.continuity"
        ),
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return }

        let legacyDir = groupRoot.appendingPathComponent("Library/Application Support", isDirectory: true)
        let legacyStore = legacyDir.appendingPathComponent("default.store")
        let appStore = appSupport.appendingPathComponent("default.store")
        guard fm.fileExists(atPath: legacyStore.path),
              !fm.fileExists(atPath: appStore.path) else { return }

        try? fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
        for name in ["default.store", "default.store-wal", "default.store-shm"] {
            let src = legacyDir.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path) else { continue }
            try? fm.moveItem(at: src, to: appSupport.appendingPathComponent(name))
        }
    }
}

/// Whether this launch is running on the real library. Set once during `ContinuityApp.init`.
@MainActor
enum LibraryStore {
    /// True when the on-disk store couldn't be opened and an empty in-memory library stands in
    /// for it. Nothing the user does this session is saved, and anything that deletes files
    /// based on "what the library references" must not run.
    private(set) static var isDegraded = false
    /// The open error, for the in-app alert and the diagnostics log.
    private(set) static var degradedReason: String?

    static func markDegraded(reason: String) {
        isDegraded = true
        degradedReason = reason
    }
}
