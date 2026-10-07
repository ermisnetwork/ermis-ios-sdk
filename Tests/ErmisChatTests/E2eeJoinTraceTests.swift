//
// Copyright 2026 Ermis Inc.
//

@testable import ErmisChat
import XCTest

final class E2eeJoinTraceTests: XCTestCase {
    func testJoinTraceIncludesOnlyOperationalMetadata() {
        let line = E2eeJoinTrace.makeLine(
            stage: "welcome_processed",
            source: "scope_sync",
            context: .init(cid: "team:project:secret-channel"),
            traceSequence: 29,
            protocolType: "welcome",
            result: "joined",
            receipt: "merged",
            readiness: "syncing",
            groupLoaded: true,
            targetedAtCurrentUser: true,
            externalJoinScheduled: false,
            deferredSync: true,
            eventEpoch: 42,
            localEpoch: 42,
            firstDecryptableEpoch: 42,
            retriesRemaining: 2,
            delaySeconds: 6
        )

        XCTAssertEqual(
            line,
            "[E2EE_JOIN] stage=welcome_processed source=scope_sync trace_seq=29 "
                + "protocol_type=welcome result=joined receipt=merged readiness=syncing "
                + "group_loaded=true targeted_current_user=true external_join_scheduled=false "
                + "deferred_sync=true event_epoch=42 local_epoch=42 first_decryptable_epoch=42 "
                + "retries_remaining=2 delay_seconds=6"
        )
    }

    func testJoinTraceOmitsIdentifiersAndErrorDescriptions() {
        let sensitive = [
            "team:project:secret-channel",
            "secret-user-id",
            "secret-device-id",
            "secret-event-id",
            "secret-commit-hash",
            "secret-receipt-id",
            "SECRET_SERVER_RESPONSE",
        ]
        let error = NSError(
            domain: sensitive.joined(separator: "|"),
            code: -42,
            userInfo: [NSLocalizedDescriptionKey: sensitive.joined(separator: "|")]
        )
        let line = E2eeJoinTrace.makeLine(
            stage: "external_join_failed",
            source: "bootstrap",
            context: .init(cid: sensitive[0]),
            traceSequence: 30,
            error: error
        )

        XCTAssertTrue(line.contains("error_category=other"))
        sensitive.forEach { XCTAssertFalse(line.contains($0)) }
        XCTAssertFalse(line.localizedCaseInsensitiveContains("ciphertext="))
        XCTAssertFalse(line.localizedCaseInsensitiveContains("url="))
        XCTAssertFalse(line.localizedCaseInsensitiveContains("token="))
    }

    func testContextDoesNotRenderAnIdentityDerivedScopeAlias() {
        let line = E2eeJoinTrace.makeLine(
            stage: "bootstrap_started",
            source: "bootstrap",
            context: .init(cid: "team:project:secret-channel"),
            traceSequence: 31
        )

        XCTAssertFalse(line.contains("secret-channel"))
        XCTAssertFalse(line.contains("scope_seq"))
    }
}
