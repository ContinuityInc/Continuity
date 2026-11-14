import Foundation

/// Converts untrusted millisecond lengths from scraped pages / service APIs into whole
/// seconds without trapping. `Int((ms / 1000).rounded())` aborts on `1e308` (and on ±inf /
/// NaN) — hostile or corrupted JSON must return `nil`, not kill the import.
public enum DurationParsing {

    /// Upper bound on a single track length we will believe (~11.5 days). Real music / mixes
    /// are far shorter; anything larger is treated as garbage rather than stored on a Track.
    public static let maxReasonableSeconds = 1_000_000

    /// `nil` when `ms` is non-finite, ≤ 0, or rounds outside `1...maxReasonableSeconds`.
    public static func seconds(fromMilliseconds ms: Double) -> Int? {
        guard ms.isFinite, ms > 0 else { return nil }
        let seconds = (ms / 1000).rounded()
        guard seconds.isFinite,
              seconds >= 1,
              seconds <= Double(maxReasonableSeconds) else { return nil }
        return Int(seconds)
    }

    /// Convenience for optional `NSNumber` payloads from `JSONSerialization`.
    public static func seconds(fromMillisecondsNumber number: NSNumber?) -> Int? {
        guard let number else { return nil }
        return seconds(fromMilliseconds: number.doubleValue)
    }
}
