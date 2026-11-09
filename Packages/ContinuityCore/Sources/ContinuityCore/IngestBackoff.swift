import Foundation

/// Exponential-backoff schedules for the ingest pipeline (resolve → download → analyse).
///
/// Pure math so the policy is unit-testable without a network: callers pass the attempt number
/// and a random fraction, and get back the delay to sleep before the next attempt.
///
/// **Equal jitter, not full jitter.** Full jitter (`random(0, window)`) can return ~0s, which is
/// exactly wrong against a rate limiter — the retry lands inside the same throttle window and
/// extends it. Equal jitter keeps half the window as a hard floor and randomises the other half,
/// so retries still de-synchronise across concurrently-importing tracks without ever hot-looping.
public enum IngestBackoff {

    /// One backoff curve: `base · multiplier^(attempt-1)`, clamped to `cap`, then jittered.
    public struct Policy: Sendable, Equatable {
        /// Delay window after the first failure.
        public let base: TimeInterval
        /// Growth factor per additional failure.
        public let multiplier: Double
        /// Upper bound on the window, before jitter.
        public let cap: TimeInterval
        /// Share of the window that is randomised (0 = fixed delay, 1 = full jitter).
        public let jitterFraction: Double

        public init(base: TimeInterval, multiplier: Double = 2, cap: TimeInterval, jitterFraction: Double = 0.5) {
            self.base = max(0, base)
            self.multiplier = max(1, multiplier)
            self.cap = max(0, cap)
            self.jitterFraction = min(max(0, jitterFraction), 1)
        }

        /// Transient blips on a single scrape/extract call (YouTubeKit churn, a dropped connection).
        /// Short — the user is watching an import progress.
        public static let request = Policy(base: 0.8, cap: 12)

        /// HTTP 429. A rate limit does not clear in a second, and retrying inside its window is
        /// what turns a throttle into a longer throttle — so this starts far out and climbs hard.
        public static let rateLimited = Policy(base: 6, cap: 120)

        /// Whole-track re-attempt after its per-call retries were exhausted. Minutes-scale: the
        /// point is to outlast a bot-detection window, not to re-hammer it.
        public static let track = Policy(base: 20, cap: 900)

        /// Process-wide cool-down armed when the source starts throttling us, shared by every
        /// in-flight track so an import backs off as one client rather than N independent ones.
        public static let sourceCooldown = Policy(base: 4, cap: 300)
    }

    /// Delay to wait *after* `attempt` has failed, before making attempt `attempt + 1`.
    /// `attempt` is 1-based; anything below 1 is treated as the first attempt.
    ///
    /// `randomFraction` must be in `0...1` — injected so tests are deterministic.
    public static func delay(
        afterAttempt attempt: Int,
        policy: Policy,
        randomFraction: Double = Double.random(in: 0...1)
    ) -> TimeInterval {
        let window = window(afterAttempt: attempt, policy: policy)
        let fixed = window * (1 - policy.jitterFraction)
        let jittered = window * policy.jitterFraction * min(max(0, randomFraction), 1)
        return fixed + jittered
    }

    /// The un-jittered delay window after `attempt` failures — `base · multiplier^(attempt-1)`,
    /// clamped to `cap`. Exposed for callers that want to report "retrying in ~Ns".
    public static func window(afterAttempt attempt: Int, policy: Policy) -> TimeInterval {
        let exponent = Double(max(1, attempt) - 1)
        // pow overflows to .infinity for large exponents; min() with a finite cap still works,
        // but guard anyway so a runaway attempt counter can't produce NaN downstream.
        let grown = policy.base * pow(policy.multiplier, exponent)
        guard grown.isFinite else { return policy.cap }
        return min(grown, policy.cap)
    }

    /// Whether `attempt` (1-based) was the last one allowed by a budget of `maxAttempts`.
    public static func isFinalAttempt(_ attempt: Int, maxAttempts: Int) -> Bool {
        attempt >= max(1, maxAttempts)
    }
}
