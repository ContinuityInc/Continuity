import Foundation

/// A minimal async concurrency gate: at most `limit` holders run between `acquire()` and
/// `release()`; the rest suspend (FIFO) until a slot frees.
///
/// Used by `PreparationQueue` so importing a large playlist doesn't fire dozens of simultaneous
/// resolves/downloads (network throttling) or stem separations (each loads a ~158 MB model and
/// pegs the CPU — running many at once would thrash memory).
actor ConcurrencyLimiter {
    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    /// Suspends until a slot is available, then claims it. Pair with exactly one `release()`.
    func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
        // Resumed by `release()`, which hands over its slot without touching `active`.
    }

    /// Frees a slot, waking the longest-waiting acquirer (if any).
    func release() {
        if waiters.isEmpty {
            active = max(0, active - 1)
        } else {
            // Transfer the slot directly to the next waiter; `active` stays the same.
            let next = waiters.removeFirst()
            next.resume()
        }
    }
}
