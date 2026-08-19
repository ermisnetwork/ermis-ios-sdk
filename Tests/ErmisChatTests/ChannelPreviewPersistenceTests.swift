import CoreData
import XCTest
@testable import ErmisChat

final class ChannelPreviewPersistenceTests: XCTestCase {
    private let cid = "team:project:timeline-preview"

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

    private func messageJSON(
        id: String,
        text: String,
        createdAt: String,
        type: String = "regular"
    ) -> String {
        """
        {
          "id": "\(id)",
          "type": "\(type)",
          "user": {"id": "sender", "project_id": "project"},
          "text": "\(text)",
          "created_at": "\(createdAt)",
          "updated_at": "\(createdAt)"
        }
        """
    }

    private func channelPayload(messages: [String], lastMessageAt: String) throws -> ChannelPayload {
        let json = """
        {
          "channel": {
            "cid": "\(cid)",
            "type": "team",
            "save_message": true,
            "last_message_at": "\(lastMessageAt)",
            "created_at": "2026-08-07T01:00:00.000Z",
            "updated_at": "\(lastMessageAt)",
            "member_count": 2,
            "mls_enabled": true
          },
          "messages": [\(messages.joined(separator: ","))],
          "read": []
        }
        """
        return try JSONDecoder.default.decode(ChannelPayload.self, from: Data(json.utf8))
    }

    @discardableResult
    private func save(_ payload: ChannelPayload, in database: DatabaseContainer) throws -> String? {
        var previewId: String?
        try database.writeAndWait { session in
            previewId = try session.saveChannel(payload: payload).previewMessage?.id
        }
        return previewId
    }

    func testChannelBatchPromotesNewlyInsertedLatestMessageBeforeWillSave() throws {
        let database = try makeDatabase()
        defer { try? close(database) }

        let oldMessage = messageJSON(
            id: "message-old",
            text: "old",
            createdAt: "2026-08-07T02:00:00.000Z"
        )
        XCTAssertEqual(
            try save(
                channelPayload(
                    messages: [oldMessage],
                    lastMessageAt: "2026-08-07T02:00:00.000Z"
                ),
                in: database
            ),
            "message-old"
        )

        let middleMessage = messageJSON(
            id: "message-middle",
            text: "middle",
            createdAt: "2026-08-07T02:01:00.000Z"
        )
        let latestMessage = messageJSON(
            id: "message-latest",
            text: "latest",
            createdAt: "2026-08-07T02:02:00.000Z"
        )

        XCTAssertEqual(
            try save(
                channelPayload(
                    messages: [oldMessage, middleMessage, latestMessage],
                    lastMessageAt: "2026-08-07T02:02:00.000Z"
                ),
                in: database
            ),
            "message-latest"
        )
    }

    func testEqualTimestampUsesLastAuthoritativePayloadMessage() throws {
        let database = try makeDatabase()
        defer { try? close(database) }

        let first = messageJSON(
            id: "message-first",
            text: "first",
            createdAt: "2026-08-07T02:03:00.000Z"
        )
        let authoritativeLast = messageJSON(
            id: "message-authoritative-last",
            text: "last",
            createdAt: "2026-08-07T02:03:00.000Z"
        )

        XCTAssertEqual(
            try save(
                channelPayload(
                    messages: [first, authoritativeLast],
                    lastMessageAt: "2026-08-07T02:03:00.000Z"
                ),
                in: database
            ),
            "message-authoritative-last"
        )
    }

    func testInvalidNewestPayloadDoesNotBecomeChannelPreview() throws {
        let database = try makeDatabase()
        defer { try? close(database) }

        let regular = messageJSON(
            id: "message-regular",
            text: "visible",
            createdAt: "2026-08-07T02:04:00.000Z"
        )
        let ephemeral = messageJSON(
            id: "message-ephemeral",
            text: "hidden from preview",
            createdAt: "2026-08-07T02:05:00.000Z",
            type: "ephemeral"
        )

        XCTAssertEqual(
            try save(
                channelPayload(
                    messages: [regular, ephemeral],
                    lastMessageAt: "2026-08-07T02:05:00.000Z"
                ),
                in: database
            ),
            "message-regular"
        )
    }
}
