import CoreData
import XCTest
@testable import ErmisChat

final class ChannelAvatarPersistenceTests: XCTestCase {
    func testChannelUpdatedPersistsAvatarWithoutChangingEncryptionOrMessageCiphertext() throws {
        for encrypted in [false, true] {
            let database = DatabaseContainer(kind: .inMemory, shouldResetEphemeralValuesOnStart: false)
            let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                !database.persistentStoreCoordinator.persistentStores.isEmpty
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 5), .completed)
            defer {
                for context in database.allContext { context.performAndWait { context.reset() } }
                for store in database.persistentStoreCoordinator.persistentStores {
                    try? database.persistentStoreCoordinator.remove(store)
                }
            }

            let cid = try ChannelId(cid: "team:project:avatar-cache")
            func detail(_ image: String) -> String {
                """
                {"cid":"\(cid.rawValue)","type":"team","name":"QA avatar","image":"\(image)",
                 "created_at":"2026-11-07T00:00:00.000Z","updated_at":"2026-11-07T01:00:00.000Z",
                 "member_count":2,"mls_enabled":\(encrypted),"mls_epoch":7}
                """
            }
            let original = """
            {"channel":\(detail("https://cdn.test/old.png")),"messages":[
                {"id":"kept-message","type":"regular","user":{"id":"sender","project_id":"project"},
                 "text":"","mls_ciphertext":"AQID","mls_epoch":7,"created_at":"2026-11-07T00:30:00.000Z"}
            ],"read":[]}
            """
            let payload = try JSONDecoder.default.decode(ChannelPayload.self, from: Data(original.utf8))
            let eventJSON = """
            {"type":"channel.updated","cid":"\(cid.rawValue)","created_at":"2026-11-07T01:00:00.000Z",
             "channel":\(detail("https://cdn.test/new.png"))}
            """
            let event = try JSONDecoder.default.decode(EventPayload.self, from: Data(eventJSON.utf8))
            try database.writeAndWait { session in
                _ = try session.saveChannel(payload: payload)
                let message = try XCTUnwrap(session.message(id: "kept-message"))
                let originalCiphertext = message.encryptedData
                let originalEpoch = message.mlsEpoch
                try session.saveEvent(payload: event)
                let channel = try XCTUnwrap(session.channel(cid: cid))
                let model = try channel.asModel()
                XCTAssertEqual(model.imageURL?.absoluteString, "https://cdn.test/new.png")
                XCTAssertEqual(model.mlsEnabled, encrypted)
                XCTAssertEqual(message.encryptedData, originalCiphertext)
                XCTAssertEqual(message.mlsEpoch, originalEpoch)
            }
        }
    }
}
