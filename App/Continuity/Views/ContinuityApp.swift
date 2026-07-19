import SwiftUI
import Ingest
import Playback
import Domain
import SwiftData

@main
struct ContinuityApp: App {
    let container: ModelContainer
    @State private var player = Player()
    /// Drives local-file ingestion (import → analyse → ready) for newly added tracks.
    @State private var prepQueue = PreparationQueue()

    init() {
        do {
            let schema = Schema([Playlist.self, Track.self])
            // Pin the store to the app container explicitly.
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
}
