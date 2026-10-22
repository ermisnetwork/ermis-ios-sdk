import XCTest
@testable import ErmisChat

final class RequestDecoderAuthenticationTests: XCTestCase {
    func testGoogleLoginDiagnosticsKeepStatusAndAllowlistedReasonWithoutSecrets() throws {
        let url = try XCTUnwrap(URL(string: "https://example.invalid/uss/v1/auth/google_login"))
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil))
        let rejected = Data(#"{"error":{"message":"Invalid apikey!"},"token":"sensitive-value"}"#.utf8)
        XCTAssertEqual(ErmisAuthenticationDiagnostics.googleResponseMarker(data: rejected, response: response, error: nil),
            "uhm_auth phase=google_http result=response http_status=401 reason=invalid_api_key")
        let arbitrary = Data(#"{"message":"sensitive-value"}"#.utf8)
        XCTAssertEqual(ErmisAuthenticationDiagnostics.googleResponseMarker(data: arbitrary, response: response, error: nil),
            "uhm_auth phase=google_http result=response http_status=401 reason=unclassified")
        XCTAssertEqual(ErmisAuthenticationDiagnostics.marker(for: ClientError.ExpiredToken()),
            "mls_auth_failure category=api http_status=401 code=0")
    }
    func testUnauthorizedResponsesTriggerRenewalRegardlessOfEnvelope() throws {
        let url = try XCTUnwrap(URL(string: "https://example.invalid/messages"))
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 401,
                                                    httpVersion: nil, headerFields: nil))
        let bodies: [Data?] = [nil, Data(), Data("Unauthorized".utf8),
                              Data(#"{"ermis_code":2,"message":"Unauthorized"}"#.utf8)]
        for body in bodies {
            XCTAssertThrowsError(try DefaultRequestDecoder().decodeRequestResponse(
                data: body, response: response, error: nil) as Data) { error in
                XCTAssertTrue(error is ClientError.ExpiredToken)
            }
        }
    }

    func testForbiddenIsNotTreatedAsTokenExpiry() throws {
        let url = try XCTUnwrap(URL(string: "https://example.invalid/messages"))
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 403,
                                                    httpVersion: nil, headerFields: nil))
        XCTAssertThrowsError(try DefaultRequestDecoder().decodeRequestResponse(
            data: Data(), response: response, error: nil) as Data) { error in
            XCTAssertFalse(error is ClientError.ExpiredToken)
            XCTAssertEqual((error as? ErmisApiError)?.httpStatusCode, 403)
        }
    }
}
