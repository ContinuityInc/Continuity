import XCTest
@testable import Ingest

final class ConcurrencyLimiterTests: XCTestCase {

    /// A later waiter with a higher priority runs before an earlier one after `release`.
    func testBumpJumpsTheQueue() async {
        let limiter = ConcurrencyLimiter(limit: 1)
        let firstID = UUID()
        let secondID = UUID()
        var order: [UUID] = []

        await limiter.acquire(id: UUID(), priority: 0)

        let first = Task {
            await limiter.acquire(id: firstID, priority: 0)
            order.append(firstID)
            await limiter.release()
        }
        await waitUntil(limiter, pending: 1)

        let second = Task {
            await limiter.acquire(id: secondID, priority: 0)
            order.append(secondID)
            await limiter.release()
        }
        await waitUntil(limiter, pending: 2)

        await limiter.bump(ids: [secondID], to: 100)
        await limiter.release()

        _ = await first.result
        _ = await second.result
        XCTAssertEqual(order, [secondID, firstID])
    }

    func testEqualPriorityStaysFIFO() async {
        let limiter = ConcurrencyLimiter(limit: 1)
        let firstID = UUID()
        let secondID = UUID()
        var order: [UUID] = []

        await limiter.acquire()

        let first = Task {
            await limiter.acquire(id: firstID, priority: 0)
            order.append(firstID)
            await limiter.release()
        }
        await waitUntil(limiter, pending: 1)

        let second = Task {
            await limiter.acquire(id: secondID, priority: 0)
            order.append(secondID)
            await limiter.release()
        }
        await waitUntil(limiter, pending: 2)

        await limiter.release()
        _ = await first.result
        _ = await second.result
        XCTAssertEqual(order, [firstID, secondID])
    }

    private func waitUntil(_ limiter: ConcurrencyLimiter, pending: Int) async {
        for _ in 0..<10_000 {
            if await limiter.pendingCount >= pending { return }
            await Task.yield()
        }
        XCTFail("timed out waiting for \(pending) limiter waiters")
    }
}
