import SwiftUI
import UIKit
import CoreImage

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

/// Immersive full-bleed backdrop built from the current track's album art — the Apple Music /
/// Spotify treatment: a smooth vertical gradient sampled from the artwork's dominant colors
/// (muted, dark enough for white content), NOT a stretched blurred image. A gradient has no
/// resolution, always fills the screen, and costs nothing per frame (the old live blur was the
/// render churn behind the playback jetsam RCA). Falls back to the deterministic seed gradient
/// (demo tracks / no art).
struct AlbumBackdrop: View {
    let url: URL?
    let seed: Int

    /// [top, bottom] colors sampled from the current URL's artwork (nil while loading).
    @State private var palette: [Color]?

    var body: some View {
        ZStack {
            if let palette {
                LinearGradient(colors: palette, startPoint: .top, endPoint: .bottom)
                    .transition(.opacity)
            } else {
                Theme.gradient(seed: seed).overlay(Color.black.opacity(0.35))
            }
        }
        .animation(.easeInOut(duration: 0.6), value: palette)
        // Soft edge scrim only: the palette is already tone-mapped for legibility; a light
        // top/bottom darkening anchors the status bar and Up Next chevron.
        .overlay(
            LinearGradient(
                colors: [.black.opacity(0.25), .clear, .black.opacity(0.35)],
                startPoint: .top, endPoint: .bottom
            )
        )
        .ignoresSafeArea()
        .task(id: url) {
            guard let url else { palette = nil; return }
            palette = await BackdropRenderer.palette(for: url)
        }
    }
}

/// Samples and caches the backdrop gradient palette for `AlbumBackdrop`: fetch the sharpest
/// available artwork tier, average the top and bottom halves (CIAreaAverage), then tone-map
/// both into the muted, dark range the reference apps use — hue preserved, saturation softened,
/// brightness pinned so white text always reads.
@MainActor
enum BackdropRenderer {
    private static var cache: [URL: [Color]] = [:]

    static func palette(for url: URL) async -> [Color]? {
        if let hit = cache[url] { return hit }
        guard let source = await fetchBestArtwork(url) else { return nil }
        let colors = await Task.detached(priority: .userInitiated) { samplePalette(source) }.value
        guard let colors else { return nil }
        cache[url] = colors
        return colors
    }

    /// YouTube thumbnails come in quality tiers; try the sharper variants first (they 404 for
    /// some videos), falling back to the stored URL.
    private static func fetchBestArtwork(_ url: URL) async -> UIImage? {
        var candidates: [URL] = []
        let raw = url.absoluteString
        if raw.contains("/hqdefault") {
            for tier in ["/maxresdefault", "/sddefault"] {
                if let upgraded = URL(string: raw.replacingOccurrences(of: "/hqdefault", with: tier)) {
                    candidates.append(upgraded)
                }
            }
        }
        candidates.append(url)
        for candidate in candidates {
            guard let (data, response) = try? await URLSession.shared.data(from: candidate) else { continue }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { continue }
            if let image = UIImage(data: data) { return image }
        }
        return nil
    }

    /// [top, bottom] gradient colors: average color of the artwork's top and bottom halves,
    /// tone-mapped into the dark, slightly muted band the Spotify/Apple Music backdrops live in.
    private nonisolated static func samplePalette(_ image: UIImage) -> [Color]? {
        guard let ci = CIImage(image: image) else { return nil }
        let extent = ci.extent
        let topHalf = CGRect(x: extent.minX, y: extent.midY, width: extent.width, height: extent.height / 2)
        let bottomHalf = CGRect(x: extent.minX, y: extent.minY, width: extent.width, height: extent.height / 2)
        guard let top = averageColor(ci, in: topHalf),
              let bottom = averageColor(ci, in: bottomHalf) else { return nil }
        return [toneMapped(top, brightness: 0.45), toneMapped(bottom, brightness: 0.14)]
    }

    private nonisolated static func averageColor(_ image: CIImage, in rect: CGRect) -> UIColor? {
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: image,
            kCIInputExtentKey: CIVector(cgRect: rect),
        ]), let output = filter.outputImage else { return nil }
        var bitmap = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        context.render(output, toBitmap: &bitmap, rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return UIColor(red: CGFloat(bitmap[0]) / 255, green: CGFloat(bitmap[1]) / 255,
                       blue: CGFloat(bitmap[2]) / 255, alpha: 1)
    }

    /// Keep the hue, soften the saturation, and PIN the brightness — sampled art can be
    /// near-white or near-black, and the backdrop must stay in a band where white content is
    /// always legible and the gradient always reads as "colored dark", never washed out.
    private nonisolated static func toneMapped(_ color: UIColor, brightness: CGFloat) -> Color {
        var hue: CGFloat = 0, saturation: CGFloat = 0, currentBrightness: CGFloat = 0, alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &currentBrightness, alpha: &alpha)
        return Color(hue: hue, saturation: min(saturation * 0.9, 0.55), brightness: brightness)
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

/// Artwork tile that shows real remote cover art when available (YouTube thumbnail), falling
/// back to the gradient `ArtworkView` while loading or when there is none (demo tracks).
struct RemoteArtworkView: View {
    let url: URL?
    let symbol: String
    let seed: Int
    var cornerRadius: CGFloat = 16
    /// Every remote thumbnail we use is YouTube's hqdefault: a 4:3 frame with the 16:9 video
    /// letterboxed inside (baked black bars, 12.5% top + bottom). Zooming the image by 4/3 pushes
    /// those bars outside the clip so tiles show only the picture — on by default because it's true
    /// of all our art. Aspect ratio is preserved (uniform scale). The gradient/symbol fallback
    /// (no URL / still loading) is a real square and is unaffected.
    var cropsLetterbox: Bool = true

    var body: some View {
        if let url {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    // YouTube thumbs are 4:3 with letterboxing; fill the square tile.
                    Color.clear.overlay(
                        image.resizable().scaledToFill()
                            .scaleEffect(cropsLetterbox ? 4.0 / 3.0 : 1)
                    )
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                        // clipShape trims pixels but NOT hit-testing: the scaledToFill (and
                        // letterbox-zoom) overflow would otherwise extend the enclosing
                        // button/row's tap area far past the visible tile.
                        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                } else {
                    ArtworkView(symbol: symbol, seed: seed, cornerRadius: cornerRadius)
                }
            }
        } else {
            ArtworkView(symbol: symbol, seed: seed, cornerRadius: cornerRadius)
        }
    }
}
