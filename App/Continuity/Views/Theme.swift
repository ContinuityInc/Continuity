import SwiftUI
import UIKit
import CoreImage

/// Lightweight visual helpers: deterministic artwork gradients from a seed, time formatting,
/// and a centralised Liquid Glass modifier so the iOS 26 API lives in exactly one place.
enum Theme {
    /// The deterministic seed palette as raw `[top, bottom]` colors. Exposed so callers that
    /// need the individual edge colors (e.g. the pager backdrop's bleed fallback before the
    /// artwork palette resolves) share the exact same source as `gradient(seed:)`.
    static func gradientColors(seed: Int) -> [Color] {
        let palettes: [[Color]] = [
            [Color(red: 0.45, green: 0.26, blue: 0.90), Color(red: 0.92, green: 0.32, blue: 0.62)],
            [Color(red: 0.10, green: 0.52, blue: 0.86), Color(red: 0.16, green: 0.82, blue: 0.74)],
            [Color(red: 0.95, green: 0.45, blue: 0.20), Color(red: 0.92, green: 0.74, blue: 0.20)],
            [Color(red: 0.18, green: 0.20, blue: 0.34), Color(red: 0.40, green: 0.46, blue: 0.66)],
            [Color(red: 0.86, green: 0.20, blue: 0.40), Color(red: 0.36, green: 0.16, blue: 0.52)],
        ]
        return palettes[abs(seed) % palettes.count]
    }

    /// A pleasant two/three-stop gradient derived deterministically from a seed.
    static func gradient(seed: Int) -> LinearGradient {
        LinearGradient(colors: gradientColors(seed: seed), startPoint: .topLeading, endPoint: .bottomTrailing)
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

/// Immersive full-bleed backdrop built from the current track's album art — a hybrid of the
/// Apple Music and Spotify treatments: a smooth vertical gradient sampled from the artwork's
/// dominant colors as the base (guarantees full coverage + legibility), with a softly blurred
/// render of the art itself layered over it, dissolving into the gradient toward the bottom.
/// Everything is pre-rendered once per URL — zero per-frame cost (the old live blur was the
/// render churn behind the playback jetsam RCA). Falls back to the deterministic seed gradient
/// (demo tracks / no art).
struct AlbumBackdrop: View {
    let url: URL?
    let seed: Int

    /// Palette + pre-blurred art for the current URL (nil while loading).
    @State private var style: BackdropStyle?

    var body: some View {
        ZStack {
            if let style {
                LinearGradient(colors: style.colors, startPoint: .top, endPoint: .bottom)
                    .transition(.opacity)
                // The blurred art rides on top at partial opacity and fades out toward the
                // bottom, so the upper screen carries the artwork's texture while the lower
                // half settles into the clean gradient (the Apple Music look). Color.clear
                // contains the scaledToFill overflow so it can never affect layout.
                Color.clear
                    .overlay(
                        Image(uiImage: style.blurredArt)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFill()
                    )
                    .opacity(0.55)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .white, location: 0),
                                .init(color: .white, location: 0.45),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .transition(.opacity)
            } else {
                Theme.gradient(seed: seed).overlay(Color.black.opacity(0.35))
            }
        }
        .animation(.easeInOut(duration: 0.6), value: style)
        // Soft edge scrim: anchors the status bar and Up Next chevron, and keeps white content
        // legible over the blurred-art region.
        .overlay(
            LinearGradient(
                colors: [.black.opacity(0.3), .black.opacity(0.12), .black.opacity(0.35)],
                startPoint: .top, endPoint: .bottom
            )
        )
        .clipped()
        .ignoresSafeArea()
        .task(id: url) {
            guard let url else { style = nil; return }
            style = await BackdropRenderer.style(for: url)
        }
    }
}

/// Everything `AlbumBackdrop` needs for one artwork URL, pre-rendered off-main and cached.
struct BackdropStyle: Equatable {
    /// [top, bottom] tone-mapped gradient colors.
    let colors: [Color]
    /// Small gaussian-blurred render of the art (compositor-upscaled full-screen).
    let blurredArt: UIImage
}

/// Samples and caches the backdrop gradient palette for `AlbumBackdrop`: fetch the sharpest
/// available artwork tier, average the top and bottom halves (CIAreaAverage), then tone-map
/// both into the muted, dark range the reference apps use — hue preserved, saturation softened,
/// brightness pinned so white text always reads.
@MainActor
enum BackdropRenderer {
    private static var cache: [URL: BackdropStyle] = [:]

    static func style(for url: URL) async -> BackdropStyle? {
        if let hit = cache[url] { return hit }
        guard let source = await fetchBestArtwork(url) else { return nil }
        let style = await Task.detached(priority: .userInitiated) { () -> BackdropStyle? in
            guard let colors = samplePalette(source) else { return nil }
            return BackdropStyle(colors: colors, blurredArt: blurredRender(source))
        }.value
        guard let style else { return nil }
        cache[url] = style
        return style
    }

    /// Scale-fill into a 160 px square, then a real gaussian (clamped so edges don't darken) —
    /// the compositor upscale of the result reads as a soft radius-60-style blur. Rendered once
    /// per URL; never per frame.
    private nonisolated static func blurredRender(_ source: UIImage) -> UIImage {
        let side: CGFloat = 160
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let small = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            let s = source.size
            let scale = max(side / s.width, side / s.height)
            let w = s.width * scale, h = s.height * scale
            source.draw(in: CGRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h))
        }
        guard let ci = CIImage(image: small) else { return small }
        let blurred = ci.clampedToExtent()
            .applyingGaussianBlur(sigma: 16)
            .cropped(to: ci.extent)
        let context = CIContext(options: nil)
        guard let cg = context.createCGImage(blurred, from: blurred.extent) else { return small }
        return UIImage(cgImage: cg)
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
