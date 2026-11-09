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
    /// Cap for the in-app search keyboard key grid (the opaque plane still spans full width).
    public static let keyboardMaxWidth: Double = 640
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
    /// cards across the hinge. Tall phone layouts and narrow windows keep the normal grid.
    public static func usesFoldAwareGrid(width: Double, height: Double) -> Bool {
        guard width.isFinite, height.isFinite else { return false }
        guard width >= foldAwareGridMinWidth else { return false }
        // Book / inner-display shapes are at least as wide as they are tall (or close).
        return width >= height * 0.85
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
