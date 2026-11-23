//
// Copyright 2026 Ermis Inc.
//

import XCTest
@testable import ErmisChat

final class WatchedChannelPageWriterTests: XCTestCase {
    func testQueuedLiveWriteRunsBeforeSecondChannel() {
        let databaseQueue = DispatchQueue(label: "test.watch.database")
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let done = expectation(description: "page saved")
        var liveCommitted = false
        WatchedChannelPageWriter.save([1, 2], persist: { channel, ack in
            databaseQueue.async {
                if channel == 1 {
                    entered.signal()
                    XCTAssertEqual(release.wait(timeout: .now() + 2), .success)
                } else {
                    XCTAssertTrue(liveCommitted)
                }
                ack(nil)
            }
        }, completion: { error in
            XCTAssertNil(error)
            done.fulfill()
        })
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        databaseQueue.async { liveCommitted = true }
        release.signal()
        wait(for: [done], timeout: 4)
    }

    func testCompletionWaitsForFinalDurableACK() {
        let finalEntered = DispatchSemaphore(value: 0)
        let done = expectation(description: "final ACK")
        let lock = NSLock()
        var finalACK: ((Error?) -> Void)?
        var completions = 0
        WatchedChannelPageWriter.save([1, 2], persist: { channel, ack in
            if channel == 1 {
                ack(nil)
            } else {
                lock.lock()
                finalACK = ack
                lock.unlock()
                finalEntered.signal()
            }
        }, completion: { error in
            XCTAssertNil(error)
            lock.lock()
            completions += 1
            lock.unlock()
            done.fulfill()
        })
        XCTAssertEqual(finalEntered.wait(timeout: .now() + 2), .success)
        lock.lock()
        XCTAssertEqual(completions, 0)
        let ack = finalACK
        lock.unlock()
        XCTAssertNotNil(ack)
        ack?(nil)
        wait(for: [done], timeout: 4)
        XCTAssertEqual(completions, 1)
    }

    func testSaveFailureRetainsAcknowledgedPrefixAndStopsTail() {
        enum SaveError: Error { case failed }
        let done = expectation(description: "save failed")
        var submitted = [Int]()
        var durable = [Int]()
        WatchedChannelPageWriter.save([1, 2, 3], persist: { channel, ack in
            submitted.append(channel)
            if channel == 2 {
                ack(SaveError.failed)
            } else {
                durable.append(channel)
                ack(nil)
            }
        }, completion: { error in
            XCTAssertTrue(error is SaveError)
            XCTAssertEqual(submitted, [1, 2])
            XCTAssertEqual(durable, [1])
            done.fulfill()
        })
        wait(for: [done], timeout: 4)
    }

    func testEmptyPageCompletesWithoutWriting() {
        let done = expectation(description: "empty page")
        WatchedChannelPageWriter.save([Int](), persist: { _, _ in
            XCTFail("Empty page must not submit a database write")
        }, completion: { error in
            XCTAssertNil(error)
            done.fulfill()
        })
        wait(for: [done], timeout: 4)
    }

    func testDuplicateACKDoesNotAdvanceTwiceOrRepeatCompletion() {
        let done = expectation(description: "ordered page")
        var submitted = [Int]()
        let page = Array(0..<128)
        WatchedChannelPageWriter.save(page, persist: { channel, ack in
            submitted.append(channel)
            ack(nil)
            ack(nil)
        }, completion: { error in
            XCTAssertNil(error)
            XCTAssertEqual(submitted, page)
            done.fulfill()
        })
        wait(for: [done], timeout: 4)
    }
}
