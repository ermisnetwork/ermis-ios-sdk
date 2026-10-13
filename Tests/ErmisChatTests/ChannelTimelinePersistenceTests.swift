import CoreData
import XCTest
@testable import ErmisChat
@testable import ErmisChatUI

final class ChannelTimelinePersistenceTests: XCTestCase {
    private let parentCid = "team:project:timeline-parent"
    private let topicCid = "topic:project:timeline-topic"
    private let otherCid = "team:project:timeline-other"

    private func database() throws -> DatabaseContainer {
        let database = DatabaseContainer(kind: .inMemory, shouldResetEphemeralValuesOnStart: false)
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !database.persistentStoreCoordinator.persistentStores.isEmpty
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 5), .completed)
        return database
    }

    private func close(_ database: DatabaseContainer) {
        for context in database.allContext { context.performAndWait { context.reset() } }
        for store in database.persistentStoreCoordinator.persistentStores {
            try? database.persistentStoreCoordinator.remove(store)
        }
    }

    private func date(_ hour: Int) -> Date {
        ISO8601DateFormatter().date(from: "2026-10-13T\(String(format: "%02d", hour)):00:00Z")!
    }

    private func message(_ id: String, hour: Int, editedHour: Int? = nil) -> String {
        let at = "2026-10-13T\(String(format: "%02d", hour)):00:00Z"
        let updatedAt = "2026-10-13T\(String(format: "%02d", editedHour ?? hour)):00:00Z"
        return """
        {"id":"\(id)","type":"regular","user":{"id":"sender","project_id":"project"},"text":"\(id)","created_at":"\(at)","updated_at":"\(updatedAt)"}
        """
    }

    private func channel(_ cid: String, hour: Int, messages: [String], parent: String? = nil) throws -> ChannelPayload {
        let parentField = parent.map { ",\"parent_cid\":\"\($0)\"" } ?? ""
        let type = cid.hasPrefix("topic:") ? "topic" : "team"
        let json = """
        {"channel":{"cid":"\(cid)","type":"\(type)","save_message":true,"topics_enabled":true,"mls_enabled":false,"member_count":2,"created_at":"2026-10-13T01:00:00Z","updated_at":"2026-10-13T23:00:00Z","last_message_at":"2026-10-13T\(String(format: "%02d", hour)):00:00Z"\(parentField)},"messages":[\(messages.joined(separator: ","))],"read":[]}
        """
        return try JSONDecoder.default.decode(ChannelPayload.self, from: Data(json.utf8))
    }

    private func event(_ type: String, cid: String, message: String) throws -> EventPayload {
        let json = """
        {"type":"\(type)","cid":"\(cid)","created_at":"2026-10-13T20:00:00Z","message":\(message)}
        """
        return try JSONDecoder.default.decode(EventPayload.self, from: Data(json.utf8))
    }

    private func seed(_ database: DatabaseContainer) throws {
        try database.writeAndWait { session in
            try session.saveChannel(payload: channel(parentCid, hour: 8, messages: [message("general", hour: 8)]))
            try session.saveChannel(payload: channel(otherCid, hour: 10, messages: [message("other", hour: 10)]))
            try session.saveChannel(payload: channel(topicCid, hour: 9, messages: [message("topic-old", hour: 9)], parent: parentCid))
        }
    }

    private func assertTimeline(_ database: DatabaseContainer, parentHour: Int, firstCid: String) throws {
        try database.viewContext.performAndWait {
            let parent = try XCTUnwrap(ChannelDTO.load(cid: try ChannelId(cid: parentCid), context: database.viewContext))
            XCTAssertEqual(parent.defaultSortingAt.bridgeDate, date(parentHour))
            let request = ChannelDTO.allChannelsFetchRequest
            request.predicate = NSPredicate(format: "parentcid == nil")
            request.sortDescriptors = [ChannelListSortingKey.defaultSortDescriptor]
            XCTAssertEqual(try database.viewContext.fetch(request).first?.cid, firstCid)
        }
    }

    func testRealtimeTopicMessageMovesParentAndUsesSamePreviewForTimestamp() throws {
        let database = try database()
        defer { close(database) }
        try seed(database)
        try assertTimeline(database, parentHour: 9, firstCid: otherCid)
        try database.writeAndWait { session in
            try session.saveEvent(payload: event("message.new", cid: topicCid, message: message("topic-new", hour: 12)))
        }
        try assertTimeline(database, parentHour: 12, firstCid: parentCid)
        try database.viewContext.performAndWait {
            let parent = try XCTUnwrap(ChannelDTO.load(cid: try ChannelId(cid: parentCid), context: database.viewContext)).asModel()
            XCTAssertEqual(parent.topicsPreviewMessage?.id, "topic-new")
            let view = ChannelListItemView()
            view.content = .init(channel: parent, currentUserId: nil)
            XCTAssertEqual(view.timestampText, view.timestampFormatter.format(date(12)))
        }
    }

    func testOlderReplayAndEditDoNotPromoteConversation() throws {
        let database = try database()
        defer { close(database) }
        try seed(database)
        try database.writeAndWait { session in
            try session.saveEvent(payload: event("message.new", cid: topicCid, message: message("topic-replayed", hour: 7)))
            try session.saveEvent(payload: event("message.updated", cid: topicCid, message: message("topic-old", hour: 9, editedHour: 20)))
        }
        try assertTimeline(database, parentHour: 9, firstCid: otherCid)
    }

    func testDeletingLatestTopicMessageMovesParentBackToRemainingHistory() throws {
        let database = try database()
        defer { close(database) }
        try seed(database)
        try database.writeAndWait { session in
            try session.saveEvent(payload: event("message.new", cid: topicCid, message: message("topic-new", hour: 12)))
        }
        try assertTimeline(database, parentHour: 12, firstCid: parentCid)
        try database.writeAndWait { session in
            try session.saveEvent(payload: event("message.deleted", cid: topicCid, message: message("topic-new", hour: 12)))
        }
        try database.viewContext.performAndWait {
            let topic = try XCTUnwrap(ChannelDTO.load(cid: try ChannelId(cid: topicCid), context: database.viewContext))
            XCTAssertEqual(topic.previewMessage?.id, "topic-old")
            XCTAssertEqual(topic.lastMessageAt?.bridgeDate, date(9))
            XCTAssertEqual(topic.defaultSortingAt.bridgeDate, date(9))
        }
        try assertTimeline(database, parentHour: 9, firstCid: otherCid)
    }
}
