//
// Copyright 2026 Ermis Inc.
//

import Foundation
@testable import ErmisChat
import XCTest

final class PrivacySafeLogMetadataTests: XCTestCase {
    func testUnknownErrorOmitsCallerControlledDomainAndDescription() {
        let secrets = [
            "bearer-secret",
            "api-key-secret",
            "presigned-url-secret",
            "push-token-secret",
            "device-id-secret",
            "user-id-secret",
            "channel-id-secret",
            "message-id-secret",
            "attachment-id-secret",
            "request-body-secret",
        ]
        let joinedSecrets = secrets.joined(separator: "|")
        let error = NSError(
            domain: joinedSecrets,
            code: -42,
            userInfo: [NSLocalizedDescriptionKey: joinedSecrets]
        )

        let output = PrivacySafeLogMetadata.errorFields(error)

        XCTAssertEqual(output, "error_type=NSError error_domain=other error_code=-42")
        secrets.forEach { XCTAssertFalse(output.contains($0)) }
    }

    func testSystemErrorUsesBoundedDomainAndNumericCode() {
        let error = URLError(.notConnectedToInternet)

        XCTAssertEqual(
            PrivacySafeLogMetadata.errorFields(error),
            "error_type=NSError error_domain=url_session error_code=-1009"
        )
    }
}
