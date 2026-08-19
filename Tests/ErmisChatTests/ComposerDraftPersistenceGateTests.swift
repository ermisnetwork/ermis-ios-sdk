import XCTest
@testable import ErmisChat
@testable import ErmisChatUI

final class ComposerDraftPersistenceGateTests: XCTestCase {
    func testOnlyOneDraftCanBePersistedAtATime() {
        var gate = ComposerDraftPersistenceGate()

        XCTAssertTrue(gate.begin(revision: 1))
        XCTAssertFalse(gate.begin(revision: 1))
    }

    func testSuccessfulPersistenceClearsOnlyUnchangedDraft() {
        var gate = ComposerDraftPersistenceGate()
        XCTAssertTrue(gate.begin(revision: 1))
        gate.updateSubmittedRevision(2)

        XCTAssertTrue(gate.complete(succeeded: true, currentRevision: 2))
        XCTAssertNil(gate.submittedRevision)
    }

    func testFailureOrNewComposerInputPreservesDraftAndReleasesGate() {
        var failedGate = ComposerDraftPersistenceGate()
        XCTAssertTrue(failedGate.begin(revision: 1))
        XCTAssertFalse(failedGate.complete(succeeded: false, currentRevision: 1))
        XCTAssertNil(failedGate.submittedRevision)
        XCTAssertTrue(failedGate.begin(revision: 2))

        var editedGate = ComposerDraftPersistenceGate()
        XCTAssertTrue(editedGate.begin(revision: 4))
        XCTAssertFalse(editedGate.complete(succeeded: true, currentRevision: 5))
        XCTAssertNil(editedGate.submittedRevision)
    }

    func testAttachmentSizePolicyUsesTwoGiBBackendContractForAllUploadLanes() {
        let backendSafePlaintextLimit = Int64(2_147_287_040)

        XCTAssertEqual(
            ComposerAttachmentSizePolicy.maximumSize(
                standardLimit: backendSafePlaintextLimit,
                e2eeLimit: backendSafePlaintextLimit,
                isE2ee: false
            ),
            backendSafePlaintextLimit
        )
        XCTAssertEqual(
            ComposerAttachmentSizePolicy.maximumSize(
                standardLimit: backendSafePlaintextLimit,
                e2eeLimit: backendSafePlaintextLimit,
                isE2ee: true
            ),
            backendSafePlaintextLimit
        )
        XCTAssertEqual(AttachmentValidationError.fileSizeMaxLimitFallback, backendSafePlaintextLimit)
    }

    func testPhotoPickerVideoSourceDefersBytesUntilPendingMessageProcessing() {
        let url = ComposerPhotoPickerVideoSource.placeholderURL(fileName: "IMG_2831.MOV")

        XCTAssertTrue(url.isFileURL)
        XCTAssertTrue(url.isTemporaryItemProviderURL)
        XCTAssertEqual(url.lastPathComponent, "IMG_2831.MOV")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
