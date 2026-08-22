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

    func testFilesRecognizesBroadVideoCandidatesWithoutClaimingNativePlayback() {
        for name in ["clip.mp4", "clip.mov", "clip.mkv", "clip.webm", "clip.hevc", "clip.h265"] {
            XCTAssertTrue(
                ComposerDocumentVideoRouting.isVideoCandidate(URL(fileURLWithPath: "/tmp/\(name)")),
                name
            )
        }
        XCTAssertFalse(
            ComposerDocumentVideoRouting.isVideoCandidate(URL(fileURLWithPath: "/tmp/document.pdf"))
        )
    }

    func testInvalidMkvCandidateCannotEnterNativeVideoLane() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mkv")
        try Data([0, 1, 2, 3]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(ComposerDocumentVideoRouting.isVideoCandidate(url))
        let isPlayable = await ComposerDocumentVideoRouting.isNativelyPlayable(url, timeout: 1)
        XCTAssertFalse(isPlayable)
    }
}
