import CoreData
import CryptoKit
import Darwin
import Foundation
import XCTest
import open_mls_ios

@testable import ErmisChat

/// This test is intentionally driven by `scripts/run-m1-e2ee-crash-harness.sh`.
/// Each seed phase durably writes one crash boundary and then SIGKILLs the XCTest runner. A second
/// xcodebuild invocation reopens the same simulator-container files and verifies recovery.
final class E2eeProcessCrashHarnessTests: XCTestCase {
    private enum Mode: String {
        case cleanup
        case tcr005Seed = "tcr005-seed"
        case tcr005Verify = "tcr005-verify"
        case tcr006Seed = "tcr006-seed"
        case tcr006Verify = "tcr006-verify"
        case tcr007Seed = "tcr007-seed"
        case tcr007Verify = "tcr007-verify"
        case tcr008Seed = "tcr008-seed"
        case tcr008Verify = "tcr008-verify"
        case tcr009Seed = "tcr009-seed"
        case tcr009Verify = "tcr009-verify"
        case tcr010Seed = "tcr010-seed"
        case tcr010Verify = "tcr010-verify"
        case tcr011Seed = "tcr011-seed"
        case tcr011Verify = "tcr011-verify"
        case tcr012Seed = "tcr012-seed"
        case tcr012Verify = "tcr012-verify"
    }

    private enum HarnessError: Error {
        case applicationSupportUnavailable
        case invalidMode(String)
        case persistentStoreTimedOut
        case seedMarkerMissing(String)
        case processDidNotTerminate
    }

    private static let modeEnvironmentKey = "ERMIS_E2EE_M1_CRASH_PHASE"
    private static let channelCid = "team:project:m1-process-crash"

    func testProcessCrashBoundary() throws {
        let rawMode = ProcessInfo.processInfo.environment[Self.modeEnvironmentKey]
        guard let rawMode else {
            // Normal SDK suites compile and exercise the harness surface without terminating the
            // runner. Only the dedicated script is authorized to select a destructive seed phase.
            XCTAssertNil(rawMode)
            return
        }
        guard let mode = Mode(rawValue: rawMode) else {
            throw HarnessError.invalidMode(rawMode)
        }

        switch mode {
        case .cleanup:
            try removeHarnessRootIfPresent()
        case .tcr005Seed:
            try seedOutgoingBeforeProviderSave(scenario: "tcr005")
        case .tcr005Verify:
            try verifyOutgoingReplacement(scenario: "tcr005")
        case .tcr006Seed:
            try seedOutgoingAfterProviderSaveBeforeIntent(scenario: "tcr006")
        case .tcr006Verify:
            try verifyOutgoingReplacement(scenario: "tcr006")
        case .tcr007Seed:
            try seedDurableIntent(scenario: "tcr007", messageId: "m1-tcr007", epoch: 17)
        case .tcr007Verify:
            try verifyDurableIntent(scenario: "tcr007", messageId: "m1-tcr007", epoch: 17)
        case .tcr008Seed:
            try seedDurableIntent(scenario: "tcr008", messageId: "m1-tcr008", epoch: 18)
        case .tcr008Verify:
            try verifyDurableIntent(scenario: "tcr008", messageId: "m1-tcr008", epoch: 18)
        case .tcr009Seed:
            try seedIncomingBoundary(scenario: "tcr009", boundary: 0)
        case .tcr009Verify:
            try verifyIncomingBoundary(scenario: "tcr009", boundary: 0)
        case .tcr010Seed:
            try seedIncomingBoundary(scenario: "tcr010", boundary: 1)
        case .tcr010Verify:
            try verifyIncomingBoundary(scenario: "tcr010", boundary: 1)
        case .tcr011Seed:
            try seedIncomingBoundary(scenario: "tcr011", boundary: 2)
        case .tcr011Verify:
            try verifyIncomingBoundary(scenario: "tcr011", boundary: 2)
        case .tcr012Seed:
            try seedIncomingBoundary(scenario: "tcr012", boundary: 3)
        case .tcr012Verify:
            try verifyIncomingBoundary(scenario: "tcr012", boundary: 3)
        }
    }

    private func seedOutgoingBeforeProviderSave(scenario: String) throws {
        let fixture = try createPersistentGroupPair(scenario: scenario)
        let sender = try Group.loadFromStorage(provider: fixture.aliceProvider, cid: Self.channelCid)
        _ = try sender.createMessage(
            provider: fixture.aliceProvider,
            sender: fixture.aliceIdentity,
            plaintext: Data("discarded-before-save".utf8)
        )

        // Intentionally omit Group.saveState: SIGKILL must leave the previous sender generation.
        try persistSeedMarker(scenario: scenario)
        try terminateCurrentProcess()
    }

    private func seedOutgoingAfterProviderSaveBeforeIntent(scenario: String) throws {
        let fixture = try createPersistentGroupPair(scenario: scenario)
        let sender = try Group.loadFromStorage(provider: fixture.aliceProvider, cid: Self.channelCid)
        _ = try sender.createMessage(
            provider: fixture.aliceProvider,
            sender: fixture.aliceIdentity,
            plaintext: Data("discarded-after-save-before-intent".utf8)
        )
        try sender.saveState(provider: fixture.aliceProvider)

        // The sender ratchet is durable, but no MessageDTO network intent is created.
        try persistSeedMarker(scenario: scenario)
        try terminateCurrentProcess()
    }

    private func verifyOutgoingReplacement(scenario: String) throws {
        try requireSeedMarker(scenario: scenario)
        let directory = try scenarioDirectory(scenario)
        let aliceProvider = try Provider.newWithPath(
            dbPath: directory.appendingPathComponent("alice.sqlite").path
        )
        let bobProvider = try Provider.newWithPath(
            dbPath: directory.appendingPathComponent("bob.sqlite").path
        )
        let aliceIdentity = try loadStoredIdentity(provider: aliceProvider)
        let sender = try Group.loadFromStorage(provider: aliceProvider, cid: Self.channelCid)
        let replacementPlaintext = Data("replacement-after-process-relaunch".utf8)
        let replacement = try sender.createMessage(
            provider: aliceProvider,
            sender: aliceIdentity,
            plaintext: replacementPlaintext
        )
        try sender.saveState(provider: aliceProvider)

        let receiver = try Group.loadFromStorage(provider: bobProvider, cid: Self.channelCid)
        let processed = try receiver.processMessage(provider: bobProvider, msg: replacement)
        XCTAssertEqual(processed.content, replacementPlaintext)
        try receiver.saveState(provider: bobProvider)

        let persistedSender = try Group.loadFromStorage(provider: aliceProvider, cid: Self.channelCid)
        let persistedReceiver = try Group.loadFromStorage(provider: bobProvider, cid: Self.channelCid)
        XCTAssertEqual(persistedSender.epoch(), persistedReceiver.epoch())
    }

    private static let receiveAccount = "m1-crash-bob"
    private static let receiveMessage = "m1-receive-proof"
    private static let peerScope = "team:project:m1-crash-peer"

    private func incomingEnvelope(ciphertext: Data, epoch: UInt64) throws -> E2eSyncEventEnvelope {
        let value: [String: Any] = [
            "event_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            "created_at": "2026-10-07T00:00:00.000001Z", "type": "application",
            "data": ["id": Self.receiveMessage, "type": "regular",
                     "mls_ciphertext": ciphertext.base64EncodedString(), "mls_epoch": epoch,
                     "content_type": "text/plain", "created_at": "2026-10-07T00:00:00.000001Z"]
        ]
        return try JSONDecoder.default.decode(E2eSyncEventEnvelope.self,
                                             from: JSONSerialization.data(withJSONObject: value))
    }

    private func seedIncomingBoundary(scenario: String, boundary: Int) throws {
        let fixture = try createPersistentGroupPair(scenario: scenario)
        let directory = try scenarioDirectory(scenario)
        let sender = try Group.loadFromStorage(provider: fixture.aliceProvider, cid: Self.channelCid)
        let payload = E2ePayload(text: "receive-before-crash", attachments: [], stickerUrl: nil)
        let ciphertext = try sender.createMessage(provider: fixture.aliceProvider,
            sender: fixture.aliceIdentity, plaintext: JSONEncoder().encode(payload))
        try sender.saveState(provider: fixture.aliceProvider)
        try ciphertext.write(to: directory.appendingPathComponent("incoming.bin"), options: .atomic)
        let receiverProvider = try Provider.newWithPath(dbPath: directory.appendingPathComponent("bob.sqlite").path)
        let receiver = try Group.loadFromStorage(provider: receiverProvider, cid: Self.channelCid)
        let client = MlsClient()
        client.provider = receiverProvider
        let database = try openDatabase(scenario: scenario)
        let inbox = E2eeDurableInboxStore(database: database)
        let event = try incomingEnvelope(ciphertext: ciphertext, epoch: sender.epoch())
        for scope in [Self.channelCid, Self.peerScope] {
            _ = try inbox.persistPage(accountId: Self.receiveAccount, scopeCid: scope,
                                      events: [event], hasMore: false, nextCursor: nil)
        }
        let processed = try client.processApplicationMessage(data: ciphertext, in: receiver)
        XCTAssertEqual(processed.payload, payload)
        try database.writeAndWait { session in
            _ = try session.saveChannel(payload: try channelPayload(messageId: Self.receiveMessage))
            try session.saveMessageDecrypt(payload: processed.payload, messageId: Self.receiveMessage,
                                           ciphertextHash: Data(SHA256.hash(data: ciphertext)))
        }
        if boundary >= 1 { try client.saveState(of: receiver) }
        if boundary >= 2 {
            try inbox.markApplicationPersistenceCompleted(accountId: Self.receiveAccount,
                scopeCid: Self.channelCid, eventId: event.eventId)
        }
        if boundary >= 3 {
            try inbox.markApplicationDispositionAndApplied(accountId: Self.receiveAccount,
                scopeCid: Self.channelCid, envelope: event, disposition: .decrypted)
        }
        XCTAssertNil(try inbox.applyCursor(accountId: Self.receiveAccount, scopeCid: Self.peerScope))
        let handle = try FileHandle(forWritingTo: {
            let url = directory.appendingPathComponent("seed-pid")
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw ClientError("Could not persist disposable crash process identity")
            }
            return url
        }())
        try handle.write(contentsOf: Data(String(Darwin.getpid()).utf8))
        try handle.synchronize()
        try handle.close()
        try persistSeedMarker(scenario: scenario)
        try terminateCurrentProcess()
    }

    private func verifyIncomingBoundary(scenario: String, boundary: Int) throws {
        try requireSeedMarker(scenario: scenario)
        let directory = try scenarioDirectory(scenario)
        XCTAssertNotEqual(try String(contentsOf: directory.appendingPathComponent("seed-pid"), encoding: .utf8),
                          String(Darwin.getpid()))
        let ciphertext = try Data(contentsOf: directory.appendingPathComponent("incoming.bin"))
        let provider = try Provider.newWithPath(dbPath: directory.appendingPathComponent("bob.sqlite").path)
        let receiver = try Group.loadFromStorage(provider: provider, cid: Self.channelCid)
        let client = MlsClient()
        client.provider = provider
        let database = try openDatabase(scenario: scenario)
        let inbox = E2eeDurableInboxStore(database: database)
        let event = try incomingEnvelope(ciphertext: ciphertext, epoch: receiver.epoch())
        var proofHash: Data?
        try database.writeAndWait { session in
            guard let context = session as? NSManagedObjectContext,
                  let proof = MessageDecryptDTO.load(messageId: Self.receiveMessage, context: context) else {
                throw ClientError("No durable receiver plaintext after process death")
            }
            XCTAssertEqual(proof.text, "receive-before-crash")
            proofHash = proof.ciphertextHash
        }
        XCTAssertEqual(proofHash, Data(SHA256.hash(data: ciphertext)))
        if boundary < 3 {
            XCTAssertNil(try inbox.applyCursor(accountId: Self.receiveAccount, scopeCid: Self.channelCid))
            XCTAssertEqual(try inbox.loadPendingEvents(accountId: Self.receiveAccount, scopeCid: Self.channelCid).count, 1)
        }
        if boundary == 0 {
            XCTAssertEqual(try client.processApplicationMessage(data: ciphertext, in: receiver).payload.text,
                           "receive-before-crash")
        } else {
            XCTAssertThrowsError(try client.processApplicationMessage(data: ciphertext, in: receiver)) { error in
                XCTAssertTrue(E2eeApplicationReplayRecovery.canFinalizeFromCachedPlaintext(
                    error: error, cachedCiphertextHash: proofHash, ciphertext: ciphertext))
                XCTAssertFalse(E2eeApplicationReplayRecovery.canFinalizeFromCachedPlaintext(
                    error: error, cachedCiphertextHash: Data(repeating: 0, count: 32), ciphertext: ciphertext))
            }
        }
        try client.saveState(of: receiver)
        if boundary < 3 {
            try inbox.markApplicationPersistenceCompleted(accountId: Self.receiveAccount,
                scopeCid: Self.channelCid, eventId: event.eventId)
            try inbox.markApplicationDispositionAndApplied(accountId: Self.receiveAccount,
                scopeCid: Self.channelCid, envelope: event, disposition: .decrypted)
        }
        XCTAssertEqual(try inbox.applyCursor(accountId: Self.receiveAccount, scopeCid: Self.channelCid),
                       ScopeSyncCursorPayload(createdAt: event.createdAtRaw, eventId: event.eventId))
        XCTAssertTrue(try inbox.loadPendingEvents(accountId: Self.receiveAccount, scopeCid: Self.channelCid).isEmpty)
        XCTAssertNil(try inbox.applyCursor(accountId: Self.receiveAccount, scopeCid: Self.peerScope))
        XCTAssertEqual(try inbox.loadPendingEvents(accountId: Self.receiveAccount, scopeCid: Self.peerScope).count, 1)
        let senderProvider = try Provider.newWithPath(dbPath: directory.appendingPathComponent("alice.sqlite").path)
        let sender = try Group.loadFromStorage(provider: senderProvider, cid: Self.channelCid)
        let nextPayload = E2ePayload(text: "receive-after-recovery", attachments: [], stickerUrl: nil)
        let next = try sender.createMessage(provider: senderProvider,
            sender: loadStoredIdentity(provider: senderProvider), plaintext: JSONEncoder().encode(nextPayload))
        XCTAssertEqual(try client.processApplicationMessage(data: next, in: receiver).payload, nextPayload)
        try client.saveState(of: receiver)
    }

    private func seedDurableIntent(scenario: String, messageId: String, epoch: Int64) throws {
        let database = try openDatabase(scenario: scenario)
        let ciphertext = deterministicCiphertext(for: scenario)
        try database.writeAndWait { session in
            let channel = try session.saveChannel(payload: try channelPayload(messageId: messageId))
            guard let message = channel.messages.first(where: { $0.id == messageId }) else {
                throw ClientError("Crash harness could not create message \(messageId)")
            }
            message.encryptedData = ciphertext
            message.mlsEpoch = epoch
            message.localMessageState = .sending
        }

        // This represents either immediately-before-POST (TCR-007) or POST-with-unknown-result
        // (TCR-008). Both must recover the exact durable intent without another MLS encryption.
        try persistSeedMarker(scenario: scenario)
        try terminateCurrentProcess()
    }

    private func verifyDurableIntent(scenario: String, messageId: String, epoch: Int64) throws {
        try requireSeedMarker(scenario: scenario)
        let expectedCiphertext = deterministicCiphertext(for: scenario)
        var database: DatabaseContainer? = try openDatabase(scenario: scenario)

        try database?.writeAndWait { session in
            guard let context = session as? NSManagedObjectContext,
                  let message = MessageDTO.load(id: messageId, context: context) else {
                throw ClientError("Crash harness could not reopen message \(messageId)")
            }
            XCTAssertEqual(message.localMessageState, .sending)
            XCTAssertEqual(message.encryptedData, expectedCiphertext)
            XCTAssertEqual(message.mlsEpoch, epoch)

            session.rescueMessagesStuckInSending()
            XCTAssertEqual(message.localMessageState, .pendingSend)
            assertExactIntent(
                message,
                messageId: messageId,
                ciphertext: expectedCiphertext,
                epoch: epoch
            )
        }
        try closeDatabase(&database)

        // Reopen once more to prove the rescue transition itself was committed, not merely visible
        // in the first verification context.
        database = try openDatabase(scenario: scenario)
        try database?.writeAndWait { session in
            guard let context = session as? NSManagedObjectContext,
                  let message = MessageDTO.load(id: messageId, context: context) else {
                throw ClientError("Crash harness lost message \(messageId) after rescue")
            }
            XCTAssertEqual(message.localMessageState, .pendingSend)
            assertExactIntent(
                message,
                messageId: messageId,
                ciphertext: expectedCiphertext,
                epoch: epoch
            )
        }
        try closeDatabase(&database)
    }

    private func assertExactIntent(
        _ message: MessageDTO,
        messageId: String,
        ciphertext: Data,
        epoch: Int64
    ) {
        XCTAssertEqual(message.id, messageId)
        XCTAssertEqual(message.encryptedData, ciphertext)
        XCTAssertEqual(message.mlsEpoch, epoch)
        let request = message.asRequestBody() as MessageRequestBody
        XCTAssertEqual(request.encryptedData, ciphertext.uint8Array)
        XCTAssertEqual(request.mlsEpoch, Int(epoch))
    }

    private func createPersistentGroupPair(
        scenario: String
    ) throws -> (aliceProvider: Provider, aliceIdentity: Identity) {
        let directory = try scenarioDirectory(scenario)
        let aliceProvider = try Provider.newWithPath(
            dbPath: directory.appendingPathComponent("alice.sqlite").path
        )
        let bobProvider = try Provider.newWithPath(
            dbPath: directory.appendingPathComponent("bob.sqlite").path
        )
        let aliceIdentity = try createAndStoreIdentity(
            provider: aliceProvider,
            userId: "m1-crash-alice"
        )
        let bobIdentity = try createAndStoreIdentity(
            provider: bobProvider,
            userId: "m1-crash-bob"
        )
        let aliceGroup = try Group.createWithCid(
            provider: aliceProvider,
            founder: aliceIdentity,
            cid: Self.channelCid
        )
        let bundle = try aliceGroup.addMembers(
            provider: aliceProvider,
            sender: aliceIdentity,
            newMembers: [bobIdentity.keyPackage(provider: bobProvider)]
        )
        try aliceGroup.mergePendingCommit(provider: aliceProvider)
        try aliceGroup.saveState(provider: aliceProvider)
        guard let welcome = bundle.welcome else {
            throw ClientError("Crash harness add-members result has no Welcome")
        }
        let bobGroup = try Group.joinWithWelcome(
            provider: bobProvider,
            welcome: welcome,
            ratchetTree: aliceGroup.exportRatchetTree()
        )
        try bobGroup.saveState(provider: bobProvider)
        return (aliceProvider, aliceIdentity)
    }

    private func createAndStoreIdentity(provider: Provider, userId: String) throws -> Identity {
        let identity = try Identity(provider: provider, userId: userId)
        try provider.storeIdentity(userId: userId, identityBytes: identity.toBytes())
        return identity
    }

    private func loadStoredIdentity(provider: Provider) throws -> Identity {
        guard let bytes = try provider.loadIdentity() else {
            throw ClientError("Crash harness provider has no durable identity")
        }
        return try Identity.fromBytes(provider: provider, data: bytes)
    }

    private func openDatabase(scenario: String) throws -> DatabaseContainer {
        let databaseURL = try scenarioDirectory(scenario).appendingPathComponent("chat.sqlite")
        let database = DatabaseContainer(
            kind: .onDisk(databaseFileURL: databaseURL),
            shouldResetEphemeralValuesOnStart: false
        )
        let loaded = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                !database.persistentStoreCoordinator.persistentStores.isEmpty
            },
            object: nil
        )
        guard XCTWaiter.wait(for: [loaded], timeout: 10) == .completed else {
            throw HarnessError.persistentStoreTimedOut
        }
        return database
    }

    private func closeDatabase(_ database: inout DatabaseContainer?) throws {
        guard let activeDatabase = database else { return }
        for context in activeDatabase.allContext {
            context.performAndWait { context.reset() }
        }
        for store in activeDatabase.persistentStoreCoordinator.persistentStores {
            try activeDatabase.persistentStoreCoordinator.remove(store)
        }
        database = nil
    }

    private func channelPayload(messageId: String) throws -> ChannelPayload {
        let json = """
        {
          "channel": {
            "cid": "\(Self.channelCid)",
            "type": "team",
            "save_message": true,
            "last_message_at": "2026-08-08T01:00:00.000Z",
            "created_at": "2026-08-08T01:00:00.000Z",
            "updated_at": "2026-08-08T01:00:00.000Z",
            "member_count": 2,
            "mls_enabled": true
          },
          "messages": [{
            "id": "\(messageId)",
            "type": "regular",
            "user": {"id": "m1-crash-alice", "project_id": "project"},
            "text": "durable plaintext",
            "mls_ciphertext": "AQID",
            "mls_epoch": 1,
            "created_at": "2026-08-08T01:00:00.000Z",
            "updated_at": "2026-08-08T01:00:00.000Z"
          }],
          "read": []
        }
        """
        return try JSONDecoder.default.decode(ChannelPayload.self, from: Data(json.utf8))
    }

    private func deterministicCiphertext(for scenario: String) -> Data {
        Data("exact-intent-\(scenario)".utf8)
    }

    private func harnessRoot() throws -> URL {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw HarnessError.applicationSupportUnavailable
        }
        return applicationSupport.appendingPathComponent("ErmisM1CrashHarness", isDirectory: true)
    }

    private func scenarioDirectory(_ scenario: String) throws -> URL {
        let directory = try harnessRoot().appendingPathComponent(scenario, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func persistSeedMarker(scenario: String) throws {
        let marker = try scenarioDirectory(scenario).appendingPathComponent("seed-complete")
        guard FileManager.default.createFile(atPath: marker.path, contents: nil) else {
            throw ClientError("Crash harness could not create seed marker")
        }
        let handle = try FileHandle(forWritingTo: marker)
        try handle.write(contentsOf: Data(scenario.utf8))
        try handle.synchronize()
        try handle.close()
    }

    private func requireSeedMarker(scenario: String) throws {
        let marker = try scenarioDirectory(scenario).appendingPathComponent("seed-complete")
        guard FileManager.default.fileExists(atPath: marker.path) else {
            throw HarnessError.seedMarkerMissing(scenario)
        }
    }

    private func removeHarnessRootIfPresent() throws {
        let root = try harnessRoot()
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        try FileManager.default.removeItem(at: root)
    }

    private func terminateCurrentProcess() throws {
        _ = Darwin.kill(Darwin.getpid(), SIGKILL)
        throw HarnessError.processDidNotTerminate
    }
}
