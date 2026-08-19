//
// Copyright 2026 Ermis Inc.
//

import XCTest
@testable import ErmisChat

final class AsyncOperationRetryTests: XCTestCase {
    func testSynchronousRetryCallbackIsBoundedAndDoesNotReenterExecutionBlock() {
        let completed = expectation(description: "operation completed")
        let lock = NSLock()
        var isInsideExecutionBlock = false
        var invocationCount = 0

        let operation = AsyncOperation(maxRetries: 3) { operation, done in
            lock.lock()
            XCTAssertFalse(isInsideExecutionBlock, "Retry re-entered the current callback stack")
            isInsideExecutionBlock = true
            invocationCount += 1
            lock.unlock()

            if operation.canRetry {
                done(.retry)
            } else {
                done(.continue)
                completed.fulfill()
            }

            lock.lock()
            isInsideExecutionBlock = false
            lock.unlock()
        }

        operation.start()

        wait(for: [completed], timeout: 2)
        XCTAssertEqual(invocationCount, 4)
    }
}
