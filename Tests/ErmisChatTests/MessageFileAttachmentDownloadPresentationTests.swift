//
// Copyright 2026 Ermis Inc.
//

import ErmisChat
@testable import ErmisChatUI
import Foundation
import XCTest

@MainActor
final class MessageFileAttachmentDownloadPresentationTests: XCTestCase {
    func testDownloadProgressRendersBesideLogicalFileSizeWithDistinctColor() throws {
        let attachment = try makeAttachment(fileSize: 48_300_000)
        let view = MessageFileAttachmentListView.ItemView()
        let hostView = installInHost(view)
        view.content = attachment

        view.downloadPresentation = .progress(.init(
            phase: .downloading,
            completedCiphertextBytes: 50,
            totalCiphertextBytes: 100
        ))

        XCTAssertFalse(view.downloadProgressView.isHidden)
        XCTAssertEqual(view.downloadProgressView.progress, 0.5, accuracy: 0.001)
        XCTAssertEqual(view.downloadProgressView.progressTintColor, .systemCyan)
        XCTAssertEqual(view.fileSizeLabel.textColor, .systemCyan)
        XCTAssertTrue(view.fileSizeLabel.text?.contains("/") == true)
        XCTAssertEqual(
            view.actionIconImageView.accessibilityLabel,
            L10n.Message.Actions.Download.inProgress
        )
        XCTAssertNotNil(hostView.subviews.first)
    }

    func testVerifiedDownloadPhasesAndSavedFolderActionReplaceByteProgress() throws {
        let attachment = try makeAttachment(fileSize: 48_300_000)
        let view = MessageFileAttachmentListView.ItemView()
        let hostView = installInHost(view)
        view.content = attachment

        view.downloadPresentation = .progress(.init(
            phase: .verifying,
            completedCiphertextBytes: 100,
            totalCiphertextBytes: 100
        ))
        XCTAssertEqual(view.fileSizeLabel.text, L10n.Message.Actions.Download.verifying)
        XCTAssertEqual(view.downloadProgressView.progress, 1, accuracy: 0.001)

        view.downloadPresentation = .choosingDestination
        XCTAssertEqual(
            view.fileSizeLabel.text,
            L10n.Message.Actions.Download.choosingDestination
        )

        view.downloadPresentation = .saved
        XCTAssertTrue(view.downloadProgressView.isHidden)
        XCTAssertEqual(
            view.fileSizeLabel.text,
            "\(L10n.Message.Actions.Download.saved) • \(L10n.Message.Actions.Download.showInFiles)"
        )
        XCTAssertEqual(view.fileSizeLabel.textColor, .systemGreen)
        XCTAssertNotNil(view.actionIconImageView.image)
        XCTAssertEqual(
            view.actionIconImageView.accessibilityLabel,
            L10n.Message.Actions.Download.showInFiles
        )
        XCTAssertNotNil(hostView.subviews.first)
    }

    func testListReappliesPresentationToMatchingAttachmentAfterCellConstruction() throws {
        let attachment = try makeAttachment(fileSize: 48_300_000)
        let list = MessageFileAttachmentListView()
        let hostView = installInHost(list)
        list.content = [attachment]

        list.setDownloadPresentation(.failed, for: attachment.id)

        let item = try XCTUnwrap(
            list.containerStackView.subviews.first as? MessageFileAttachmentListView.ItemView
        )
        XCTAssertEqual(item.downloadPresentation, .failed)
        XCTAssertEqual(item.fileSizeLabel.text, L10n.Message.Actions.Download.failureTitle)
        XCTAssertTrue(item.downloadProgressView.isHidden)
        XCTAssertNotNil(hostView.subviews.first)
    }

    private func installInHost(_ view: UIView) -> UIView {
        let hostView = UIView(frame: CGRect(x: 0, y: 0, width: 360, height: 120))
        view.frame = hostView.bounds
        hostView.addSubview(view)
        hostView.layoutIfNeeded()
        return hostView
    }

    private func makeAttachment(fileSize: Int64) throws -> MessageFileAttachment {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mkv")
        try Data([1, 2, 3, 4]).write(to: sourceURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: sourceURL) }
        let file = try AttachmentFile(url: sourceURL, fileSize: Int(fileSize))
        let cid = try ChannelId(cid: "messaging:test:file-download")
        let opaqueURL = try XCTUnwrap(
            URL(string: "ermis-e2ee-attachment://asset/attachment/original")
        )
        return MessageFileAttachment(
            id: .init(cid: cid, messageId: "file-download-message", index: 0),
            type: .file,
            payload: .init(title: "archive.mkv", assetRemoteURL: opaqueURL, file: file),
            thumbnailData: nil,
            uploadingState: nil
        )
    }
}
