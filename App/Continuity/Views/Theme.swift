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

/// Immersive full-bleed backdrop built from the current track's album art: heavily blurred and
/// darkened with a depth scrim (top/bottom gradient + centre-luminous vignette) so white content
/// reads on any artwork. Shared by the minimal home and the full Now Playing surface so both
/// feel like the same room. Falls back to the deterministic gradient (demo tracks / no art).
struct AlbumBackdrop: View {
    let url: URL?
    let seed: Int

    /// Pre-blurred backdrop bitmap for the current URL (nil while loading → gradient shows).
    @State private var backdrop: UIImage?

    var body: some View {
        // A pre-blurred bitmap upscaled by the compositor, NOT a live `.blur(radius: 60,
        // opaque: true)`. The live blur forced a full-screen (~14 MB) offscreen rasterization
        // that re-rendered whenever this subtree invalidated — under a playing 20 Hz position
        // timer that render churn ramped memory until jetsam (see the OOM RCA). The bitmap is
        // rendered once per URL by BackdropRenderer (real gaussian on a 160 px working image),
        // so it matches the old blur's look at zero per-frame cost.
        ZStack {
            Theme.gradient(seed: seed)
            if let backdrop {
                // Color.clear takes exactly the proposed size; the scaledToFill image lives in
                // an overlay so its overflow can never widen this view's layout — an
                // unconstrained fill image inflates the ZStack past the screen and shoves the
                // page's centered content sideways.
                Color.clear
                    .overlay(
                        Image(uiImage: backdrop)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFill()
                    )
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.6), value: backdrop)
        .overlay(scrim)
        .clipped()
        .ignoresSafeArea()
        .task(id: url) {
            guard let url else { backdrop = nil; return }
            backdrop = await BackdropRenderer.image(for: url)
        }
    }

    /// Keeps the luminous centre while darkening the edges — legibility without a muddy flat wash.
    private var scrim: some View {
        ZStack {
            Color.black.opacity(0.26)
            LinearGradient(
                colors: [.black.opacity(0.4), .clear, .black.opacity(0.55)],
                startPoint: .top, endPoint: .bottom
            )
            RadialGradient(
                colors: [.clear, .black.opacity(0.38)],
                center: .center, startRadius: 80, endRadius: 560
            )
        }
    }
}

/// Renders and caches the pre-blurred backdrop bitmaps for `AlbumBackdrop`. A ONE-TIME render
/// per URL (cached): fetch the sharpest available artwork, scale-fill it into a small working
/// square, run a real gaussian pass, and let the compositor upscale the result full-screen.
/// Matches the look of the old live `.blur(radius: 60)` with zero per-frame offscreen rendering
/// (the live blur was the render churn behind the playback jetsam RCA).
@MainActor
enum BackdropRenderer {
    private static let cache = NSCache<NSURL, UIImage>()

    static func image(for url: URL) async -> UIImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        guard let source = await fetchBestArtwork(url) else { return nil }
        let rendered = await Task.detached(priority: .userInitiated) { render(source) }.value
        cache.setObject(rendered, forKey: url as NSURL)
        return rendered
    }

    /// YouTube thumbnails come in quality tiers; try the sharper variants first (they 404 for
    /// some videos), falling back to the stored URL. A sharper source keeps the blurred field
    /// smooth instead of blocky.
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

    /// Scale-fill into a 160 px square, then a real gaussian (clamped so edges don't darken).
    /// sigma 20 at 160 px upscaled to screen width ≈ the old radius-60 live blur.
    private nonisolated static func render(_ source: UIImage) -> UIImage {
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
            .applyingGaussianBlur(sigma: 20)
            .cropped(to: ci.extent)
        let context = CIContext(options: nil)
        guard let cg = context.createCGImage(blurred, from: blurred.extent) else { return small }
        return UIImage(cgImage: cg)
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
