//
// Copyright 2026 Ermis Inc.
//

@testable import ErmisChat
import XCTest

final class E2eeAttachmentMessageBindingStateTests: XCTestCase {
    func testForceQuitFailureIsRepairedBeforeCompletedManifestSend() {
        XCTAssertEqual(
            MessageRepository.preparedE2eeAttachmentSendState(from: .sendingFailed),
            .pendingSend
        )
    }

    func testInterruptedSendIsRepairedForIdempotentReplay() {
        XCTAssertEqual(
            MessageRepository.preparedE2eeAttachmentSendState(from: .sending),
            .pendingSend
        )
        XCTAssertEqual(
            MessageRepository.preparedE2eeAttachmentSendState(
                from: .sendingAfterE2eeEpochStale
            ),
            .pendingSendAfterE2eeEpochStale
        )
    }

    func testPendingAndAuthoritativeStatesRemainUnchanged() {
        XCTAssertEqual(
            MessageRepository.preparedE2eeAttachmentSendState(from: .pendingSend),
            .pendingSend
        )
        XCTAssertNil(MessageRepository.preparedE2eeAttachmentSendState(from: nil))
    }
}
