import Foundation
import SwiftData

/// Seeds an in-memory library for M0 so the UI has playlists/albums to browse and play
/// (synthesised audio). Replaced in M1 by real YouTube-sourced content + persistence.
enum SampleData {

    @MainActor
    static func seed(into context: ModelContext) {
        // Avoid double-seeding if called more than once.
        let existing = try? context.fetch(FetchDescriptor<Playlist>())
        if let existing, !existing.isEmpty { return }

        for playlist in makePlaylists() {
            context.insert(playlist)
        }
        try? context.save()
    }

    static func makePlaylists() -> [Playlist] {
        [
            playlist(
                title: "Late Night Drive",
                subtitle: "Synthwave · 6 tracks",
                symbol: "moon.stars.fill",
                seed: 1,
                titles: [
                    ("Neon Mirage", "Aria Vance"),
                    ("Midnight Coast", "Lukas Vega"),
                    ("Afterglow", "Sora"),
                    ("Velvet Static", "The Lumen"),
                    ("Slow Horizon", "Noctis"),
                    ("Eastbound", "Aria Vance"),
                ]
            ),
            playlist(
                title: "Deep Focus",
                subtitle: "Ambient · 5 tracks",
                symbol: "brain.head.profile",
                seed: 2,
                titles: [
                    ("Glass Fields", "Ilan Brooke"),
                    ("Quiet Engine", "Mota"),
                    ("Tideline", "Ilan Brooke"),
                    ("Paper Rooms", "Senna"),
                    ("Long Exposure", "Mota"),
                ]
            ),
            playlist(
                title: "House Party",
                subtitle: "Deep House · 6 tracks",
                symbol: "party.popper.fill",
                seed: 3,
                titles: [
                    ("Pulse Theory", "Dovre"),
                    ("Get Closer", "Kaya M"),
                    ("Basement", "Dovre"),
                    ("Hold The Line", "Felix Orr"),
                    ("Sunrise Set", "Kaya M"),
                    ("Back Room", "Dovre"),
                ]
            ),
            playlist(
                title: "Morning Coffee",
                subtitle: "Jazz · 4 tracks",
                symbol: "cup.and.saucer.fill",
                seed: 4,
                titles: [
                    ("Slow Roast", "The Hale Trio"),
                    ("Window Seat", "Marisol"),
                    ("Second Pour", "The Hale Trio"),
                    ("Warm Front", "Marisol"),
                ]
            ),
        ]
    }

    private static func playlist(
        title: String,
        subtitle: String,
        symbol: String,
        seed: Int,
        titles: [(String, String)]
    ) -> Playlist {
        let list = Playlist(title: title, subtitle: subtitle, artworkSymbol: symbol, gradientSeed: seed)
        list.tracks = titles.enumerated().map { index, pair in
            Track(
                title: pair.0,
                artist: pair.1,
                // Short, varied durations so track changes are audible quickly while testing M0.
                durationSeconds: Double(24 + (index * 7) % 24),
                artworkSymbol: symbol,
                gradientSeed: seed * 10 + index,
                sortIndex: index
            )
        }
        return list
    }
}
