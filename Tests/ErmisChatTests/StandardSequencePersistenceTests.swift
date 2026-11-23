import CoreData
import XCTest
@testable import ErmisChat

final class StandardSequencePersistenceTests: XCTestCase {
    private let cid = "team:project:standard-sequence"
    private func close(_ database: DatabaseContainer) throws {
        database.allContext.forEach { context in context.performAndWait { context.reset() } }
        for store in database.persistentStoreCoordinator.persistentStores { try database.persistentStoreCoordinator.remove(store) }
    }
    private func database(_ url: URL) throws -> DatabaseContainer {
        let db = DatabaseContainer(kind: .onDisk(databaseFileURL: url), shouldResetEphemeralValuesOnStart: false)
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !db.persistentStoreCoordinator.persistentStores.isEmpty }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 5), .completed)
        XCTAssertEqual(db.persistentStoreCoordinator.persistentStores.first?.url, url, "Migration must retain the disk store")
        return db
    }
    private func payload(_ text: String, seq: UInt64? = nil) throws -> ChannelPayload {
        let sequence = seq.map { ",\"last_event_seq\":\($0)" } ?? ""
        let json = """
        {"channel":{"cid":"\(cid)","type":"team","save_message":true,"created_at":"2026-11-17T00:00:00Z","updated_at":"2026-11-17T00:00:00Z","mls_enabled":false},
        "messages":[{"id":"sequence-message","type":"regular","user":{"id":"sender","project_id":"project"},"text":"\(text)","created_at":"2026-11-17T00:00:00Z","updated_at":"2026-11-17T00:00:00Z"\(sequence)}],"read":[]}
        """
        return try JSONDecoder.default.decode(ChannelPayload.self, from: Data(json.utf8))
    }
    func testModel7HistoryMigratesAndNewerRealtimeSequenceSurvivesOlderPageAndReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("standard.sqlite"), cached = DatabaseContainer.cachedModel
        defer { DatabaseContainer.cachedModel = cached }
        let models = try XCTUnwrap(Bundle.ermisChat.url(forResource: "ErmisChatModel", withExtension: "momd"))
        DatabaseContainer.cachedModel = try XCTUnwrap(NSManagedObjectModel(contentsOf: models.appendingPathComponent("ErmisChatModel 7.mom")))
        let old = try database(url), legacy = try payload("legacy")
        try old.writeAndWait { session in try session.saveChannel(payload: legacy) }
        try close(old)
        DatabaseContainer.cachedModel = nil
        let migrated = try database(url)
        let high: UInt64 = 9_007_199_254_740_993
        let latest = try payload("realtime", seq: high), stale = try payload("stale-page", seq: high - 1)
        try migrated.writeAndWait { session in
            XCTAssertEqual(session.message(id: "sequence-message")?.text, "legacy")
            try session.saveChannel(payload: latest); try session.saveChannel(payload: stale)
            XCTAssertEqual(session.message(id: "sequence-message")?.text, "realtime")
            XCTAssertEqual(session.message(id: "sequence-message")?.standardEventSequence, String(high))
        }
        try close(migrated)
        let reopened = try database(url); defer { try? close(reopened) }
        try reopened.writeAndWait { session in
            XCTAssertEqual(session.message(id: "sequence-message")?.text, "realtime")
            XCTAssertEqual(session.message(id: "sequence-message")?.standardEventSequence, String(high))
        }
    }
    func testFailedStoreLoadPreservesOriginalBytesInsteadOfDestroyingHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("preserve.sqlite"), original = Data("fixture invalid SQLite file - preserve for recovery".utf8)
        try original.write(to: url)
        let db = DatabaseContainer(kind: .onDisk(databaseFileURL: url), shouldResetEphemeralValuesOnStart: false)
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !db.persistentStoreCoordinator.persistentStores.isEmpty }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 5), .completed)
        defer { try? close(db) }
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertNotEqual(db.persistentStoreCoordinator.persistentStores.first?.url, url)
    }
}
