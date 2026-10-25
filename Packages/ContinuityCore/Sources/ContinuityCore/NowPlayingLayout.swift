import Foundation

/// Picks the Now Playing arrangement from the space the page actually has.
///
/// iPhone Duo's inner display (and resizable iPhone Mirroring) hands an iPhone app a wide,
/// near-square window that can change size mid-session on fold/unfold, so the layout is decided
/// from the measured page size — never from idiom, orientation or `UIScreen` — and re-decided on
/// every resize. Pure Foundation so the thresholds are pinned by Linux tests.
public enum NowPlayingLayout {
    public enum Arrangement: Equatable, Sendable {
        /// Artwork above the controls — every phone-shaped window, including the Duo's outer display.
        case column
        /// Artwork beside the controls — wide windows such as the Duo's inner display.
        case sideBySide
    }

    /// Narrowest window that gets the side-by-side layout (the widest iPhone is 440pt).
    public static let sideBySideMinWidth: Double = 640
    /// Shortest window that still fits the full controls column (label, transition panel,
    /// scrubber, 108pt transport, chip) plus the chevron bands.
    public static let sideBySideMinHeight: Double = 520
    /// Cap on the single-column stack so the scrubber and transport don't stretch across a
    /// wide window that is too short for side-by-side.
    public static let columnMaxWidth: Double = 520
    /// Vertical band the page reserves for the Library / Up Next chevrons and the vote bar.
    public static let chromeBandHeight: Double = 44 + 96

    public static func arrangement(width: Double, height: Double) -> Arrangement {
        // A transient zero/NaN size during a fold must fall back to the phone layout, not trap
        // or pick a layout from garbage.
        guard width.isFinite, height.isFinite else { return .column }
        guard width >= sideBySideMinWidth, height >= sideBySideMinHeight else { return .column }
        // Only when the window is at least roughly square; a tall window keeps the column.
        return width >= height * 0.9 ? .sideBySide : .column
    }

    /// Largest artwork side for the arrangement, in points.
    public static func artworkMaxSide(_ arrangement: Arrangement, width: Double, height: Double) -> Double {
        switch arrangement {
        case .column:
            return width.isFinite && width >= 600 ? 360 : 280
        case .sideBySide:
            guard height.isFinite else { return 280 }
            return min(420, max(280, height - chromeBandHeight - 48))
        }
    }
}
