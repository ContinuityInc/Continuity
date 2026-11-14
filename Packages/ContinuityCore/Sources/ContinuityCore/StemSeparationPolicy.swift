import Foundation

/// Pure policy for *how much* of a track to stem-separate.
///
/// Vocal-aware transitions only need stems inside the blend windows — the outgoing track's
/// outro and the incoming track's intro. Separating the middle of a long mix/podcast burns
/// CPU-hours and stem-cache bytes for no blend benefit, while the streaming pipeline already
/// bounds peak RAM to O(window). This type decides the time ranges; Ingest owns running them.
///
/// Does **not** replace `StemSeparationBudget` headroom floors or ORT session options — those
/// stay load-bearing jetsam guards. This only scopes *which* audio gets fed to the separator.
public enum StemSeparationPolicy {

    /// Absolute backstop matching today's `OnnxStemSeparator` truncation (30 minutes).
    /// Streaming already bounds memory; this bounds disk + CPU-hours on pathological inputs.
    public static let absoluteMaxSeconds: Double = 1_800

    /// Longest blend the UI can request today ("Smooth" preset = 12 s). Edge width must cover
    /// at least this so stems exist for the whole crossfade.
    public static let designMaxBlendSeconds: Double = 12

    /// Padding beyond the blend on each edge (early seek into the blend, skip-button 5 s blend,
    /// beat-align settle). Keeps a little stem audio before/after the nominal fade.
    public static let edgeMarginSeconds: Double = 18

    /// Default edge half-width = design blend + margin (30 s).
    public static var defaultEdgeSeconds: Double {
        designMaxBlendSeconds + edgeMarginSeconds
    }

    /// How to carve a track into separation work.
    public enum Mode: String, Sendable, Equatable, CaseIterable {
        /// Separate a single prefix `[0, min(duration, maxSeconds))`.
        /// Matches the historical separator behaviour (truncate long inputs at the cap).
        case fullPrefix
        /// Separate only the head and tail edges needed for blends; skip the middle.
        /// When the two edges meet or overlap they collapse into one contiguous range.
        case edgesOnly
    }

    /// Planned ranges for one track, ready for an Ingest consumer.
    public struct Plan: Equatable, Sendable {
        public let mode: Mode
        /// Half-open second ranges within `[0, trackDuration)`, ordered ascending, non-overlapping.
        public let ranges: [Range<Double>]

        public init(mode: Mode, ranges: [Range<Double>]) {
            self.mode = mode
            self.ranges = ranges
        }

        /// Total seconds of audio that would be fed through the separator.
        public var totalSeconds: Double {
            ranges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
        }
    }

    // MARK: - Tier dials (extends AdaptiveQuality, not a parallel flag)

    /// Constrained tiers prefer edge-only work so ORT window count stays small under pressure.
    public static func mode(for tier: AdaptiveQualityTier) -> Mode {
        switch tier {
        case .full, .balanced: return .fullPrefix
        case .constrained: return .edgesOnly
        }
    }

    /// Cap on separation work. Never exceeds `absoluteMaxSeconds`. Lower on mid/low tiers so a
    /// long full-prefix job can't monopolise the single stem limiter on Air-class devices.
    ///
    /// These are policy knobs for future Ingest adoption — today's separator still uses
    /// `absoluteMaxSeconds` until wired. They do **not** change `StemSeparationBudget` floors.
    public static func maxSeparationSeconds(for tier: AdaptiveQualityTier) -> Double {
        switch tier {
        case .full: return absoluteMaxSeconds
        case .balanced: return 900
        case .constrained: return 600
        }
    }

    /// Edge half-width for a concrete blend duration. Non-finite / negative blend falls back to
    /// `designMaxBlendSeconds`; non-finite / negative margin falls back to `edgeMarginSeconds`.
    public static func edgeSeconds(
        blendDuration: Double,
        margin: Double = edgeMarginSeconds
    ) -> Double {
        let blend = positiveFinite(blendDuration) ?? designMaxBlendSeconds
        let pad = nonNegativeFinite(margin) ?? edgeMarginSeconds
        return blend + pad
    }

    /// Time ranges (seconds) that should be separated for a track of `trackDuration`.
    /// Empty when duration is unusable (non-finite, ≤ 0). Degenerate knobs sanitize rather than trap.
    public static func separationRanges(
        trackDuration: Double,
        mode: Mode,
        edgeSeconds: Double = defaultEdgeSeconds,
        maxSeconds: Double = absoluteMaxSeconds
    ) -> [Range<Double>] {
        guard let duration = positiveFinite(trackDuration) else { return [] }
        let cap = min(positiveFinite(maxSeconds) ?? absoluteMaxSeconds, absoluteMaxSeconds)
        guard cap > 0 else { return [] }

        switch mode {
        case .fullPrefix:
            let end = min(duration, cap)
            return end > 0 ? [0..<end] : []

        case .edgesOnly:
            let requestedEdge = positiveFinite(edgeSeconds) ?? defaultEdgeSeconds
            guard requestedEdge > 0 else { return [] }

            // Short enough that head+tail cover the whole track → one contiguous range,
            // but only when that range still fits the budget. Over budget must keep a
            // real outro edge (the point of edgesOnly) instead of a prefix that drops it.
            if duration <= requestedEdge * 2, duration <= cap {
                return [0..<duration]
            }

            // Half the budget per edge, never larger than the caller asked for. When we
            // skipped the merge because duration > cap, edge ≤ cap/2 < duration/2 so the
            // two ranges stay non-overlapping and total work ≤ cap.
            let edge = min(requestedEdge, cap / 2)
            guard edge > 0 else { return [] }

            let head = 0..<edge
            let tailStart = duration - edge
            let tail = tailStart..<duration
            return [head, tail]
        }
    }

    /// Convenience: tier + blend → mode, capped ranges, and total work seconds.
    public static func plan(
        trackDuration: Double,
        tier: AdaptiveQualityTier,
        blendDuration: Double = designMaxBlendSeconds
    ) -> Plan {
        let mode = mode(for: tier)
        let ranges = separationRanges(
            trackDuration: trackDuration,
            mode: mode,
            edgeSeconds: edgeSeconds(blendDuration: blendDuration),
            maxSeconds: maxSeparationSeconds(for: tier)
        )
        return Plan(mode: mode, ranges: ranges)
    }

    // MARK: - Sanitizers

    private static func positiveFinite(_ value: Double) -> Double? {
        guard value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func nonNegativeFinite(_ value: Double) -> Double? {
        guard value.isFinite, value >= 0 else { return nil }
        return value
    }
}
