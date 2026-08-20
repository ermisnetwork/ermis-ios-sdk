//
// Copyright 2026 Ermis Inc.
//

import Foundation
@testable import ErmisChat
import XCTest

final class URLRequestPrivacySafeDiagnosticsTests: XCTestCase {
    func testDiagnosticSummaryOmitsEveryRequestControlledField() throws {
        let sensitiveValues = [
            "api-key-secret",
            "bearer-secret",
            "cookie-secret",
            "presigned-signature-secret",
            "push-token-secret",
            "device-id-secret",
            "user-id-secret",
            "channel-id-secret",
            "message-id-secret",
            "attachment-id-secret",
            "request-body-secret"
        ]
        let url = try XCTUnwrap(URL(string:
            "https://storage.example/user-id-secret/channel-id-secret?api_key=api-key-secret&signature=presigned-signature-secret"
        ))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer bearer-secret", forHTTPHeaderField: "Authorization")
        request.setValue("session=cookie-secret", forHTTPHeaderField: "Cookie")
        request.setValue("push-token-secret", forHTTPHeaderField: "X-Push-Token")
        request.setValue("device-id-secret", forHTTPHeaderField: "X-Device-ID")
        request.httpBody = Data("request-body-secret message-id-secret attachment-id-secret".utf8)

        let output = request.privacySafeDiagnosticSummary(state: .started)

        XCTAssertEqual(output, "[API_REQUEST] state=started method=POST")
        sensitiveValues.forEach { XCTAssertFalse(output.contains($0)) }
        XCTAssertFalse(output.localizedCaseInsensitiveContains("url="))
        XCTAssertFalse(output.localizedCaseInsensitiveContains("header"))
        XCTAssertFalse(output.localizedCaseInsensitiveContains("body"))
    }

    func testDiagnosticSummaryBoundsUnknownMethod() throws {
        let url = try XCTUnwrap(URL(string: "https://example.test"))
        var customRequest = URLRequest(url: url)
        customRequest.httpMethod = "SECRET-CUSTOM-METHOD"

        XCTAssertEqual(
            customRequest.privacySafeDiagnosticSummary(state: .failed),
            "[API_REQUEST] state=failed method=OTHER"
        )
    }
}
