import SwiftUI
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
            // M0 uses an in-memory store seeded with sample data. M1 switches to a
            // persistent configuration once real ingested content needs to survive launches.
            let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
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
