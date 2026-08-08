import XCTest
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
}
