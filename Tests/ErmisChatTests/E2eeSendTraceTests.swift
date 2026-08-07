import XCTest

@testable import ErmisChat

final class E2eeSendTraceTests: XCTestCase {
    func testTraceIncludesCorrelatedOperationalMetadata() throws {
        let cid = try ChannelId(cid: "team:project:channel-1")
        let context = E2eeSendTrace.Context(
            messageId: "message-1",
            cid: cid,
            groupCid: "team:project:parent-1",
            startedAtNanoseconds: E2eeSendTrace.nowNanoseconds()
        )

        let line = E2eeSendTrace.makeLine(
            stage: "mls_create_succeeded",
            context: context,
            epoch: 12,
            payloadBytes: 24,
            ciphertextBytes: 96,
            queueWaitMilliseconds: 3,
            operationMilliseconds: 7,
            reusedIntent: false,
            authenticatedAAD: false
        )

        XCTAssertTrue(line.hasPrefix("[E2EE_SEND] "))
        XCTAssertTrue(line.contains("stage=mls_create_succeeded"))
        XCTAssertTrue(line.contains("message_id=message-1"))
        XCTAssertTrue(line.contains("cid=team:project:channel-1"))
        XCTAssertTrue(line.contains("group_cid=team:project:parent-1"))
        XCTAssertTrue(line.contains("epoch=12"))
        XCTAssertTrue(line.contains("payload_bytes=24"))
        XCTAssertTrue(line.contains("ciphertext_bytes=96"))
        XCTAssertTrue(line.contains("queue_wait_ms=3"))
        XCTAssertTrue(line.contains("operation_ms=7"))
        XCTAssertTrue(line.contains("reused_intent=false"))
        XCTAssertTrue(line.contains("authenticated_aad=false"))
        XCTAssertTrue(line.contains("elapsed_ms="))
    }

    func testTraceErrorMetadataNeverIncludesDescriptionsOrPayloads() throws {
        let cid = try ChannelId(cid: "team:project:channel-1")
        let context = E2eeSendTrace.Context(
            messageId: "message-1",
            cid: cid,
            startedAtNanoseconds: E2eeSendTrace.nowNanoseconds()
        )
        let sensitiveMarker = "SECRET_PLAINTEXT_AND_SERVER_MESSAGE"
        let error = NSError(
            domain: "network.ermis.send",
            code: -42,
            userInfo: [NSLocalizedDescriptionKey: sensitiveMarker]
        )

        let line = E2eeSendTrace.makeLine(
            stage: "http_request_failed",
            context: context,
            error: error
        )

        XCTAssertTrue(line.contains("error_domain=network.ermis.send"))
        XCTAssertTrue(line.contains("error_code=-42"))
        XCTAssertFalse(line.contains(sensitiveMarker))
        XCTAssertFalse(line.localizedCaseInsensitiveContains("plaintext"))
        XCTAssertFalse(line.localizedCaseInsensitiveContains("ciphertext="))
        XCTAssertFalse(line.localizedCaseInsensitiveContains("aad="))
        XCTAssertFalse(line.localizedCaseInsensitiveContains("url="))
    }

    func testApiErrorLogsOnlyStatusAndStableCode() throws {
        let cid = try ChannelId(cid: "team:project:channel-1")
        let context = E2eeSendTrace.Context(
            messageId: "message-1",
            cid: cid,
            startedAtNanoseconds: E2eeSendTrace.nowNanoseconds()
        )
        let sensitiveMarker = "SECRET_SERVER_RESPONSE_MESSAGE"
        let error = ErmisApiError(
            type: .inputNotCorrect,
            statusCode: 400,
            message: sensitiveMarker
        )

        let line = E2eeSendTrace.makeLine(
            stage: "http_request_failed",
            context: context,
            error: error
        )

        XCTAssertTrue(line.contains("http_status=400"))
        XCTAssertTrue(line.contains("api_code=4"))
        XCTAssertFalse(line.contains(sensitiveMarker))
    }
}
