import SwiftUI
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
            let schema = Schema([Playlist.self, Track.self])
            // Persistent on-disk store so imported playlists/tracks + their analysis survive
            // relaunches. Sample content is seeded exactly once (see SampleData.seed).
            let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
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
}
