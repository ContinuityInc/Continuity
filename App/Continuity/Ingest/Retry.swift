import Foundation

/// Retries a transient-failing async operation with exponential backoff + jitter.
///
/// Only `IngestError`s that report themselves `isRetryable` (network blips, rate limits) are
/// retried; a definitively-empty source or any other error propagates immediately. The scraped
/// endpoints (Spotify embed, YouTube playlist page) fail transiently often enough that a single
/// blip shouldn't surface to the user as "playlist unavailable".
enum Retry {
    static func run<T>(
        maxAttempts: Int = 3,
        baseDelay: TimeInterval = 0.7,
        _ operation: () async throws -> T
    ) async throws -> T {
        var attempt = 1
        while true {
            do {
                return try await operation()
            } catch let error as IngestError where error.isRetryable && attempt < maxAttempts {
                // Exponential backoff (0.7s, 1.4s, …) with up to 30% jitter so retries don't
                // synchronize. Rate limits get a longer floor — they rarely clear in <1s.
                let floor = (error.isRateLimited ? 1.5 : baseDelay)
                let delay = floor * pow(2, Double(attempt - 1))
                let jitter = Double.random(in: 0...(delay * 0.3))
                try? await Task.sleep(nanoseconds: UInt64((delay + jitter) * 1_000_000_000))
                attempt += 1
            }
        }
    }
}

private extension IngestError {
    var isRateLimited: Bool {
        if case .rateLimited = self { return true }
        return false
    }
}
