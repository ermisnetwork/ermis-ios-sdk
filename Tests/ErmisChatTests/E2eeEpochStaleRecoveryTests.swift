import CoreData
import XCTest
import ErmisShared

@testable import ErmisChat

final class E2eeEpochStaleRecoveryTests: XCTestCase {
    private let cid = "team:project:epoch-stale"

    func testParsesOnlyAuthoritativeMessageEpochStaleContract() {
        let direct = ErmisApiError(
            type: .inputNotCorrect,
            statusCode: 400,
            message: "epoch_stale: message encrypted with epoch 4, current group epoch is 7"
        )
        XCTAssertEqual(
            E2eeMessageEpochStaleRejection.parse(direct),
            .init(rejectedEpoch: 4, currentGroupEpoch: 7)
        )

        let wrapped = ClientError(with: ErmisApiError(
            type: .inputNotCorrect,
            statusCode: 409,
            message: "epoch_stale: message encrypted with epoch 7, current group epoch is 8"
        ))
        XCTAssertEqual(
            E2eeMessageEpochStaleRejection.parse(wrapped),
            .init(rejectedEpoch: 7, currentGroupEpoch: 8)
        )
    }

    func testRejectsNonMessageOrNonAuthoritativeEpochErrors() {
        let protocolError = ErmisApiError(
            type: .inputNotCorrect,
            statusCode: 400,
            message: "epoch_stale: expected 7, got 4"
        )
        let serverError = ErmisApiError(
            type: .internalServerError,
            statusCode: 500,
            message: "epoch_stale: message encrypted with epoch 4, current group epoch is 7"
        )
        let malformed = ErmisApiError(
            type: .inputNotCorrect,
            statusCode: 400,
            message: "epoch_stale: message encrypted with epoch 4, current group epoch is secret"
        )

        XCTAssertNil(E2eeMessageEpochStaleRejection.parse(protocolError))
        XCTAssertNil(E2eeMessageEpochStaleRejection.parse(serverError))
        XCTAssertNil(E2eeMessageEpochStaleRejection.parse(malformed))
    }

    func testRebindRequiresExactIntentAndForwardEpoch() {
        let rejection = E2eeMessageEpochStaleRejection(rejectedEpoch: 4, currentGroupEpoch: 7)
        XCTAssertTrue(rejection.canRebind(intentEpoch: 4))
        XCTAssertFalse(rejection.canRebind(intentEpoch: 3))
        XCTAssertFalse(
            E2eeMessageEpochStaleRejection(rejectedEpoch: 4, currentGroupEpoch: 4)
                .canRebind(intentEpoch: 4)
        )
        XCTAssertFalse(rejection.isSatisfied(by: 6))
        XCTAssertTrue(rejection.isSatisfied(by: 7))
        XCTAssertTrue(rejection.isSatisfied(by: 8))
    }

    func testAuthoritativeSendRejectionPersistsRecoveryStateAndMinimumEpoch() throws {
        let database = try makeDatabase()
        defer { try? close(database) }

        try database.writeAndWait { session in
            let message = try makeMessage(in: session, id: "send-1")
            message.encryptedData = Data([1, 2, 3])
            message.mlsEpoch = 4
            message.localMessageState = .sending

            let changed = message.prepareForE2eeEpochStaleRebind(
                .init(rejectedEpoch: 4, currentGroupEpoch: 7),
                isEdit: false
            )

            XCTAssertTrue(changed)
            XCTAssertNil(message.encryptedData)
            XCTAssertEqual(message.mlsEpoch, 7)
            XCTAssertEqual(message.localMessageState, .pendingSendAfterE2eeEpochStale)
        }
    }

    func testMismatchedIntentIsNeverDiscarded() throws {
        let database = try makeDatabase()
        defer { try? close(database) }

        try database.writeAndWait { session in
            let message = try makeMessage(in: session, id: "send-2")
            message.encryptedData = Data([4, 5, 6])
            message.mlsEpoch = 5
            message.localMessageState = .sending

            let changed = message.prepareForE2eeEpochStaleRebind(
                .init(rejectedEpoch: 4, currentGroupEpoch: 7),
                isEdit: false
            )

            XCTAssertFalse(changed)
            XCTAssertEqual(message.encryptedData, Data([4, 5, 6]))
            XCTAssertEqual(message.mlsEpoch, 5)
            XCTAssertEqual(message.localMessageState, .sending)
        }
    }

    func testAuthoritativeEditRejectionPersistsRecoveryStateAndMinimumEpoch() throws {
        let database = try makeDatabase()
        defer { try? close(database) }

        try database.writeAndWait { session in
            let message = try makeMessage(in: session, id: "edit-1")
            message.encryptedData = Data([9, 8, 7])
            message.mlsEpoch = 11
            message.localMessageState = .syncing

            let changed = message.prepareForE2eeEpochStaleRebind(
                .init(rejectedEpoch: 11, currentGroupEpoch: 13),
                isEdit: true
            )

            XCTAssertTrue(changed)
            XCTAssertNil(message.encryptedData)
            XCTAssertEqual(message.mlsEpoch, 13)
            XCTAssertEqual(message.localMessageState, .pendingSyncAfterE2eeEpochStale)
        }
    }

    func testSecondEpochStaleRejectionCannotDiscardReplacementIntent() throws {
        let database = try makeDatabase()
        defer { try? close(database) }

        try database.writeAndWait { session in
            let send = try makeMessage(in: session, id: "send-second-stale")
            send.encryptedData = Data([1, 3, 5])
            send.mlsEpoch = 8
            send.localMessageState = .sendingAfterE2eeEpochStale

            let edit = try makeMessage(in: session, id: "edit-second-stale")
            edit.encryptedData = Data([2, 4, 6])
            edit.mlsEpoch = 9
            edit.localMessageState = .syncingAfterE2eeEpochStale

            XCTAssertFalse(send.prepareForE2eeEpochStaleRebind(
                .init(rejectedEpoch: 8, currentGroupEpoch: 10),
                isEdit: false
            ))
            XCTAssertFalse(edit.prepareForE2eeEpochStaleRebind(
                .init(rejectedEpoch: 9, currentGroupEpoch: 10),
                isEdit: true
            ))

            XCTAssertEqual(send.encryptedData, Data([1, 3, 5]))
            XCTAssertEqual(send.mlsEpoch, 8)
            XCTAssertEqual(send.localMessageState, .sendingAfterE2eeEpochStale)
            XCTAssertEqual(edit.encryptedData, Data([2, 4, 6]))
            XCTAssertEqual(edit.mlsEpoch, 9)
            XCTAssertEqual(edit.localMessageState, .syncingAfterE2eeEpochStale)
        }
    }

    func testRelaunchPreservesOneRetryBoundaryForSendAndEdit() throws {
        let database = try makeDatabase()
        defer { try? close(database) }

        try database.writeAndWait { session in
            let send = try makeMessage(in: session, id: "send-retry")
            send.encryptedData = Data([7, 7])
            send.mlsEpoch = 8
            send.localMessageState = .sendingAfterE2eeEpochStale

            let edit = try makeMessage(in: session, id: "edit-retry")
            edit.encryptedData = Data([8, 8])
            edit.mlsEpoch = 9
            edit.localMessageState = .syncingAfterE2eeEpochStale

            session.rescueMessagesStuckInSending()

            XCTAssertEqual(send.localMessageState, .pendingSendAfterE2eeEpochStale)
            XCTAssertEqual(send.encryptedData, Data([7, 7]))
            XCTAssertEqual(send.mlsEpoch, 8)
            XCTAssertEqual(edit.localMessageState, .pendingSyncAfterE2eeEpochStale)
            XCTAssertEqual(edit.encryptedData, Data([8, 8]))
            XCTAssertEqual(edit.mlsEpoch, 9)
        }
    }

    func testUnknownSendResultRelaunchRetriesExactNormalE2eeIntent() throws {
        let database = try makeDatabase()
        defer { try? close(database) }

        try database.writeAndWait { session in
            let message = try makeMessage(in: session, id: "unknown-send-result")
            let ciphertext = Data([10, 20, 30, 40])
            message.encryptedData = ciphertext
            message.mlsEpoch = 12
            message.localMessageState = .sending

            // Simulate process termination after POST started but before its result was durable.
            session.rescueMessagesStuckInSending()

            XCTAssertEqual(message.id, "unknown-send-result")
            XCTAssertEqual(message.localMessageState, .pendingSend)
            XCTAssertEqual(message.encryptedData, ciphertext)
            XCTAssertEqual(message.mlsEpoch, 12)
            let retryBody = message.asRequestBody() as MessageRequestBody
            XCTAssertEqual(retryBody.encryptedData, ciphertext.uint8Array)
            XCTAssertEqual(retryBody.mlsEpoch, 12)
        }
    }

    func testEpochRecoveryStatesRemainObservableByWorkers() throws {
        let database = try makeDatabase()
        defer { try? close(database) }

        try database.writeAndWait { session in
            let send = try makeMessage(in: session, id: "send-pending")
            send.localMessageState = .pendingSendAfterE2eeEpochStale

            let edit = try makeMessage(in: session, id: "edit-pending")
            edit.localMessageState = .pendingSyncAfterE2eeEpochStale
        }

        database.backgroundReadOnlyContext.performAndWait {
            let sends = try? database.backgroundReadOnlyContext.fetch(
                MessageDTO.messagesPendingSendFetchRequest()
            )
            let edits = try? database.backgroundReadOnlyContext.fetch(
                MessageDTO.messagesPendingSyncFetchRequest()
            )
            XCTAssertEqual(sends?.map(\.id), ["send-pending"])
            XCTAssertEqual(edits?.map(\.id), ["edit-pending"])
        }
    }

    private func makeDatabase() throws -> DatabaseContainer {
        let database = DatabaseContainer(
            kind: .inMemory,
            shouldResetEphemeralValuesOnStart: false
        )
        let storeLoaded = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                !database.persistentStoreCoordinator.persistentStores.isEmpty
            },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [storeLoaded], timeout: 5), .completed)
        return database
    }

    private func close(_ database: DatabaseContainer) throws {
        for context in database.allContext {
            context.performAndWait { context.reset() }
        }
        for store in database.persistentStoreCoordinator.persistentStores {
            try database.persistentStoreCoordinator.remove(store)
        }
    }

    private func makeMessage(in session: any DatabaseSession, id: String) throws -> MessageDTO {
        let channel = try session.saveChannel(payload: channelPayload(messageIds: [id]))
        return try XCTUnwrap(channel.messages.first { $0.id == id })
    }

    private func channelPayload(messageIds: [String]) throws -> ChannelPayload {
        let messages = messageIds.enumerated().map { index, id in
            """
            {
              "id": "\(id)",
              "type": "regular",
              "user": {"id": "sender", "project_id": "project"},
              "text": "",
              "mls_ciphertext": "AQID",
              "mls_epoch": \(index + 4),
              "created_at": "2026-08-07T02:0\(index):00.000Z",
              "updated_at": "2026-08-07T02:0\(index):00.000Z"
            }
            """
        }
        let json = """
        {
          "channel": {
            "cid": "\(cid)",
            "type": "team",
            "save_message": true,
            "last_message_at": "2026-08-07T02:10:00.000Z",
            "created_at": "2026-08-07T01:00:00.000Z",
            "updated_at": "2026-08-07T02:10:00.000Z",
            "member_count": 2,
            "mls_enabled": true
          },
          "messages": [\(messages.joined(separator: ","))],
          "read": []
        }
        """
        return try JSONDecoder.default.decode(ChannelPayload.self, from: Data(json.utf8))
    }
}
