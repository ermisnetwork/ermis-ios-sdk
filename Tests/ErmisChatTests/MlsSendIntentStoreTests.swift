import XCTest
@testable import ErmisChat

final class MlsSendIntentStoreTests: XCTestCase {
    private func intent() -> MlsSendIntent {
        .init(version: 1, uuid: UUID().uuidString.lowercased(), owner: "owner-scope", cid: "team:project:send",
            scope: String(repeating: "a", count: 64), groupId: Data([1,2,3]), generation: 0,
            providerId: String(repeating: "b", count: 64), payload: Data("QA-original-intent".utf8),
            aad: Data(), originalEnvelope: Data("{}".utf8), phase: .unsealed, ciphertext: nil,
            epoch: nil, wireEnvelope: nil, revision: 0)
    }
    private func fixture(_ body: (URL, MlsSendIntentStore) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".db")
        try body(url, MlsSendIntentStore(url: url))
    }
    private func seal(_ original: MlsSendIntent) -> MlsSendIntent {
        var next = original; next.phase = .sealed; next.ciphertext = Data([7,8,9]); next.epoch = 1
        next.wireEnvelope = Data("{\"message\":{\"mls_ciphertext\":\"BwgJ\"}}".utf8); next.revision += 1
        return next
    }
    func testFailedUnsealedSurvivesRestartAndRequiresExplicitRetryCAS() throws {
        try fixture { url, store in
            let original = intent(); try store.save(original, replacing: nil, assertCurrent: {})
            var failed = original; failed.phase = .failedUnsealed; failed.revision += 1
            try store.save(failed, replacing: original, assertCurrent: {})
            let reopened = try MlsSendIntentStore(url: url)
            XCTAssertEqual(try reopened.load(uuid: original.uuid, owner: original.owner), failed)
            XCTAssertThrowsError(try reopened.save(seal(failed), replacing: failed, assertCurrent: {}))
            var retry = failed; retry.phase = .unsealed; retry.revision += 1
            try reopened.save(retry, replacing: failed, assertCurrent: {})
            XCTAssertThrowsError(try store.save(retry, replacing: failed, assertCurrent: {}))
            XCTAssertEqual(retry.payload, original.payload)
        }
    }
    func testDispatchAndCancelRetainExactCipherAndLateAcceptanceTruth() throws {
        try fixture { url, store in
            let original = intent(); try store.save(original, replacing: nil, assertCurrent: {})
            let sealed = seal(original); try store.save(sealed, replacing: original, assertCurrent: {})
            var dispatched = sealed; dispatched.phase = .dispatched; dispatched.revision += 1
            try store.save(dispatched, replacing: sealed, assertCurrent: {})
            var canceled = dispatched; canceled.phase = .canceledDispatched; canceled.revision += 1
            try store.save(canceled, replacing: dispatched, assertCurrent: {})
            let reopened = try MlsSendIntentStore(url: url)
            XCTAssertTrue(try XCTUnwrap(reopened.load(uuid: original.uuid, owner: original.owner)).requiresReconcile)
            var accepted = canceled; accepted.phase = .accepted; accepted.revision += 1
            try reopened.save(accepted, replacing: canceled, assertCurrent: {})
            XCTAssertEqual(accepted.ciphertext, sealed.ciphertext)
            var wrong = accepted; wrong.phase = .unsealed; wrong.revision += 1
            XCTAssertThrowsError(try reopened.save(wrong, replacing: accepted, assertCurrent: {}))
        }
    }
    func testForeignOrChangedIntentCannotReplaceExistingUUID() throws {
        try fixture { _, store in
            let original = intent(); try store.save(original, replacing: nil, assertCurrent: {})
            XCTAssertThrowsError(try store.load(uuid: original.uuid, owner: "foreign-owner"))
            XCTAssertThrowsError(try store.save(original, replacing: nil, assertCurrent: {}))
            var sealed = seal(original); sealed.ciphertext = Data([9]);
            try store.save(sealed, replacing: original, assertCurrent: {})
            var changed = sealed; changed.phase = .dispatched; changed.revision += 1; changed.ciphertext = Data([2])
            XCTAssertThrowsError(try store.save(changed, replacing: sealed, assertCurrent: {}))
        }
    }
    func testOwnerReplacementAtCommitRollsBackIntent() throws {
        try fixture { _, store in
            let original = intent(); var count = 0
            XCTAssertThrowsError(try store.save(original, replacing: nil, assertCurrent: {
                count += 1; if count == 2 { throw MlsSendIntentError.conflict }
            }))
            XCTAssertNil(try store.load(uuid: original.uuid, owner: original.owner))
        }
    }
    func testCancelBeforeDispatchCannotAcquireReconcileOrSendAuthority() throws {
        try fixture { _, store in
            let original = intent(); try store.save(original, replacing: nil, assertCurrent: {})
            var canceled = original; canceled.phase = .canceled; canceled.revision += 1
            try store.save(canceled, replacing: original, assertCurrent: {})
            XCTAssertFalse(canceled.requiresReconcile)
            XCTAssertThrowsError(try store.save(seal(canceled), replacing: canceled, assertCurrent: {}))
        }
    }
    func testTerminalRetirementObligationSurvivesReopenAndClearsWithCAS() throws {
        try fixture { url, store in
            let original = intent(); try store.save(original, replacing: nil, assertCurrent: {})
            var sealed = seal(original); sealed.nativeSealed = true
            try store.save(sealed, replacing: original, assertCurrent: {})
            var dispatched = sealed; dispatched.phase = .dispatched; dispatched.revision += 1
            try store.save(dispatched, replacing: sealed, assertCurrent: {})
            var accepted = dispatched; accepted.phase = .accepted; accepted.revision += 1
            try store.save(accepted, replacing: dispatched, assertCurrent: {})
            let reopened = try MlsSendIntentStore(url: url)
            XCTAssertEqual(try reopened.pendingRetirements(owner: original.owner), [accepted])
            var retired = accepted; retired.nativeRetired = true; retired.revision += 1
            try reopened.save(retired, replacing: accepted, assertCurrent: {})
            XCTAssertTrue(try reopened.pendingRetirements(owner: original.owner).isEmpty)
            XCTAssertThrowsError(try store.save(retired, replacing: accepted, assertCurrent: {}))
            XCTAssertEqual(try store.load(uuid: original.uuid, owner: original.owner)?.ciphertext, sealed.ciphertext)
        }
    }

}
