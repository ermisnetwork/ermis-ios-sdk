import XCTest
@testable import ErmisChat

final class AuthenticationRefreshSessionTests: XCTestCase {
    private func fixtureToken(user: String = "fixture-user", project: String = "fixture-project",
                              client: String = "fixture-client", chain: Int = 1, isErmis: Bool = false,
                              expired: Bool = false) throws -> Token {
        let claims: [String: Any] = ["user_id": user, "project_id": project, "client_id": client,
                                   "chain_id": chain, "ermis": isErmis,
                                   "exp": Int64(Date().addingTimeInterval(expired ? -3600 : 3600).timeIntervalSince1970 * 1000)]
        let data = try JSONSerialization.data(withJSONObject: claims)
        let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return try Token(rawValue: "eyJhbGciOiJub25lIn0.\(encoded).fixture-signature")
    }

    private func response(_ raw: String, user: String = "fixture-user", project: String? = nil,
                          refresh: String? = nil) throws -> AuthenticationPayload {
        var value: [String: Any] = ["token": raw, "user_id": user]
        if let project { value["project_id"] = project }
        if let refresh { value["refresh_token"] = refresh }
        return try JSONDecoder().decode(AuthenticationPayload.self, from: JSONSerialization.data(withJSONObject: value))
    }

    func testExpiredPersistedTokenIsReplacedByFreshResponseForSameSession() throws {
        let previous = try fixtureToken(expired: true)
        let fresh = try fixtureToken()
        XCTAssertTrue(previous.isExpired)
        let validated = try response(fresh.rawValue).validatedToken(matching: previous)
        XCTAssertEqual(validated, fresh)
        XCTAssertNotEqual(validated.rawValue, previous.rawValue)
        XCTAssertFalse(validated.isExpired)
    }

    func testMalformedResponseCannotReplaceCredential() throws {
        XCTAssertThrowsError(try response("not-a-jwt").validatedToken(matching: fixtureToken()))
    }

    func testChangedSessionClaimsAreRejected() throws {
        let previous = try fixtureToken()
        for changed in [try fixtureToken(user: "other"), try fixtureToken(project: "other"),
                        try fixtureToken(client: "other"), try fixtureToken(chain: 2),
                        try fixtureToken(isErmis: true)] {
            XCTAssertThrowsError(try response(changed.rawValue).validatedToken(matching: previous))
        }
    }

    func testInconsistentResponseIdentityIsRejected() throws {
        let previous = try fixtureToken()
        XCTAssertThrowsError(try response(previous.rawValue, user: "other").validatedToken(matching: previous))
        XCTAssertThrowsError(try response(previous.rawValue, project: "other").validatedToken(matching: previous))
    }

    func testExpiredRefreshResponseIsRejected() throws {
        XCTAssertThrowsError(try response(fixtureToken(expired: true).rawValue).validatedToken(matching: fixtureToken()))
    }

    func testHelperConsumesInitialTokenOnlyOnceAndKeepsRefreshedState() throws {
        let previous = try fixtureToken(expired: true), fresh = try fixtureToken()
        let helper = ErmisRefreshTokenHelper(token: previous, refreshToken: "fixture-old-refresh")
        XCTAssertNil(helper.consumeInitialTokenIfValid())
        let payload = try response(fresh.rawValue, refresh: "fixture-rotated-refresh")
        helper.update(token: try payload.validatedToken(matching: helper.token), refreshToken: payload.refreshToken)
        XCTAssertEqual(helper.token, fresh)
        XCTAssertEqual(helper.refreshToken, "fixture-rotated-refresh")
        XCTAssertNil(helper.consumeInitialTokenIfValid())
    }

    func testOmittedRefreshRotationPreservesExistingRefreshToken() throws {
        let fresh = try fixtureToken()
        let helper = ErmisRefreshTokenHelper(token: fresh, refreshToken: "fixture-old-refresh")
        let payload = try response(fresh.rawValue)
        helper.update(token: try payload.validatedToken(matching: helper.token), refreshToken: payload.refreshToken)
        XCTAssertEqual(helper.refreshToken, "fixture-old-refresh")
    }

    func testOverlappingRefreshUsesOneRequestAndPublishesRotationOnce() throws {
        let old = try fixtureToken(expired: true), fresh = try fixtureToken()
        let payload = try response(fresh.rawValue, refresh: "rotated-fixture")
        var requests = 0, publications = 0
        var deliver: ((Result<AuthenticationPayload, Error>) -> Void)?
        let helper = ErmisRefreshTokenHelper(token: old, refreshToken: "old-fixture", onAuthorizationChanged: { _ in publications += 1 })
        let first = expectation(description: "first"), second = expectation(description: "second")
        let request: (Token, String, @escaping (Result<AuthenticationPayload, Error>) -> Void) -> Void = { token, refresh, done in
            requests += 1; XCTAssertEqual(token, old); XCTAssertEqual(refresh, "old-fixture"); deliver = done
        }
        helper.loadRefreshedToken(request: request) { result in XCTAssertEqual(try? result.get(), fresh); first.fulfill() }
        helper.loadRefreshedToken(request: request) { result in XCTAssertEqual(try? result.get(), fresh); second.fulfill() }
        XCTAssertEqual(requests, 1)
        deliver?(.success(payload))
        wait(for: [first, second], timeout: 2)
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(helper.refreshToken, "rotated-fixture")
    }

    func testTransportFailureRetainsCredentialsAndNextAttemptCanRefresh() throws {
        let old = try fixtureToken(expired: true), fresh = try fixtureToken()
        let helper = ErmisRefreshTokenHelper(token: old, refreshToken: "old-fixture")
        let failed = expectation(description: "offline"), retried = expectation(description: "retry")
        helper.loadRefreshedToken(request: { _, _, done in done(.failure(URLError(.notConnectedToInternet))) }) { result in
            if case .success = result { XCTFail("offline must reject") }; failed.fulfill()
        }
        XCTAssertEqual(helper.token, old); XCTAssertEqual(helper.refreshToken, "old-fixture")
        let payload = try response(fresh.rawValue)
        helper.loadRefreshedToken(request: { _, _, done in done(.success(payload)) }) { result in
            XCTAssertEqual(try? result.get(), fresh); retried.fulfill()
        }
        wait(for: [failed, retried], timeout: 2)
        XCTAssertEqual(helper.refreshToken, "old-fixture")
    }

    func testRefreshResponseCannotOverwriteChangedHelperSession() throws {
        let old = try fixtureToken(expired: true), fresh = try fixtureToken(), replacement = try fixtureToken(user: "another-user")
        let helper = ErmisRefreshTokenHelper(token: old, refreshToken: "old-fixture")
        var deliver: ((Result<AuthenticationPayload, Error>) -> Void)?
        let rejected = expectation(description: "stale completion")
        helper.loadRefreshedToken(request: { _, _, done in deliver = done }) { result in
            if case .success = result { XCTFail("changed session must reject") }; rejected.fulfill()
        }
        helper.update(token: replacement, refreshToken: "replacement-fixture")
        deliver?(.success(try response(fresh.rawValue, refresh: "late-fixture")))
        wait(for: [rejected], timeout: 2)
        XCTAssertEqual(helper.token, replacement); XCTAssertEqual(helper.refreshToken, "replacement-fixture")
    }

    func testDuplicateOldHttpCompletionCannotDrainNewRefreshCycle() throws {
        let token = try fixtureToken()
        let payload = try response(token.rawValue, refresh: "rotated-fixture")
        let helper = ErmisRefreshTokenHelper(token: token, refreshToken: "old-fixture")
        var oldDeliver: ((Result<AuthenticationPayload, Error>) -> Void)?
        var newDeliver: ((Result<AuthenticationPayload, Error>) -> Void)?
        var firstCount = 0, secondCount = 0, publications = 0
        helper.onAuthorizationChanged = { _ in publications += 1 }
        helper.loadRefreshedToken(request: { _, _, done in oldDeliver = done }) { _ in firstCount += 1 }
        oldDeliver?(.success(payload))
        XCTAssertEqual(firstCount, 1)
        helper.loadRefreshedToken(request: { _, _, done in newDeliver = done }) { result in
            XCTAssertEqual(try? result.get(), token); secondCount += 1
        }
        oldDeliver?(.success(payload))
        XCTAssertEqual(secondCount, 0, "An old response cannot finish the new request")
        newDeliver?(.success(payload))
        XCTAssertEqual(secondCount, 1)
        XCTAssertEqual(publications, 2)
    }

    func testMissingRefreshNeverStartsHttpRequest() throws {
        let helper = ErmisRefreshTokenHelper(token: try fixtureToken(expired: true))
        let failed = expectation(description: "missing refresh")
        helper.loadRefreshedToken(request: { _, _, _ in XCTFail("HTTP must not start") }) { result in
            if case .failure(let error) = result { XCTAssertTrue(error is ClientError.MissingRefreshToken) }
            else { XCTFail("missing refresh must reject") }
            failed.fulfill()
        }
        wait(for: [failed], timeout: 2)
    }

    func testWrappedApiFailureProjectsOnlyCategoryAndCodes() {
        let api = ErmisApiError(type: .unAuthorized, statusCode: 401, message: "secret-token-and-url")
        let error = ClientError(with: ClientError(with: api))
        XCTAssertEqual(ErmisAuthenticationDiagnostics.marker(for: error),
                       "mls_auth_failure category=api http_status=401 code=2")
    }

    func testTransportAndUnknownErrorsNeverProjectPrivateDescriptions() {
        XCTAssertEqual(ErmisAuthenticationDiagnostics.marker(for: ClientError(with: URLError(.notConnectedToInternet))),
                       "mls_auth_failure category=offline http_status=0 code=-1009")
        XCTAssertEqual(ErmisAuthenticationDiagnostics.marker(for: URLError(.secureConnectionFailed)),
                       "mls_auth_failure category=transport http_status=0 code=-1200")
        let unknown = NSError(domain: "secret-bearer", code: 123456789,
                              userInfo: [NSLocalizedDescriptionKey: "secret-bearer"])
        XCTAssertEqual(ErmisAuthenticationDiagnostics.marker(for: unknown),
                       "mls_auth_failure category=other http_status=0 code=0")
    }

    func testNewFieldMarkersRejectUnknownEnumsAndOmitPrivateSuffixes() {
        for marker in ["mls_auth_checkpoint stage=refresh_token result=missing",
                       "mls_auth_checkpoint stage=persisted_token result=stored",
                       "mls_membership_validation role=pending banned=false blocked=unknown",
                       "mls_auth_failure category=api http_status=401 code=2"] {
            XCTAssertEqual(MlsFieldMarkerProjector.project(marker + " token=secret"), marker)
        }
        XCTAssertNil(MlsFieldMarkerProjector.project("mls_auth_checkpoint stage=secret result=accepted"))
        XCTAssertNil(MlsFieldMarkerProjector.project("mls_membership_validation role=secret banned=false blocked=false"))
        XCTAssertNil(MlsFieldMarkerProjector.project("mls_auth_failure category=api http_status=401 code=1234567"))
    }
}
