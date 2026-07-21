import Foundation
import ContinuityCore
import os

/// Process-wide cool-down shared by every outbound request to a scraped source.
///
/// **Why this exists.** Importing a playlist enqueues N tracks at once; each runs its own
/// `Retry` loop with no knowledge of the others. When YouTube starts throttling (429, or a
/// bot-gated page that parses to nothing), all N loops independently retried *into the same
/// throttle window* — which extends it — and then all N gave up within a few seconds of each
/// other. That's why a fresh import failed every song rather than a few: the retries were the
/// amplifier, not the cure.
///
/// The fix is to make the whole app back off as **one** client. Any request that sees a throttle
/// signal arms a cool-down here; every other in-flight request waits it out before its next
/// attempt. Success clears the streak. A minimum spacing between requests also paces the initial
/// burst, so an import ramps up instead of hitting the source with a wall of connections.
actor IngestThrottle {
    /// The one instance every resolver/downloader consults.
    static let shared = IngestThrottle()

    /// Minimum spacing between outbound requests to a scraped source. Slow enough that a 50-track
    /// Spotify import doesn't read as a scraper, fast enough to stay invisible next to the
    /// per-track resolve+download time.
    private let minimumSpacing: TimeInterval = 0.25

    /// Consecutive throttle signals since the last success; drives the cool-down curve.
    private var failureStreak = 0
    /// No request may start before this instant.
    private var openAt = Date.distantPast
    /// When the last request was released, for `minimumSpacing`.
    private var lastReleasedAt = Date.distantPast

    /// Waits until the source is ready for another request: any active cool-down elapses, then
    /// the minimum spacing since the previous caller. Call immediately before each attempt.
    func gate() async {
        // Loop rather than sleep once: a concurrent failure can push `openAt` further out while
        // we're sleeping, and that new cool-down must be honoured too.
        while true {
            let now = Date()
            let readyAt = max(openAt, lastReleasedAt.addingTimeInterval(minimumSpacing))
            guard readyAt > now else { break }
            let wait = readyAt.timeIntervalSince(now)
            // `openAt` is only ever pushed out by other tasks, so re-checking after the sleep
            // converges; the spacing term can only move by `minimumSpacing`.
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            if Task.isCancelled { break }
        }
        lastReleasedAt = Date()
    }

    /// The source answered normally — clear the streak so the next blip starts from `base` again.
    ///
    /// Deliberately does **not** clear `openAt`: during a rate limit some requests still succeed
    /// (a cached page, a different endpoint), and letting one of those cancel an armed cool-down
    /// would release the whole import back into the throttle and oscillate. An armed cool-down
    /// always expires on its own schedule.
    func noteSuccess() {
        failureStreak = 0
    }

    /// The source throttled or refused us. Arms (or extends) the shared cool-down.
    ///
    /// `isRateLimit` distinguishes an explicit 429 — which needs a much longer window than a
    /// dropped connection — from a generic transient network failure.
    func noteThrottled(isRateLimit: Bool) {
        failureStreak += 1
        let policy: IngestBackoff.Policy = isRateLimit ? .rateLimited : .sourceCooldown
        let delay = IngestBackoff.delay(afterAttempt: failureStreak, policy: policy)
        let candidate = Date().addingTimeInterval(delay)
        // Never pull the gate in: overlapping failures should compound, not reset each other.
        if candidate > openAt {
            openAt = candidate
            Logger.ingest.notice(
                "source cool-down \(delay, format: .fixed(precision: 1))s (streak \(self.failureStreak), rateLimit \(isRateLimit))"
            )
        }
    }

    /// How long callers must currently wait — used to decide whether a whole-track retry is worth
    /// scheduling now or should be pushed past the cool-down.
    func remainingCooldown() -> TimeInterval {
        max(0, openAt.timeIntervalSince(Date()))
    }

    /// Test seam: forget all throttle state.
    func reset() {
        failureStreak = 0
        openAt = .distantPast
        lastReleasedAt = .distantPast
    }
}
