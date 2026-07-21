import Foundation
import ContinuityCore

/// Retries a transient-failing async operation with exponential backoff + jitter, coordinated
/// across the whole app by `IngestThrottle`.
///
/// Only `IngestError`s that report themselves `isRetryable` (network blips, rate limits, expired
/// stream URLs) are retried; a definitively-empty source or any other error propagates
/// immediately. The scraped endpoints (Spotify embed, YouTube playlist/search pages, YouTubeKit
/// extraction) fail transiently often enough that a single blip shouldn't surface to the user as
/// "playlist unavailable".
///
/// Two things matter here beyond "sleep and try again":
/// - **The gate is shared.** Every attempt waits on `IngestThrottle` first, so N concurrently
///   importing tracks back off together instead of each discovering the same rate limit alone.
/// - **The delay outlasts the throttle.** The previous schedule (0.7s then 1.4s) retried inside
///   the same window that had just rejected us, which extended the throttle and failed the track.
enum Retry {
    static func run<T>(
        // Bounded deliberately: this loop holds an `ingestLimiter` slot while it sleeps, so a
        // long rate-limit curve here would stall the import. Past this budget the *track-level*
        // backoff in `PreparationQueue.process` takes over, which retries without holding a slot.
        maxAttempts: Int = 4,
        policy: IngestBackoff.Policy = .request,
        _ operation: () async throws -> T
    ) async throws -> T {
        var attempt = 1
        while true {
            await IngestThrottle.shared.gate()
            do {
                let value = try await operation()
                await IngestThrottle.shared.noteSuccess()
                return value
            } catch let error as IngestError where error.isRetryable {
                // Tell the shared gate first — even on the final attempt, so sibling tracks that
                // are still going learn about the throttle from this failure.
                await IngestThrottle.shared.noteThrottled(isRateLimit: error.isRateLimited)
                guard !IngestBackoff.isFinalAttempt(attempt, maxAttempts: maxAttempts) else { throw error }
                try Task.checkCancellation()

                // Rate limits escalate on their own, much slower curve; other transients use the
                // caller's policy. The shared cool-down armed above is additive on top of this.
                let effective = error.isRateLimited ? IngestBackoff.Policy.rateLimited : policy
                let delay = IngestBackoff.delay(afterAttempt: attempt, policy: effective)
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                attempt += 1
            }
        }
    }
}

extension IngestError {
    var isRateLimited: Bool {
        if case .rateLimited = self { return true }
        return false
    }
}
