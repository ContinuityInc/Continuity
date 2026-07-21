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

    /// One-time move of an existing app-group SwiftData store into Application Support so
    /// libraries built before `groupContainer: .none` aren't orphaned beside an empty new store.
    private static func migrateStoreOutOfAppGroupIfNeeded() {
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
