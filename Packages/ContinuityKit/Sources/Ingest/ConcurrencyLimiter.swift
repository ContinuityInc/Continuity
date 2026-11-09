import Foundation

/// A minimal async concurrency gate: at most `limit` holders run between `acquire` and
/// `release()`; the rest suspend until a slot frees.
///
/// Waiters are FIFO among equal `priority` values. A later `bump` reorders still-waiting
/// acquirers so a user-prioritized track jumps the ingest queue without cancelling anyone
/// already downloading.
///
/// Used by `PreparationQueue` so importing a large playlist doesn't fire dozens of simultaneous
/// resolves/downloads (network throttling) or stem separations (each loads a ~158 MB model and
/// pegs the CPU — running many at once would thrash memory).
actor ConcurrencyLimiter {
    private struct Waiter {
        let id: UUID
        var priority: Int
        let sequence: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let limit: Int
    private var active = 0
    private var waiters: [Waiter] = []
    private var nextSequence = 0

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    /// Suspends until a slot is available, then claims it. Pair with exactly one `release()`.
    func acquire() async {
        await acquire(id: UUID(), priority: 0)
    }

    /// Identified acquire so a later `bump` can move this waiter ahead of equal/lower priority.
    func acquire(id: UUID, priority: Int) async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(Waiter(
                id: id,
                priority: priority,
                sequence: nextSequence,
                continuation: continuation
            ))
            nextSequence += 1
            sortWaiters()
        }
        // Resumed by `release()`, which hands over its slot without touching `active`.
    }

    /// Raises still-waiting acquirers in `ids` to at least `priority`. No-op for holders
    /// already running — those finish; the next slot goes to the new head of the queue.
    func bump(ids: Set<UUID>, to priority: Int) {
        guard !ids.isEmpty else { return }
        var changed = false
        for i in waiters.indices where ids.contains(waiters[i].id) {
            if waiters[i].priority < priority {
                waiters[i].priority = priority
                changed = true
            }
        }
        if changed { sortWaiters() }
    }

    /// Frees a slot, waking the highest-priority waiter (FIFO among ties).
    func release() {
        if waiters.isEmpty {
            active = max(0, active - 1)
        } else {
            let next = waiters.removeFirst()
            next.continuation.resume()
        }
    }

    /// Waiter count — tests use this instead of `Task.yield` to know an `acquire` has queued.
    var pendingCount: Int { waiters.count }

    /// Higher priority first; among equals, the earlier `acquire` stays ahead.
    private func sortWaiters() {
        waiters.sort { a, b in
            if a.priority != b.priority { return a.priority > b.priority }
            return a.sequence < b.sequence
        }
    }
}
