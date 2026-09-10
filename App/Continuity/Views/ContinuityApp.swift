import SwiftUI
import Ingest
import Playback
import Domain
import SwiftData

@main
struct ContinuityApp: App {
    let container: ModelContainer
    @State private var player = Player()
    /// Drives YouTube ingestion (resolve → download → ready) for newly added tracks.
    @State private var prepQueue = PreparationQueue()

    init() {
        Self.configureURLCache()
        do {
            let schema = Schema([Playlist.self, Track.self, TransitionVote.self])
            // Pin the store to the app container. `groupContainer` defaults to `.automatic`,
            // which (with our share-extension app group entitlement) put SwiftData in the
            // group container — unused by the extension, noisy on first launch, and desynced
            // from the `UserDefaults.standard` seed flag.
            Self.migrateStoreOutOfAppGroupIfNeeded()
            let configuration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                groupContainer: .none
            )
            let container = try ModelContainer(for: schema, configurations: configuration)
            SampleData.seed(into: container.mainContext)
            self.container = container
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
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
