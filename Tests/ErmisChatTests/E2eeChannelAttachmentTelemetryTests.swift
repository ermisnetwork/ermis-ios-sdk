//
// Copyright 2026 Ermis Inc.
//

import Foundation
@testable import ErmisChat
import XCTest

final class E2eeChannelAttachmentTelemetryTests: XCTestCase {
    func testQueryAndJoinSuccessContainOnlyBoundedMetadata() {
        XCTAssertEqual(
            E2eeChannelAttachmentTelemetry.queryStarted(limit: 50, hasCursor: true),
            "[E2EE_CHANNEL_ATTACHMENTS] operation=query state=started limit=50 has_cursor=true"
        )
        XCTAssertEqual(
            E2eeChannelAttachmentTelemetry.querySucceeded(projectionCount: 12, hasMore: false),
            "[E2EE_CHANNEL_ATTACHMENTS] operation=query state=succeeded projection_count=12 has_more=false"
        )
        XCTAssertEqual(
            E2eeChannelAttachmentTelemetry.joinSucceeded(
                projectionCount: 12,
                renderableCount: 9,
                unavailableCount: 3
            ),
            "[E2EE_CHANNEL_ATTACHMENTS] operation=join state=succeeded projection_count=12 renderable_count=9 unavailable_count=3"
        )
    }

    func testQueryFailureUsesFixedCategoryAndDoesNotRenderRawError() {
        let sensitiveValues = [
            "message-id-secret",
            "attachment-id-secret",
            "private-photo.jpg",
            "https://grant.example/private",
            "cek-secret",
            "nonce-secret"
        ]
        let error = NSError(
            domain: sensitiveValues.joined(separator: "|"),
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: sensitiveValues.joined(separator: " ")]
        )

        let output = E2eeChannelAttachmentTelemetry.failed(operation: .query, error: error)

        XCTAssertEqual(
            output,
            "[E2EE_CHANNEL_ATTACHMENTS] operation=query state=failed category=unknown retryable=false"
        )
        sensitiveValues.forEach { XCTAssertFalse(output.contains($0)) }
    }

    func testKnownFailuresUseStableCategories() {
        XCTAssertEqual(
            E2eeChannelAttachmentTelemetry.failed(
                operation: .query,
                error: URLError(.notConnectedToInternet)
            ),
            "[E2EE_CHANNEL_ATTACHMENTS] operation=query state=failed category=networkUnavailable retryable=true"
        )
        XCTAssertEqual(
            E2eeChannelAttachmentTelemetry.failed(
                operation: .query,
                error: E2eeAttachmentAPIContractError.invalidQuery
            ),
            "[E2EE_CHANNEL_ATTACHMENTS] operation=query state=failed category=contractViolation retryable=false"
        )
        XCTAssertEqual(
            E2eeChannelAttachmentTelemetry.failed(
                operation: .join,
                error: NSError(domain: "must-not-be-logged", code: 1)
            ),
            "[E2EE_CHANNEL_ATTACHMENTS] operation=join state=failed category=localStateUnavailable retryable=true"
        )
    }
}
