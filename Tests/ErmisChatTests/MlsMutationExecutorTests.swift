//
// Copyright 2025 Ermis Inc.
//

import XCTest
@testable import ErmisChat

final class MlsMutationExecutorTests: XCTestCase {
    func testSameScopePreservesFIFOAcrossPriorities() {
        let executor = MlsMutationExecutor(label: "test.mls.fifo")
        let firstStarted = expectation(description: "first started")
        let releaseFirst = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var order: [Int] = []

        let first = executor.enqueue(scopeIds: ["group-a"], priority: .low) {
            firstStarted.fulfill()
            releaseFirst.wait()
            lock.withLock { order.append(1) }
        }
        wait(for: [firstStarted], timeout: 1)
        let second = executor.enqueue(scopeIds: ["group-a"], priority: .low) {
            lock.withLock { order.append(2) }
        }
        let third = executor.enqueue(scopeIds: ["group-a"], priority: .veryHigh) {
            lock.withLock { order.append(3) }
        }

        releaseFirst.signal()
        [first, second, third].forEach { $0.waitUntilFinished() }
        XCTAssertEqual(order, [1, 2, 3])
    }

    func testSyncIsReentrantFromExecutorWorker() {
        let executor = MlsMutationExecutor(label: "test.mls.reentrant")
        let completed = expectation(description: "nested sync completed")
        var value: Int?

        let operation = executor.enqueue(scopeIds: ["group-a"]) {
            value = try? executor.sync(scopeIds: ["group-a"]) {
                XCTAssertTrue(executor.isExecuting)
                return 42
            }
            completed.fulfill()
        }

        wait(for: [completed], timeout: 1)
        operation.waitUntilFinished()
        XCTAssertEqual(value, 42)
    }

    func testDifferentScopesStillSerializeSharedProviderMutations() {
        let executor = MlsMutationExecutor(label: "test.mls.global")
        let lock = NSLock()
        var activeCount = 0
        var peakActiveCount = 0

        let operations = (0..<20).map { index in
            executor.enqueue(scopeIds: ["group-\(index)"]) {
                lock.withLock {
                    activeCount += 1
                    peakActiveCount = max(peakActiveCount, activeCount)
                }
                Thread.sleep(forTimeInterval: 0.001)
                lock.withLock { activeCount -= 1 }
            }
        }

        operations.forEach { $0.waitUntilFinished() }
        XCTAssertEqual(peakActiveCount, 1)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
