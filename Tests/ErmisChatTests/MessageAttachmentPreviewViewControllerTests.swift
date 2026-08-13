//
// Copyright 2026 Ermis Inc.
//

@testable import ErmisChatUI
import Foundation
import XCTest

final class MessageAttachmentPreviewViewControllerTests: XCTestCase {
    func testOpaqueE2eeFileURLRequiresAuthenticatedResolver() {
        let opaqueURL = URL(string: "ermis-e2ee-attachment://asset/attachment-id/original-id")

        XCTAssertTrue(MessageAttachmentPreviewViewController.isOpaqueE2eeURL(opaqueURL))
    }

    func testStandardFileURLKeepsExistingPreviewPath() {
        let remoteURL = URL(string: "https://storage.example.test/document.pdf")
        let localURL = URL(fileURLWithPath: "/tmp/document.pdf")

        XCTAssertFalse(MessageAttachmentPreviewViewController.isOpaqueE2eeURL(remoteURL))
        XCTAssertFalse(MessageAttachmentPreviewViewController.isOpaqueE2eeURL(localURL))
        XCTAssertFalse(MessageAttachmentPreviewViewController.isOpaqueE2eeURL(nil))
    }
}
