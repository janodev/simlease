import Foundation
@testable import SimLeaseApp
import SimLeaseCore
import Testing

@MainActor
@Suite("Lease board refresh")
struct LeaseBoardTests {
    @Test("Status loading runs away from the main thread")
    func statusLoadingRunsAwayFromMainThread() async throws {
        let row = makeRow(id: "TEST-UDID")
        let probe = StatusProbe(rows: [row])
        let board = LeaseBoard(
            statusLoader: { [probe] in probe.load() },
            startAutomatically: false
        )

        board.refresh()

        try await waitUntil { board.rows == [row] }
        #expect(probe.didRun)
        #expect(probe.ranAwayFromMainThread)
        #expect(board.statusError == nil)
    }

    @Test("Overlapping refresh requests never load concurrently")
    func overlappingRefreshRequestsNeverLoadConcurrently() async throws {
        let row = makeRow(id: "COALESCED-UDID")
        let probe = StatusProbe(rows: [row], delay: 0.05)
        let board = LeaseBoard(
            statusLoader: { [probe] in probe.load() },
            startAutomatically: false
        )

        for _ in 0..<10 {
            board.refresh()
        }

        try await waitUntil { probe.callCount >= 2 && board.rows == [row] }
        #expect(probe.callCount == 2)
        #expect(probe.maximumConcurrentCalls == 1)
    }

    private func makeRow(id: String) -> BoardRow {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let lease = Lease(
            label: "test",
            agent: "agent",
            workdir: "/tmp/test",
            originalName: "iPhone 17 Pro",
            renamed: false,
            created: false,
            claimedAt: now,
            expiresAt: now.addingTimeInterval(60)
        )
        return BoardRow(id: id, lease: lease, booted: true, expired: false)
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for the lease board to refresh")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class StatusProbe: @unchecked Sendable {
    private let delay: TimeInterval
    private let lock = NSLock()
    private let rows: [BoardRow]
    private var activeCalls = 0
    private var calls = 0
    private var maximumCalls = 0
    private var ranOffMainThread = false

    init(rows: [BoardRow], delay: TimeInterval = 0) {
        self.delay = delay
        self.rows = rows
    }

    var callCount: Int {
        lock.withLock { calls }
    }

    var didRun: Bool {
        callCount > 0
    }

    var maximumConcurrentCalls: Int {
        lock.withLock { maximumCalls }
    }

    var ranAwayFromMainThread: Bool {
        lock.withLock { ranOffMainThread }
    }

    func load() -> [BoardRow] {
        lock.withLock {
            activeCalls += 1
            calls += 1
            maximumCalls = max(maximumCalls, activeCalls)
            ranOffMainThread = ranOffMainThread || !Thread.isMainThread
        }
        if delay > 0 {
            Thread.sleep(forTimeInterval: delay)
        }
        lock.withLock {
            activeCalls -= 1
        }
        return rows
    }
}
