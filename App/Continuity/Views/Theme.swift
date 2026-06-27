import SwiftUI

/// Lightweight visual helpers: deterministic artwork gradients from a seed, time formatting,
/// and a centralised Liquid Glass modifier so the iOS 26 API lives in exactly one place.
enum Theme {
    /// A pleasant two/three-stop gradient derived deterministically from a seed.
    static func gradient(seed: Int) -> LinearGradient {
        let palettes: [[Color]] = [
            [Color(red: 0.45, green: 0.26, blue: 0.90), Color(red: 0.92, green: 0.32, blue: 0.62)],
            [Color(red: 0.10, green: 0.52, blue: 0.86), Color(red: 0.16, green: 0.82, blue: 0.74)],
            [Color(red: 0.95, green: 0.45, blue: 0.20), Color(red: 0.92, green: 0.74, blue: 0.20)],
            [Color(red: 0.18, green: 0.20, blue: 0.34), Color(red: 0.40, green: 0.46, blue: 0.66)],
            [Color(red: 0.86, green: 0.20, blue: 0.40), Color(red: 0.36, green: 0.16, blue: 0.52)],
        ]
        let colors = palettes[abs(seed) % palettes.count]
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// mm:ss formatting for the transport clock.
    static func time(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

extension View {
    /// Continuity's standard Liquid Glass surface. Centralised so the exact iOS 26
    /// `glassEffect` API is touched in one spot.
    func continuityGlass(cornerRadius: CGFloat = 22) -> some View {
        self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// Reusable square artwork tile (gradient + SF Symbol) used by cards, rows and Now Playing.
struct ArtworkView: View {
    let symbol: String
    let seed: Int
    var cornerRadius: CGFloat = 16

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Theme.gradient(seed: seed))
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .shadow(radius: 6, y: 2)
            )
    }
}
