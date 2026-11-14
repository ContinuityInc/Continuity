import Foundation

/// Pure geometry helpers for iPhone Duo (and any resizable iPhone window).
///
/// Duo's inner display is wide, near-square, regular×regular, with the status bar on the
/// **right** edge (asymmetric insets). The physical fold sits at the middle of the *panel*
/// (insets included), not the middle of the safe area. Layout decisions come from measured
/// size + insets — never idiom, orientation, or `UIScreen`. Pure Foundation so Linux CI can
/// pin the numbers; views re-read them on every resize (fold/unfold).
public enum DuoLayout {
    /// Readable content column — Apple's HIG-ish width, below the ~867pt of an unfolded Duo.
    public static let readableColumnMaxWidth: Double = 640
    /// Minimum top chrome clearance when the top safe-area inset collapses to ~0 (Duo inner /
    /// landscape phones). On a normal portrait iPhone the inset already covers this.
    public static let minimumTopChrome: Double = 24
    /// Library card minimum; used to count fold-aware columns.
    public static let libraryCardMinimum: Double = 150
    public static let libraryCardSpacing: Double = 16
    /// Wide enough that a centered adaptive grid would put a card on the hinge.
    public static let foldAwareGridMinWidth: Double = 700

    /// Extra top padding needed so chrome clears the display edge when `topInset` is short.
    public static func extraTopChrome(topInset: Double, minimum: Double = minimumTopChrome) -> Double {
        guard topInset.isFinite, minimum.isFinite else { return minimumTopChrome }
        return max(0, minimum - max(0, topInset))
    }

    /// Full-window page height when a `GeometryReader` sits *inside* the safe area while its
    /// `ScrollView` ignores it. `proxy.size.height` is then short by exactly the vertical insets
    /// it reports; adding them back makes each page (and the shared backdrop) match the window
    /// that `containerRelativeFrame(.vertical)` tiles into. Non-finite insets clamp to 0; a
    /// non-finite safe-area height yields 0 so callers never feed SwiftUI a NaN frame.
    public static func pageHeight(
        safeAreaHeight: Double,
        topInset: Double,
        bottomInset: Double
    ) -> Double {
        guard safeAreaHeight.isFinite else { return 0 }
        let top = topInset.isFinite ? max(0, topInset) : 0
        let bottom = bottomInset.isFinite ? max(0, bottomInset) : 0
        let height = safeAreaHeight + top + bottom
        guard height.isFinite, height > 0 else { return 0 }
        return height
    }

    /// X of the physical fold in the *content* coordinate space (origin at the leading content
    /// edge, after the leading safe-area inset has already been applied).
    ///
    /// Duo unfolded landscape example (content 867 × 553, trailing inset 84, leading 0):
    /// full panel = 951, middle = 475.5, content midX = 475.5.
    public static func foldContentMidX(
        contentWidth: Double,
        leadingInset: Double,
        trailingInset: Double
    ) -> Double? {
        guard contentWidth.isFinite, contentWidth > 0,
              leadingInset.isFinite, trailingInset.isFinite else { return nil }
        let fullWidth = contentWidth + max(0, leadingInset) + max(0, trailingInset)
        guard fullWidth > 0 else { return nil }
        let mid = fullWidth / 2 - max(0, leadingInset)
        guard mid.isFinite, mid > 0, mid < contentWidth else { return nil }
        return mid
    }

    /// Width of the pane to the right of the fold, in content coordinates.
    public static func rightPaneWidth(
        contentWidth: Double,
        leadingInset: Double,
        trailingInset: Double
    ) -> Double? {
        guard let mid = foldContentMidX(
            contentWidth: contentWidth,
            leadingInset: leadingInset,
            trailingInset: trailingInset
        ), contentWidth.isFinite else { return nil }
        let width = contentWidth - mid
        return width.isFinite && width > 0 ? width : nil
    }

    /// Whether a library-style adaptive grid should split around the fold instead of tiling
    /// cards across the hinge. Tall phone layouts, narrow windows, and outer-display tent
    /// landscape (wide-but-short, no physical fold) keep the normal adaptive grid.
    public static func usesFoldAwareGrid(width: Double, height: Double) -> Bool {
        guard width.isFinite, height.isFinite else { return false }
        guard width >= foldAwareGridMinWidth else { return false }
        // Book / inner-display shapes are near-square: at least ~as wide as tall, but not the
        // ultra-wide strip of a phone in landscape tent pose (no hinge there).
        guard width >= height * 0.85 else { return false }
        return height >= width * 0.55
    }

    /// Even column count for a fold-centered grid: the same number of flexible columns on each
    /// side of the hinge, with a widened central gutter. Falls back to a single adaptive column
    /// count when the fold can't be placed.
    ///
    /// `viewportWidth` / `viewportHeight` must be the *visible* window (ScrollView bounds),
    /// not the LazyVGrid's content size — a tall scrolling grid is always "taller than wide"
    /// and would permanently disable the fold split.
    public static func foldAwareColumnCount(
        viewportWidth: Double,
        viewportHeight: Double,
        leadingInset: Double,
        trailingInset: Double,
        minimum: Double = libraryCardMinimum,
        spacing: Double = libraryCardSpacing
    ) -> (perSide: Int, gutter: Double)? {
        guard usesFoldAwareGrid(width: viewportWidth, height: viewportHeight),
              let mid = foldContentMidX(
                  contentWidth: viewportWidth,
                  leadingInset: leadingInset,
                  trailingInset: trailingInset
              ),
              minimum.isFinite, minimum > 0,
              spacing.isFinite, spacing >= 0
        else { return nil }

        // Shorter side sets the usable half so both sides match.
        let half = min(mid, viewportWidth - mid)
        guard half.isFinite, half > minimum else { return nil }
        // Thin gutter for the hinge itself (a few points); spacing is added by the grid.
        let gutter = spacing + 8
        let usable = half - gutter / 2
        guard usable.isFinite, usable > 0 else { return nil }
        let perSide = max(1, Int((usable + spacing) / (minimum + spacing)))
        return (perSide, gutter)
    }

    /// Rounds a measured size to whole points so a live resize (fold animation) doesn't write
    /// a new `@State` on every sub-point frame.
    public static func roundedSize(width: Double, height: Double) -> (width: Double, height: Double) {
        let w = width.isFinite ? width.rounded() : 0
        let h = height.isFinite ? height.rounded() : 0
        return (w, h)
    }
}
