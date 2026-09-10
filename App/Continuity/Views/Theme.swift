import SwiftUI
import UIKit
import ImageIO
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

// MARK: - Liquid Glass

extension View {
    /// Continuity's standard Liquid Glass surface. Centralised so the exact iOS 26
    /// `glassEffect` API is touched in one spot.
    ///
    /// Everything glass-looking in the app goes through this (or `continuityGlassCapsule`) —
    /// no `Material` stand-ins. A material is a static blur+vibrancy layer; Liquid Glass is a
    /// real system effect that refracts what's behind it, reacts to motion, and — inside a
    /// `GlassEffectContainer` — is composited for the whole group in one pass.
    func continuityGlass(cornerRadius: CGFloat = 22, interactive: Bool = false) -> some View {
        self.glassEffect(interactive ? .regular.interactive() : .regular,
                         in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// Capsule-shaped Liquid Glass — the pill/badge/chip form of `continuityGlass`.
    func continuityGlassCapsule(interactive: Bool = false) -> some View {
        self.glassEffect(interactive ? .regular.interactive() : .regular, in: Capsule())
    }
}

// MARK: - Image decoding

/// Shared image decode helpers. Every artwork path in the app funnels through here so nothing
/// ever decodes a full-resolution bitmap for a 44 pt row (a 1400 px embedded cover is ~7.8 MB
/// of RAM; the thumbnail it's drawn at is ~70 KB).
enum ArtworkDecoder {
    /// Decodes `data` directly at a bounded size via ImageIO, rather than decoding full-size
    /// and letting the compositor scale it down.
    static func image(from data: Data, maxPixel: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return UIImage(data: data)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            // Decode now, on this background thread — not lazily on the main thread at draw time.
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImage)
    }

    /// Loads bytes for a remote or on-disk artwork URL.
    static func data(for url: URL) async -> Data? {
        if url.isFileURL {
            return try? Data(contentsOf: url, options: .mappedIfSafe)
        }
        guard let (data, response) = try? await URLSession.shared.data(from: url) else { return nil }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return nil }
        return data
    }

    /// Rough decoded-bitmap size, for NSCache cost accounting.
    static func byteCost(_ image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 1 }
        return max(1, cgImage.bytesPerRow * cgImage.height)
    }
}

/// Process-wide CoreImage context. Building one per render compiles the filter kernels and
/// allocates its backing resources every time — hundreds of milliseconds of setup to run a
/// 160 px blur. `CIContext` is documented as thread-safe, so one instance serves every caller.
enum SharedCIContext {
    static let shared = CIContext(options: [.workingColorSpace: NSNull()])
}

/// Bounded, shared, decoded-artwork cache behind every artwork view in the app.
///
/// This replaces `AsyncImage`, which caches nothing of its own: each row that scrolled back
/// into view re-hit the network stack and re-decoded the JPEG, and the same cover shown in a
/// list row, the mini player and Now Playing decoded three times over. Here one decode per URL
/// is shared by every view, bounded by count and bytes, and dropped automatically under memory
/// pressure (NSCache) so it can never contribute to a jetsam.
@MainActor
final class ArtworkImageStore {
    static let shared = ArtworkImageStore()

    /// Artwork is drawn at most at Now Playing's 280 pt (≈840 px on a 3× screen); anything
    /// larger is bytes we pay for and never see.
    private static let maxPixelSize: CGFloat = 900

    private let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 180
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    /// One load per URL even when several views ask at once (a track's cover is typically
    /// requested by a row, the mini player and Now Playing in the same frame).
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]

    private init() {}

    /// Synchronous cache hit, so a re-created row draws its art immediately instead of
    /// flashing the placeholder for a frame.
    func cachedImage(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func image(for url: URL) async -> UIImage? {
        if let hit = cachedImage(for: url) { return hit }
        if let existing = inFlight[url] { return await existing.value }

        let maxPixel = Self.maxPixelSize
        let task = Task { () -> UIImage? in
            await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let data = await ArtworkDecoder.data(for: url) else { return nil }
                return ArtworkDecoder.image(from: data, maxPixel: maxPixel)
            }.value
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image {
            cache.setObject(image, forKey: url as NSURL, cost: ArtworkDecoder.byteCost(image))
        }
        return image
    }
}

// MARK: - Backdrop

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
            let resolved = await BackdropRenderer.style(for: url)
            // The render is shared between backdrops and deliberately outlives any one view's
            // task, so cancellation doesn't reach it — check here instead. Without this, a slow
            // fetch for the previous track can land after the next track's (cached, instant)
            // one and repaint the screen in the wrong song's colors.
            guard !Task.isCancelled else { return }
            style = resolved
        }
    }
}

/// Everything `AlbumBackdrop` needs for one artwork URL, pre-rendered off-main and cached.
struct BackdropStyle: Equatable {
    /// [top, bottom] tone-mapped gradient colors.
    let colors: [Color]
    /// Small gaussian-blurred render of the art (compositor-upscaled full-screen).
    let blurredArt: UIImage

    /// Identity comparison on the image: styles are cached per URL and handed out as the same
    /// instance, so pointer equality is exact here — and it avoids `UIImage.isEqual`, which can
    /// fall through to comparing pixel data on every SwiftUI diff.
    static func == (lhs: BackdropStyle, rhs: BackdropStyle) -> Bool {
        lhs.colors == rhs.colors && lhs.blurredArt === rhs.blurredArt
    }
}

/// Samples and caches the backdrop gradient palette for `AlbumBackdrop`: fetch the sharpest
/// available artwork tier, average the top and bottom halves (CIAreaAverage), then tone-map
/// both into the muted, dark range the reference apps use — hue preserved, saturation softened,
/// brightness pinned so white text always reads.
@MainActor
enum BackdropRenderer {
    /// Bounded and purgeable. The old plain dictionary held one blurred `UIImage` per artwork
    /// URL played, for the life of the process, and never gave anything back under memory
    /// pressure — a slow leak on exactly the resource the jetsam RCA was fighting for.
    private static let cache: NSCache<NSURL, CachedBackdropStyle> = {
        let cache = NSCache<NSURL, CachedBackdropStyle>()
        cache.countLimit = 32
        return cache
    }()

    /// Renders in flight, keyed by URL. `AlbumBackdrop` and `PagerBackdrop` request the SAME
    /// url in the same frame (the pager hosts one inside the other), so without coalescing
    /// every track change ran two artwork downloads and two gaussian renders to throw one away.
    private static var inFlight: [URL: Task<BackdropStyle?, Never>] = [:]

    static func style(for url: URL) async -> BackdropStyle? {
        if let hit = cache.object(forKey: url as NSURL) { return hit.style }
        if let existing = inFlight[url] { return await existing.value }

        let task = Task { () -> BackdropStyle? in
            guard let source = await fetchBestArtwork(url) else { return nil }
            return await Task.detached(priority: .userInitiated) { () -> BackdropStyle? in
                guard let colors = samplePalette(source) else { return nil }
                return BackdropStyle(colors: colors, blurredArt: blurredRender(source))
            }.value
        }
        inFlight[url] = task
        let style = await task.value
        inFlight[url] = nil

        guard let style else { return nil }
        cache.setObject(CachedBackdropStyle(style), forKey: url as NSURL)
        return style
    }

    /// NSCache stores objects, so the value struct rides in a box.
    private final class CachedBackdropStyle {
        let style: BackdropStyle
        init(_ style: BackdropStyle) { self.style = style }
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
        guard let cg = SharedCIContext.shared.createCGImage(blurred, from: blurred.extent) else { return small }
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
            guard let data = await ArtworkDecoder.data(for: candidate) else { continue }
            // Bounded decode: the palette is an area average and the blur renders at 160 px, so
            // fully decoding a 1280×720 maxres frame (≈3.7 MB of bitmap) buys nothing.
            if let image = ArtworkDecoder.image(from: data, maxPixel: 512) { return image }
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
        SharedCIContext.shared.render(output, toBitmap: &bitmap, rowBytes: 4,
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

// MARK: - Artwork tiles

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

/// Artwork tile that shows real cover art when available (a YouTube thumbnail, or artwork
/// extracted from an imported file), falling back to the gradient `ArtworkView` while loading
/// or when there is none (demo tracks).
struct RemoteArtworkView: View {
    let url: URL?
    let symbol: String
    let seed: Int
    var cornerRadius: CGFloat = 16
    /// Remote thumbnails are YouTube's hqdefault: a 4:3 frame with the 16:9 video letterboxed
    /// inside (baked black bars, 12.5% top + bottom). Zooming the image by 4/3 pushes those bars
    /// outside the clip so tiles show only the picture. Aspect ratio is preserved (uniform
    /// scale). Artwork extracted from an imported file is a real cover, not a video frame, so
    /// the zoom is applied to remote thumbnails only — cropping 12.5% off a real album cover
    /// loses picture. The gradient/symbol fallback is a real square and is unaffected.
    var cropsLetterbox: Bool = true

    var body: some View {
        if let url {
            CachedArtworkImage(
                url: url,
                cornerRadius: cornerRadius,
                // A file URL is embedded cover art, never a letterboxed video frame.
                cropsLetterbox: cropsLetterbox && !url.isFileURL
            ) {
                ArtworkView(symbol: symbol, seed: seed, cornerRadius: cornerRadius)
            }
        } else {
            ArtworkView(symbol: symbol, seed: seed, cornerRadius: cornerRadius)
        }
    }
}

/// Draws one artwork URL through `ArtworkImageStore` — a shared decode, a bounded cache, and a
/// synchronous cache hit so recycled rows never flash their placeholder.
struct CachedArtworkImage<Placeholder: View>: View {
    let url: URL
    let cornerRadius: CGFloat
    let cropsLetterbox: Bool
    @ViewBuilder let placeholder: Placeholder

    @State private var loaded: UIImage?

    var body: some View {
        Group {
            if let image = loaded ?? ArtworkImageStore.shared.cachedImage(for: url) {
                Color.clear.overlay(
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .scaleEffect(cropsLetterbox ? 4.0 / 3.0 : 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                // clipShape trims pixels but NOT hit-testing: the scaledToFill (and
                // letterbox-zoom) overflow would otherwise extend the enclosing button/row's
                // tap area far past the visible tile.
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                placeholder
            }
        }
        .task(id: url) {
            if let hit = ArtworkImageStore.shared.cachedImage(for: url) {
                loaded = hit
                return
            }
            let image = await ArtworkImageStore.shared.image(for: url)
            // Loads are shared across every view asking for this URL, so they outlive this
            // view's task; a recycled row must not adopt the image its previous track asked for.
            guard !Task.isCancelled else { return }
            loaded = image
        }
    }
}
