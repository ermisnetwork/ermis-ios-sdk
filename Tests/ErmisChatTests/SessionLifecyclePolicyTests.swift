import XCTest
@testable import ErmisChat

final class SessionLifecyclePolicyTests: XCTestCase {
    func testStorageDefaultsToAutomaticResolution() {
        let config = ErmisClientConfig(
            apiKeyString: "test-api-key",
            endpointEnviroment: .init(baseURL: URL(string: "https://example.com")!),
            isErmis: false
        )
        XCTAssertEqual(config.localStorageScope, .automatic)
    }

    func testLogoutDefaultsCanExpressPreserveAndExplicitPurge() {
        XCTAssertNotEqual(LogoutLocalDataPolicy.preserve, .purgeCurrentUser)
    }

    func testReadinessHasExpectedTerminalStates() {
        XCTAssertEqual(E2eeChannelReadiness.ready.rawValue, "ready")
        XCTAssertEqual(E2eeChannelReadiness.needsRetry.rawValue, "needsRetry")
        XCTAssertEqual(E2eeChannelReadiness.failed.rawValue, "failed")
    }
}
