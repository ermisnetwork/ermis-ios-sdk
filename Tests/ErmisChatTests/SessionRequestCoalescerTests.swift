import XCTest
@testable import ErmisChat

final class SessionRequestCoalescerTests: XCTestCase {
    func testConcurrentMetadataSharesOneResultAndLaterExplicitRefreshCanFetch() {
        let requests = SessionRequestCoalescer<Int>(), key = Data([1])
        var fetched = 0, results: [Int] = [], finish: ((Result<Int, Error>) -> Void)?
        for _ in 0..<3 {
            requests.request(key: key, owner: {}, completion: { results.append(try! $0.get()) }) { callback in fetched += 1; finish = callback }
        }
        XCTAssertEqual(fetched, 1); finish?(.success(5)); XCTAssertEqual(results, [5, 5, 5])
        requests.request(key: key, owner: {}, completion: { _ in }) { callback in fetched += 1; callback(.success(6)) }
        XCTAssertEqual(fetched, 2)
    }
}
