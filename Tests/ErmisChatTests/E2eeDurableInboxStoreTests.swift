import CoreData
import XCTest
@testable import ErmisChat

final class E2eeDurableInboxStoreTests: XCTestCase {
    private let accountId = "account-1"
    private let scopeCid = "team:project:durable-inbox"

    private func makeDatabase() throws -> DatabaseContainer {
        try makeDatabase(kind: .inMemory)
    }

    private func makeDatabase(kind: DatabaseContainer.Kind) throws -> DatabaseContainer {
        let database = DatabaseContainer(
            kind: kind,
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

    private func envelope(
        eventId: String = "11111111-1111-4111-8111-111111111111",
        value: Int = 1,
        createdAt: String = "2026-08-06T10:00:00.123456Z"
    ) throws -> E2eSyncEventEnvelope {
        let json = """
        {
          "event_id": "\(eventId)",
          "created_at": "\(createdAt)",
          "type": "future_event",
          "data": {"value": \(value)}
        }
        """
        return try JSONDecoder.default.decode(E2eSyncEventEnvelope.self, from: Data(json.utf8))
    }

    private func applicationEnvelope(ciphertextJSON: String) throws -> E2eSyncEventEnvelope {
        let json = """
        {
          "event_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
          "created_at": "2026-08-06T10:00:00.123456Z",
          "type": "application",
          "data": {
            "id": "message-1",
            "type": "regular",
            "mls_ciphertext": \(ciphertextJSON),
            "content_type": "text/plain",
            "created_at": "2026-08-06T10:00:00.123456Z"
          }
        }
        """
        return try JSONDecoder.default.decode(E2eSyncEventEnvelope.self, from: Data(json.utf8))
    }

    private func protocolEnvelope(
        eventId: String,
        createdAt: String
    ) throws -> E2eSyncEventEnvelope {
        let json = """
        {
          "event_id": "\(eventId)",
          "created_at": "\(createdAt)",
          "type": "protocol",
          "data": {
            "epoch": 2,
            "user": {"id": "sender", "project_id": "project"},
            "type": "commit",
            "commit": "AA==",
            "created_at": "\(createdAt)"
          }
        }
        """
        return try JSONDecoder.default.decode(E2eSyncEventEnvelope.self, from: Data(json.utf8))
    }

    private func close(_ databases: [DatabaseContainer]) throws {
        for container in databases {
            for context in container.allContext {
                context.performAndWait { context.reset() }
            }
            for persistentStore in container.persistentStoreCoordinator.persistentStores {
                try container.persistentStoreCoordinator.remove(persistentStore)
            }
        }
    }

    func testPageAndFetchCursorArePersistedAtomically() throws {
        let database = try makeDatabase()
        let store = E2eeDurableInboxStore(database: database)
        let event = try envelope()
        let cursor = ScopeSyncCursorPayload(
            createdAt: event.createdAtRaw,
            eventId: event.eventId
        )

        let result = try store.persistPage(
            accountId: accountId,
            scopeCid: scopeCid,
            events: [event],
            hasMore: true,
            nextCursor: cursor
        )

        XCTAssertEqual(result.insertedEvents.map(\.eventId), [event.eventId])
        XCTAssertEqual(try store.fetchCursor(accountId: accountId, scopeCid: scopeCid), cursor)
        XCTAssertEqual(try store.loadPendingEvents(accountId: accountId, scopeCid: scopeCid).map(\.eventId), [event.eventId])
        XCTAssertNil(try store.applyCursor(accountId: accountId, scopeCid: scopeCid))
    }

    func testSamePageIsIdempotent() throws {
        let database = try makeDatabase()
        let store = E2eeDurableInboxStore(database: database)
        let event = try envelope()
        let cursor = ScopeSyncCursorPayload(createdAt: event.createdAtRaw, eventId: event.eventId)

        _ = try store.persistPage(
            accountId: accountId,
            scopeCid: scopeCid,
            events: [event],
            hasMore: false,
            nextCursor: cursor
        )
        let duplicate = try store.persistPage(
            accountId: accountId,
            scopeCid: scopeCid,
            events: [event],
            hasMore: false,
            nextCursor: cursor
        )

        XCTAssertTrue(duplicate.insertedEvents.isEmpty)
        XCTAssertEqual(try store.loadPendingEvents(accountId: accountId, scopeCid: scopeCid).count, 1)
    }

    func testDurableReplayPreservesBellboyKindRankAtSameTimestamp() throws {
        let database = try makeDatabase()
        let store = E2eeDurableInboxStore(database: database)
        let createdAt = "2026-08-06T10:00:00.123456Z"
        let application = try applicationEnvelope(ciphertextJSON: #""AAEC""#)
        let protocolEvent = try protocolEnvelope(
            eventId: "ffffffff-ffff-4fff-8fff-ffffffffffff",
            createdAt: createdAt
        )

        // The application UUID sorts first lexically. Bellboy's kind rank must still place the
        // protocol event first after the durable store is reopened/reloaded.
        _ = try store.persistPage(
            accountId: accountId,
            scopeCid: scopeCid,
            events: [protocolEvent, application],
            hasMore: false,
            nextCursor: nil
        )

        XCTAssertEqual(
            try store.loadPendingEvents(accountId: accountId, scopeCid: scopeCid).map(\.eventId),
            [protocolEvent.eventId, application.eventId]
        )
        XCTAssertThrowsError(
            try store.markApplied(
                accountId: accountId,
                scopeCid: scopeCid,
                envelope: application
            )
        ) { error in
            XCTAssertEqual(
                error as? E2eeDurableInboxError,
                .outOfOrderApply(
                    expectedEventId: protocolEvent.eventId,
                    actualEventId: application.eventId
                )
            )
        }
    }

    func testLegacyArrayAndBase64EventAreTheSameDurableEvent() throws {
        let database = try makeDatabase()
        let store = E2eeDurableInboxStore(database: database)
        let legacyEvent = try applicationEnvelope(ciphertextJSON: "[0,1,2]")
        let base64Event = try applicationEnvelope(ciphertextJSON: #""AAEC""#)
        _ = try store.persistPage(
            accountId: accountId,
            scopeCid: scopeCid,
            events: [legacyEvent],
            hasMore: false,
            nextCursor: nil
        )

        // Simulate a row written by an older SDK before canonical raw-envelope persistence.
        let legacyRaw = Data("""
        {
          "event_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
          "created_at": "2026-08-06T10:00:00.123456Z",
          "type": "application",
          "data": {
            "id": "message-1",
            "type": "regular",
            "mls_ciphertext": [0,1,2],
            "content_type": "text/plain",
            "created_at": "2026-08-06T10:00:00.123456Z"
          }
        }
        """.utf8)
        try database.writeAndWait { context in
            guard let context = context as? NSManagedObjectContext,
                  let row = try E2eeInboxEventDTO.load(
                    accountId: accountId,
                    scopeCid: scopeCid,
                    eventId: legacyEvent.eventId,
                    context: context
                  ) else {
                return XCTFail("Expected durable inbox row")
            }
            row.rawEnvelope = legacyRaw
        }

        let duplicate = try store.persistPage(
            accountId: accountId,
            scopeCid: scopeCid,
            events: [base64Event],
            hasMore: false,
            nextCursor: nil
        )

        XCTAssertTrue(duplicate.insertedEvents.isEmpty)
        XCTAssertEqual(try store.loadPendingEvents(accountId: accountId, scopeCid: scopeCid).count, 1)
        database.writableContext.performAndWait {
            let stored = try? E2eeInboxEventDTO.load(
                accountId: accountId,
                scopeCid: scopeCid,
                eventId: legacyEvent.eventId,
                context: database.writableContext
            )?.rawEnvelope
            XCTAssertEqual(stored, base64Event.rawEnvelope)
        }
    }

    func testCommitProofPersistsBeforeMlsStateMarker() throws {
        let store = E2eeDurableInboxStore(database: try makeDatabase())
        let event = try envelope()
        _ = try store.persistPage(
            accountId: accountId,
            scopeCid: scopeCid,
            events: [event],
            hasMore: false,
            nextCursor: nil
        )
        let ciphertextHash = Data(repeating: 0xa5, count: 32)

        try store.markCommitProofPersisted(
            accountId: accountId,
            scopeCid: scopeCid,
            eventId: event.eventId,
            ciphertextHash: ciphertextHash,
            targetEpoch: 42
        )
        XCTAssertEqual(
            try store.commitPersistenceProof(
                accountId: accountId,
                scopeCid: scopeCid,
                eventId: event.eventId
            ),
            .init(
                ciphertextHash: ciphertextHash,
                targetEpoch: 42,
                mlsStatePersisted: false
            )
        )

        try store.markCommitStatePersisted(
            accountId: accountId,
            scopeCid: scopeCid,
            eventId: event.eventId,
            ciphertextHash: ciphertextHash,
            targetEpoch: 42
        )
        XCTAssertEqual(
            try store.commitPersistenceProof(
                accountId: accountId,
                scopeCid: scopeCid,
                eventId: event.eventId
            ),
            .init(
                ciphertextHash: ciphertextHash,
                targetEpoch: 42,
                mlsStatePersisted: true
            )
        )
    }

    func testCommitProofRejectsHashAndEpochMismatch() throws {
        let store = E2eeDurableInboxStore(database: try makeDatabase())
        let event = try envelope()
        _ = try store.persistPage(
            accountId: accountId,
            scopeCid: scopeCid,
            events: [event],
            hasMore: false,
            nextCursor: nil
        )
        let ciphertextHash = Data(repeating: 0xa5, count: 32)
        try store.markCommitProofPersisted(
            accountId: accountId,
            scopeCid: scopeCid,
            eventId: event.eventId,
            ciphertextHash: ciphertextHash,
            targetEpoch: 42
        )

        XCTAssertThrowsError(
            try store.markCommitProofPersisted(
                accountId: accountId,
                scopeCid: scopeCid,
                eventId: event.eventId,
                ciphertextHash: Data(repeating: 0x5a, count: 32),
                targetEpoch: 42
            )
        ) {
            XCTAssertEqual(
                $0 as? E2eeDurableInboxError,
                .protocolCommitProofMismatch(eventId: event.eventId)
            )
        }
        XCTAssertThrowsError(
            try store.markCommitStatePersisted(
                accountId: accountId,
                scopeCid: scopeCid,
                eventId: event.eventId,
                ciphertextHash: ciphertextHash,
                targetEpoch: 43
            )
        ) {
            XCTAssertEqual(
                $0 as? E2eeDurableInboxError,
                .protocolCommitProofMismatch(eventId: event.eventId)
            )
        }
    }

    func testHistoricalCommitIsAtomicallySupersededAndResolvesRepair() throws {
        let database = try makeDatabase()
        let store = E2eeDurableInboxStore(database: database)
        let event = try protocolEnvelope(
            eventId: "11111111-1111-4111-8111-111111111111",
            createdAt: "2026-08-06T10:00:00.123456Z"
        )
        _ = try store.persistPage(
            accountId: accountId,
            scopeCid: scopeCid,
            events: [event],
            hasMore: false,
            nextCursor: nil
        )
        try store.recordRepairIssue(
            accountId: accountId,
            scopeCid: scopeCid,
            eventId: event.eventId,
            category: "epoch_mismatch",
            details: "local=4,event=2"
        )
        let ciphertextHash = Data(repeating: 0xc4, count: 32)

        try store.markCommitSuperseded(
            accountId: accountId,
            scopeCid: scopeCid,
            envelope: event,
            ciphertextHash: ciphertextHash,
            targetEpoch: 2
        )

        XCTAssertTrue(try store.loadPendingEvents(accountId: accountId, scopeCid: scopeCid).isEmpty)
        XCTAssertEqual(
            try store.applyCursor(accountId: accountId, scopeCid: scopeCid),
            ScopeSyncCursorPayload(createdAt: event.createdAtRaw, eventId: event.eventId)
        )
        XCTAssertEqual(
            try store.commitPersistenceProof(
                accountId: accountId,
                scopeCid: scopeCid,
                eventId: event.eventId
            ),
            .init(
                ciphertextHash: ciphertextHash,
                targetEpoch: 2,
                mlsStatePersisted: false
            )
        )

        var failureCategory: String?
        var unresolvedRepairCount = -1
        database.writableContext.performAndWait {
            failureCategory = try? E2eeInboxEventDTO.load(
                accountId: accountId,
                scopeCid: scopeCid,
                eventId: event.eventId,
                context: database.writableContext
            )?.failureCategory
            let request = NSFetchRequest<E2eeRepairIssueDTO>(entityName: E2eeRepairIssueDTO.entityName)
            request.predicate = NSPredicate(
                format: "accountId == %@ AND scopeCid == %@ AND eventId == %@ AND resolvedAt == nil",
                accountId,
                scopeCid,
                event.eventId
            )
            unresolvedRepairCount = (try? database.writableContext.count(for: request)) ?? -1
        }
        XCTAssertEqual(failureCategory, E2eeDurableInboxStore.supersededCommitCategory)
        XCTAssertEqual(unresolvedRepairCount, 0)

        // Relaunch/replay of the same finalized event is an idempotent no-op and must not move
        // the apply cursor or mutate the proof.
        try store.markCommitSuperseded(
            accountId: accountId,
            scopeCid: scopeCid,
            envelope: event,
            ciphertextHash: ciphertextHash,
            targetEpoch: 2
        )
        XCTAssertEqual(
            try store.applyCursor(accountId: accountId, scopeCid: scopeCid),
            ScopeSyncCursorPayload(createdAt: event.createdAtRaw, eventId: event.eventId)
        )
    }

    func testSupersededCommitCannotSkipEarlierPendingEvent() throws {
        let database = try makeDatabase()
        let store = E2eeDurableInboxStore(database: database)
        let first = try protocolEnvelope(
            eventId: "11111111-1111-4111-8111-111111111111",
            createdAt: "2026-08-06T10:00:00.000000Z"
        )
        let second = try protocolEnvelope(
            eventId: "22222222-2222-4222-8222-222222222222",
            createdAt: "2026-08-06T10:00:01.000000Z"
        )
        _ = try store.persistPage(
            accountId: accountId,
            scopeCid: scopeCid,
            events: [first, second],
            hasMore: false,
            nextCursor: nil
        )

        XCTAssertThrowsError(
            try store.markCommitSuperseded(
                accountId: accountId,
                scopeCid: scopeCid,
                envelope: second,
                ciphertextHash: Data(repeating: 0xc4, count: 32),
                targetEpoch: 2
            )
        ) {
            XCTAssertEqual(
                $0 as? E2eeDurableInboxError,
                .outOfOrderApply(expectedEventId: first.eventId, actualEventId: second.eventId)
            )
        }
        XCTAssertNil(try store.applyCursor(accountId: accountId, scopeCid: scopeCid))
        XCTAssertEqual(
            try store.loadPendingEvents(accountId: accountId, scopeCid: scopeCid).map(\.eventId),
            [first.eventId, second.eventId]
        )
        XCTAssertNil(
            try store.commitPersistenceProof(
                accountId: accountId,
                scopeCid: scopeCid,
                eventId: second.eventId
            )
        )
    }

    func testSupersededCommitProofMismatchRollsBackApplyState() throws {
        let database = try makeDatabase()
        let store = E2eeDurableInboxStore(database: database)
        let event = try protocolEnvelope(
            eventId: "11111111-1111-4111-8111-111111111111",
            createdAt: "2026-08-06T10:00:00.123456Z"
        )
        _ = try store.persistPage(
            accountId: accountId,
            scopeCid: scopeCid,
            events: [event],
            hasMore: false,
            nextCursor: nil
        )
        let originalHash = Data(repeating: 0xa5, count: 32)
        try store.markCommitProofPersisted(
            accountId: accountId,
            scopeCid: scopeCid,
            eventId: event.eventId,
            ciphertextHash: originalHash,
            targetEpoch: 2
        )

        XCTAssertThrowsError(
            try store.markCommitSuperseded(
                accountId: accountId,
                scopeCid: scopeCid,
                envelope: event,
                ciphertextHash: Data(repeating: 0x5a, count: 32),
                targetEpoch: 2
            )
        ) {
            XCTAssertEqual(
                $0 as? E2eeDurableInboxError,
                .protocolCommitProofMismatch(eventId: event.eventId)
            )
        }
        XCTAssertNil(try store.applyCursor(accountId: accountId, scopeCid: scopeCid))
        XCTAssertEqual(
            try store.loadPendingEvents(accountId: accountId, scopeCid: scopeCid).map(\.eventId),
            [event.eventId]
        )
        XCTAssertEqual(
            try store.commitPersistenceProof(
                accountId: accountId,
                scopeCid: scopeCid,
                eventId: event.eventId
            ),
            .init(
                ciphertextHash: originalHash,
                targetEpoch: 2,
                mlsStatePersisted: false
            )
        )
    }

    func testDuplicateEventIdWithDifferentPayloadIsRejected() throws {
        let database = try makeDatabase()
        let store = E2eeDurableInboxStore(database: database)
        let original = try envelope(value: 1)
        let changed = try envelope(value: 2)

        _ = try store.persistPage(
            accountId: accountId,
            scopeCid: scopeCid,
            events: [original],
            hasMore: false,
            nextCursor: nil
        )

        XCTAssertThrowsError(
            try store.persistPage(
                accountId: accountId,
                scopeCid: scopeCid,
                events: [changed],
                hasMore: false,
                nextCursor: nil
            )
        ) {
            XCTAssertEqual(
                $0 as? E2eeDurableInboxError,
                .duplicateEventPayloadMismatch(eventId: original.eventId)
            )
        }
        XCTAssertEqual(try store.loadPendingEvents(accountId: accountId, scopeCid: scopeCid).count, 1)
    }

    func testHasMoreRequiresAuthoritativeNextCursor() throws {
        let store = E2eeDurableInboxStore(database: try makeDatabase())
        XCTAssertThrowsError(
            try store.persistPage(
                accountId: accountId,
                scopeCid: scopeCid,
                events: [try envelope()],
                hasMore: true,
                nextCursor: nil
            )
        ) {
            XCTAssertEqual($0 as? E2eeDurableInboxError, .invalidPagination(scopeCid: scopeCid))
        }
    }

    func testBacklogWarningSnapshotAtSoftThreshold() throws {
        let store = E2eeDurableInboxStore(
            database: try makeDatabase(),
            limits: .init(
                scopeWarningCount: 2,
                scopeMaximumCount: 3,
                accountWarningCount: 10,
                accountMaximumCount: 20,
                pageMaximumRawBytes: 1_024 * 1_024
            )
        )
        let first = try envelope()
        let second = try envelope(
            eventId: "22222222-2222-4222-8222-222222222222",
            createdAt: "2026-08-06T10:00:01.000000Z"
        )

        let result = try store.persistPage(
            accountId: accountId,
            scopeCid: scopeCid,
            events: [first, second],
            hasMore: false,
            nextCursor: nil
        )

        XCTAssertEqual(result.backlog.scopePendingCount, 2)
        XCTAssertEqual(result.backlog.accountPendingCount, 2)
        XCTAssertEqual(result.backlog.insertedEventCount, 2)
        XCTAssertEqual(result.backlog.pageRawBytes, first.rawEnvelope.count + second.rawEnvelope.count)
        XCTAssertTrue(result.backlog.warningThresholdExceeded)
    }

    func testScopeBacklogHardLimitRejectsWholePageAndCursor() throws {
        let database = try makeDatabase()
        let store = E2eeDurableInboxStore(
            database: database,
            limits: .init(
                scopeWarningCount: 2,
                scopeMaximumCount: 3,
                accountWarningCount: 10,
                accountMaximumCount: 20,
                pageMaximumRawBytes: 1_024 * 1_024
            )
        )
        let first = try envelope()
        let second = try envelope(
            eventId: "22222222-2222-4222-8222-222222222222",
            createdAt: "2026-08-06T10:00:01.000000Z"
        )
        _ = try store.persistPage(
            accountId: accountId,
            scopeCid: scopeCid,
            events: [first, second],
            hasMore: false,
            nextCursor: nil
        )

        let third = try envelope(
            eventId: "33333333-3333-4333-8333-333333333333",
            createdAt: "2026-08-06T10:00:02.000000Z"
        )
        let fourth = try envelope(
            eventId: "44444444-4444-4444-8444-444444444444",
            createdAt: "2026-08-06T10:00:03.000000Z"
        )
        let rejectedCursor = ScopeSyncCursorPayload(
            createdAt: fourth.createdAtRaw,
            eventId: fourth.eventId
        )

        XCTAssertThrowsError(
            try store.persistPage(
                accountId: accountId,
                scopeCid: scopeCid,
                events: [third, fourth],
                hasMore: true,
                nextCursor: rejectedCursor
            )
        ) {
            XCTAssertEqual(
                $0 as? E2eeDurableInboxError,
                .backlogLimitExceeded(
                    scopeCid: scopeCid,
                    scopePending: 4,
                    accountPending: 4
                )
            )
        }
        XCTAssertEqual(
            try store.loadPendingEvents(accountId: accountId, scopeCid: scopeCid).map(\.eventId),
            [first.eventId, second.eventId]
        )
        XCTAssertNil(try store.fetchCursor(accountId: accountId, scopeCid: scopeCid))
    }

    func testAccountBacklogHardLimitAppliesAcrossScopes() throws {
        let database = try makeDatabase()
        let store = E2eeDurableInboxStore(
            database: database,
            limits: .init(
                scopeWarningCount: 10,
                scopeMaximumCount: 10,
                accountWarningCount: 2,
                accountMaximumCount: 3,
                pageMaximumRawBytes: 1_024 * 1_024
            )
        )
        let first = try envelope()
        let second = try envelope(
            eventId: "22222222-2222-4222-8222-222222222222",
            createdAt: "2026-08-06T10:00:01.000000Z"
        )
        _ = try store.persistPage(
            accountId: accountId,
            scopeCid: scopeCid,
            events: [first, second],
            hasMore: false,
            nextCursor: nil
        )

        let otherScope = "team:project:durable-inbox-2"
        let third = try envelope(
            eventId: "33333333-3333-4333-8333-333333333333",
            createdAt: "2026-08-06T10:00:02.000000Z"
        )
        let fourth = try envelope(
            eventId: "44444444-4444-4444-8444-444444444444",
            createdAt: "2026-08-06T10:00:03.000000Z"
        )

        XCTAssertThrowsError(
            try store.persistPage(
                accountId: accountId,
                scopeCid: otherScope,
                events: [third, fourth],
                hasMore: false,
                nextCursor: nil
            )
        ) {
            XCTAssertEqual(
                $0 as? E2eeDurableInboxError,
                .backlogLimitExceeded(
                    scopeCid: otherScope,
                    scopePending: 2,
                    accountPending: 4
                )
            )
        }
        XCTAssertTrue(try store.loadPendingEvents(accountId: accountId, scopeCid: otherScope).isEmpty)
    }

    func testOversizedRawPageIsRejectedBeforePersistence() throws {
        let database = try makeDatabase()
        let event = try envelope()
        let maximumRawBytes = event.rawEnvelope.count - 1
        let store = E2eeDurableInboxStore(
            database: database,
            limits: .init(
                scopeWarningCount: 10,
                scopeMaximumCount: 20,
                accountWarningCount: 20,
                accountMaximumCount: 40,
                pageMaximumRawBytes: maximumRawBytes
            )
        )

        XCTAssertThrowsError(
            try store.persistPage(
                accountId: accountId,
                scopeCid: scopeCid,
                events: [event],
                hasMore: false,
                nextCursor: nil
            )
        ) {
            XCTAssertEqual(
                $0 as? E2eeDurableInboxError,
                .pageTooLarge(
                    scopeCid: scopeCid,
                    rawBytes: event.rawEnvelope.count,
                    maximumRawBytes: maximumRawBytes
                )
            )
        }
        XCTAssertTrue(try store.loadPendingEvents(accountId: accountId, scopeCid: scopeCid).isEmpty)
    }

    func testPageFailureRollsBackNewEventsAndFetchCursor() throws {
        let database = try makeDatabase()
        let store = E2eeDurableInboxStore(database: database)
        let original = try envelope(value: 1)
        _ = try store.persistPage(
            accountId: accountId,
            scopeCid: scopeCid,
            events: [original],
            hasMore: false,
            nextCursor: nil
        )

        let newEvent = try envelope(
            eventId: "22222222-2222-4222-8222-222222222222",
            createdAt: "2026-08-06T10:00:01.000000Z"
        )
        let conflictingDuplicate = try envelope(value: 2)
        let rejectedCursor = ScopeSyncCursorPayload(
            createdAt: newEvent.createdAtRaw,
            eventId: newEvent.eventId
        )

        XCTAssertThrowsError(
            try store.persistPage(
                accountId: accountId,
                scopeCid: scopeCid,
                events: [newEvent, conflictingDuplicate],
                hasMore: false,
                nextCursor: rejectedCursor
            )
        )
        XCTAssertEqual(
            try store.loadPendingEvents(accountId: accountId, scopeCid: scopeCid).map(\.eventId),
            [original.eventId]
        )
        XCTAssertNil(try store.fetchCursor(accountId: accountId, scopeCid: scopeCid))
    }

    func testPendingEventsLoadInCanonicalOrder() throws {
        let database = try makeDatabase()
        let store = E2eeDurableInboxStore(database: database)
        let later = try envelope(
            eventId: "22222222-2222-4222-8222-222222222222",
            createdAt: "2026-08-06T10:00:01.000000Z"
        )
        let earlier = try envelope(
            eventId: "11111111-1111-4111-8111-111111111111",
            createdAt: "2026-08-06T10:00:00.000000Z"
        )
        _ = try store.persistPage(
            accountId: accountId,
            scopeCid: scopeCid,
            events: [later, earlier],
            hasMore: false,
            nextCursor: nil
        )

        XCTAssertEqual(
            try store.loadPendingEvents(accountId: accountId, scopeCid: scopeCid).map(\.eventId),
            [earlier.eventId, later.eventId]
        )
    }

    func testApplyCursorAdvancesIndependentlyFromFetchCursor() throws {
        let database = try makeDatabase()
        let store = E2eeDurableInboxStore(database: database)
        let event = try envelope()
        let fetchCursor = ScopeSyncCursorPayload(
            createdAt: "2026-08-06T10:00:01.000000Z",
            eventId: "22222222-2222-4222-8222-222222222222"
        )
        _ = try store.persistPage(
            accountId: accountId,
            scopeCid: scopeCid,
            events: [event],
            hasMore: false,
            nextCursor: fetchCursor
        )

        try store.markApplied(accountId: accountId, scopeCid: scopeCid, envelope: event)

        XCTAssertEqual(try store.fetchCursor(accountId: accountId, scopeCid: scopeCid), fetchCursor)
        XCTAssertEqual(
            try store.applyCursor(accountId: accountId, scopeCid: scopeCid),
            ScopeSyncCursorPayload(createdAt: event.createdAtRaw, eventId: event.eventId)
        )
        XCTAssertTrue(try store.loadPendingEvents(accountId: accountId, scopeCid: scopeCid).isEmpty)
    }

    func testRemovedPageAtomicallyClearsScopeDurabilityAndAdvancesRemovedCursor() throws {
        let database = try makeDatabase()
        let store = E2eeDurableInboxStore(database: database)
        let event = try envelope()
        let scopeCursor = ScopeSyncCursorPayload(
            createdAt: event.createdAtRaw,
            eventId: event.eventId
        )
        _ = try store.persistPage(
            accountId: accountId,
            scopeCid: scopeCid,
            events: [event],
            hasMore: false,
            nextCursor: scopeCursor
        )
        try store.recordRepairIssue(
            accountId: accountId,
            scopeCid: scopeCid,
            eventId: event.eventId,
            category: "test_repair",
            details: nil
        )

        let removedCursor = RemovedSyncCursorPayload(
            removedAt: "2026-08-06T10:01:00.123456Z",
            eventId: "33333333-3333-4333-8333-333333333333"
        )
        try store.commitRemovedPage(
            accountId: accountId,
            channelCids: [try ChannelId(cid: scopeCid)],
            scopeCids: [scopeCid],
            nextCursor: removedCursor
        )

        XCTAssertTrue(try store.loadPendingEvents(accountId: accountId, scopeCid: scopeCid).isEmpty)
        XCTAssertNil(try store.fetchCursor(accountId: accountId, scopeCid: scopeCid))
        XCTAssertNil(try store.applyCursor(accountId: accountId, scopeCid: scopeCid))
        XCTAssertEqual(try store.removedCursor(accountId: accountId), removedCursor)

        var repairCount = -1
        database.writableContext.performAndWait {
            let request = NSFetchRequest<E2eeRepairIssueDTO>(entityName: E2eeRepairIssueDTO.entityName)
            request.predicate = NSPredicate(
                format: "accountId == %@ AND scopeCid == %@",
                accountId,
                scopeCid
            )
            repairCount = (try? database.writableContext.count(for: request)) ?? -1
        }
        XCTAssertEqual(repairCount, 0)
    }

    func testApplyRejectsSkippingEarlierPendingEvent() throws {
        let database = try makeDatabase()
        let store = E2eeDurableInboxStore(database: database)
        let first = try envelope(
            eventId: "11111111-1111-4111-8111-111111111111",
            createdAt: "2026-08-06T10:00:00.000000Z"
        )
        let second = try envelope(
            eventId: "22222222-2222-4222-8222-222222222222",
            createdAt: "2026-08-06T10:00:01.000000Z"
        )
        _ = try store.persistPage(
            accountId: accountId,
            scopeCid: scopeCid,
            events: [first, second],
            hasMore: false,
            nextCursor: nil
        )

        XCTAssertThrowsError(
            try store.markApplied(accountId: accountId, scopeCid: scopeCid, envelope: second)
        ) {
            XCTAssertEqual(
                $0 as? E2eeDurableInboxError,
                .outOfOrderApply(expectedEventId: first.eventId, actualEventId: second.eventId)
            )
        }
        XCTAssertNil(try store.applyCursor(accountId: accountId, scopeCid: scopeCid))
        XCTAssertEqual(
            try store.loadPendingEvents(accountId: accountId, scopeCid: scopeCid).map(\.eventId),
            [first.eventId, second.eventId]
        )
    }

    func testRepairIssueKeepsEventPendingAndRecordsCategory() throws {
        let database = try makeDatabase()
        let store = E2eeDurableInboxStore(database: database)
        let event = try envelope()
        _ = try store.persistPage(
            accountId: accountId,
            scopeCid: scopeCid,
            events: [event],
            hasMore: false,
            nextCursor: nil
        )

        try store.recordRepairIssue(
            accountId: accountId,
            scopeCid: scopeCid,
            eventId: event.eventId,
            category: "epoch_mismatch",
            details: "local=3,event=5"
        )

        XCTAssertEqual(try store.loadPendingEvents(accountId: accountId, scopeCid: scopeCid).map(\.eventId), [event.eventId])
        var category: String?
        database.writableContext.performAndWait {
            category = try? E2eeInboxEventDTO.load(
                accountId: accountId,
                scopeCid: scopeCid,
                eventId: event.eventId,
                context: database.writableContext
            )?.failureCategory
        }
        XCTAssertEqual(category, "epoch_mismatch")
        XCTAssertNil(try store.applyCursor(accountId: accountId, scopeCid: scopeCid))
    }

    func testApplicationRepairCanAdvanceCursorWithoutClearingFailureProof() throws {
        let database = try makeDatabase()
        let store = E2eeDurableInboxStore(database: database)
        let event = try applicationEnvelope(ciphertextJSON: #""AAEC""#)
        _ = try store.persistPage(
            accountId: accountId,
            scopeCid: scopeCid,
            events: [event],
            hasMore: false,
            nextCursor: nil
        )
        try store.recordRepairIssue(
            accountId: accountId,
            scopeCid: scopeCid,
            eventId: event.eventId,
            category: "application_decrypt_failed",
            details: "test"
        )

        try store.markApplied(
            accountId: accountId,
            scopeCid: scopeCid,
            envelope: event,
            preservingFailure: true
        )

        XCTAssertEqual(
            try store.applyCursor(accountId: accountId, scopeCid: scopeCid),
            ScopeSyncCursorPayload(createdAt: event.createdAtRaw, eventId: event.eventId)
        )
        XCTAssertTrue(try store.loadPendingEvents(accountId: accountId, scopeCid: scopeCid).isEmpty)
        var category: String?
        database.writableContext.performAndWait {
            category = try? E2eeInboxEventDTO.load(
                accountId: accountId,
                scopeCid: scopeCid,
                eventId: event.eventId,
                context: database.writableContext
            )?.failureCategory
        }
        XCTAssertEqual(category, "application_decrypt_failed")
    }

    func testPendingPageSurvivesDatabaseReopen() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("E2eeDurableInboxStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("chat.sqlite")
        let event = try envelope()
        let cursor = ScopeSyncCursorPayload(createdAt: event.createdAtRaw, eventId: event.eventId)

        let database = try makeDatabase(kind: .onDisk(databaseFileURL: databaseURL))
        let store = E2eeDurableInboxStore(database: database)
        _ = try store.persistPage(
            accountId: accountId,
            scopeCid: scopeCid,
            events: [event],
            hasMore: false,
            nextCursor: cursor
        )

        let reopenedDatabase = try makeDatabase(kind: .onDisk(databaseFileURL: databaseURL))
        let reopenedStore = E2eeDurableInboxStore(database: reopenedDatabase)
        XCTAssertEqual(
            try reopenedStore.loadPendingEvents(accountId: accountId, scopeCid: scopeCid).map(\.eventId),
            [event.eventId]
        )
        XCTAssertEqual(try reopenedStore.fetchCursor(accountId: accountId, scopeCid: scopeCid), cursor)
        XCTAssertNil(try reopenedStore.applyCursor(accountId: accountId, scopeCid: scopeCid))

        try close([database, reopenedDatabase])
        try FileManager.default.removeItem(at: directory)
    }

    func testVersionTwoStoreLightweightMigratesToDurabilitySchema() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("E2eeDurabilityMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("chat.sqlite")

        let modelDirectory = try XCTUnwrap(
            Bundle.ermisChat.url(forResource: "ErmisChatModel", withExtension: "momd")
        )
        let versionTwoURL = modelDirectory.appendingPathComponent("ErmisChatModel 2.mom")
        let versionTwoModel = try XCTUnwrap(NSManagedObjectModel(contentsOf: versionTwoURL))
        let oldCoordinator = NSPersistentStoreCoordinator(managedObjectModel: versionTwoModel)
        let oldStore = try oldCoordinator.addPersistentStore(
            ofType: NSSQLiteStoreType,
            configurationName: nil,
            at: databaseURL,
            options: nil
        )
        try oldCoordinator.remove(oldStore)

        let migratedDatabase = try makeDatabase(kind: .onDisk(databaseFileURL: databaseURL))
        let durabilityStore = E2eeDurableInboxStore(database: migratedDatabase)
        let event = try envelope()
        _ = try durabilityStore.persistPage(
            accountId: accountId,
            scopeCid: scopeCid,
            events: [event],
            hasMore: false,
            nextCursor: ScopeSyncCursorPayload(createdAt: event.createdAtRaw, eventId: event.eventId)
        )
        XCTAssertEqual(
            try durabilityStore.loadPendingEvents(accountId: accountId, scopeCid: scopeCid).map(\.eventId),
            [event.eventId]
        )

        try close([migratedDatabase])
        try FileManager.default.removeItem(at: directory)
    }
}
