import XCTest
import CoreData
import CryptoKit
import open_mls_ios
@testable import ErmisChat

/// Uses actual repository/Core Data/native sealing. The seam returns transport outcomes only;
/// there is no fake login, JWT or backend acceptance claim.
final class MessageRepositoryAtomicTransportTests: XCTestCase {
    private final class SecureStore: MlsDeviceIdSecureStoring {
        var values: [String: String] = [:]
        func load(userId: String) throws -> String? { values[userId] }
        func save(deviceId: String, userId: String) throws { values[userId] = deviceId }
        func remove(userId: String) throws { values.removeValue(forKey: userId) }
    }
    private final class TransportAPI: APIClient {
        var transport: ((String, Data) throws -> Data)?
        private let heldLock = NSLock()
        private var holdingReconciliation = false
        private var heldReconciliations: [() -> Void] = []
        var holdReconciliation: Bool {
            get { heldLock.lock(); defer { heldLock.unlock() }; return holdingReconciliation }
            set { heldLock.lock(); holdingReconciliation = newValue; heldLock.unlock() }
        }
        var heldReconciliationCount: Int {
            heldLock.lock(); defer { heldLock.unlock() }; return heldReconciliations.count
        }
        func releaseReconciliations() {
            heldLock.lock()
            holdingReconciliation = false
            let callbacks = heldReconciliations
            heldReconciliations.removeAll()
            heldLock.unlock()
            callbacks.forEach { $0() }
        }
        override func request<Response: Decodable>(endpoint: Endpoint<Response>, completion: @escaping (Result<Response, Error>) -> Void) {
            let invoke = { [self] in
                do {
                    try endpoint.localMlsGuard?()
                    guard let body = endpoint.body as? Data else { throw MlsSendIntentError.invalid }
                    let response = try XCTUnwrap(transport)(endpoint.path.value, body)
                    completion(.success(try JSONDecoder.ermis.decode(Response.self, from: response)))
                } catch { completion(.failure(error)) }
            }
            heldLock.lock()
            if holdingReconciliation && endpoint.path.value.hasSuffix("/message/reconcile") {
                heldReconciliations.append(invoke)
                heldLock.unlock()
            } else { heldLock.unlock(); invoke() }
        }
    }
    private final class CancelBeforePrepareRepository: E2eRepository {
        var beforePrepare: (() throws -> Void)?
        var beforeAccept: (() -> Void)?
        override func acceptOutgoingSend(_ original: MlsSendIntent) throws {
            beforeAccept?()
            try super.acceptOutgoingSend(original)
        }
        override func prepareOutgoingSend(_ request: MessageRequestBody, payload: E2ePayload, cid: ChannelId) throws -> MlsSendIntent {
            try beforePrepare?()
            return try super.prepareOutgoingSend(request, payload: payload, cid: cid)
        }
    }
    func testCancelBeforeIntentPersistenceRetiresLateNativeSealWithoutDispatch() throws {
        try scenario(cancelAfterDispatch: false, cancelBeforeIntent: true)
    }
    func testLostAckUsesReconcileExactEnvelopeAndPublishesOnce() throws { try scenario(cancelAfterDispatch: false) }
    func testDirectCanonicalAcceptanceReleasesWriterBeforeMlsInboxRead() throws {
        try scenario(cancelAfterDispatch: false, directAcceptance: true)
    }
    func testCancelAfterDispatchKeepsReconcileObligationAndLateCanonicalTruth() throws { try scenario(cancelAfterDispatch: true) }
    func testLostAckReconcilesAutomaticallyWithoutRetryOrLifecycleWake() throws {
        try scenario(cancelAfterDispatch: false, automaticReconcile: true)
    }
    func testWakeArrivingDuringReconcileIsCoalescedAfterUnknownOutcome() throws {
        try scenario(cancelAfterDispatch: false, coalescedWake: true)
    }
    func testAuthenticatedCaptionEditKeepsManifestAndReconcilesLostResponse() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("caption-edit-" + UUID().uuidString)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "caption-edit-" + UUID().uuidString))
        let devices = MlsDeviceIdStore(defaults: defaults, legacyDefaults: defaults, secureStore: SecureStore())
        let client = MlsClient(storageFolderURL: root, deviceIdStore: devices, userDefaults: defaults, importLegacyStorage: false)
        try client.setup(with: "native-sender")
        let cid = try ChannelId(cid: "team:project:caption-transport")
        let native = try XCTUnwrap(client.provider), signer = try XCTUnwrap(client.identity)
        let group = try Group.createWithCid(provider: native, founder: signer, cid: cid.rawValue)
        let peerProvider = Provider(), peer = try Identity(provider: peerProvider, userId: "caption-peer")
        let join = try group.addMembers(provider: native, sender: signer, newMembers: [peer.keyPackage(provider: peerProvider)])
        try group.mergePendingCommit(provider: native); try group.saveState(provider: native)
        let peerGroup = try Group.joinWithWelcome(provider: peerProvider, welcome: XCTUnwrap(join.welcome), ratchetTree: group.exportRatchetTree())
        let database = DatabaseContainer(kind: .inMemory, shouldResetEphemeralValuesOnStart: false)
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !database.persistentStoreCoordinator.persistentStores.isEmpty }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 5), .completed)
        let now = Date()
        let account = CurrentUserPayload(id: "native-sender", projectId: "project", name: "Fixture", imageURL: nil,
            phone: nil, email: nil, role: .user, createdAt: now, updatedAt: now, deactivatedAt: nil,
            lastActiveAt: now, isOnline: false, isInvisible: false, isBanned: false, isBlocked: false,
            language: nil, isEmailVerified: true, bellBoyId: "", aboutMe: "")
        let id = UUID().uuidString.lowercased(), attachmentId = UUID().uuidString.lowercased()
        let manifest = E2eeAttachmentManifestV1(attachmentId: attachmentId, assets: [
            E2eeAttachmentManifestAssetV1(assetId: UUID().uuidString.lowercased(), kind: .original,
                cipherSize: 24, cipherSha256: String(repeating: "b", count: 64), frameSize: 262144,
                contentKey: Data(repeating: 7, count: 32).base64EncodedString(),
                noncePrefix: Data(repeating: 9, count: 8).base64EncodedString(), plaintextSize: 0,
                plaintextSha256: SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined(),
                display: ["name": "qaatt-fixture.txt", "mime_type": "text/plain", "size": 0])])
        var canonical: [String: Any] = ["id": id, "cid": cid.rawValue, "type": "regular",
            "user": ["id": "native-sender", "project_id": "project"], "text": "", "mls_ciphertext": "AQID",
            "mls_epoch": 1, "group_generation": 0, "e2ee_group_id": cid.rawValue, "e2ee_attachment_ids": [attachmentId],
            "msg_seq": 7, "last_event_seq": 10, "device_id": try XCTUnwrap(client.currentDeviceId),
            "created_at": "2026-11-07T03:30:21.905Z", "updated_at": "2026-11-07T03:30:21.905Z"]
        let channel: [String: Any] = ["cid": cid.rawValue, "type": "team", "mls_enabled": true,
            "created_at": "2026-11-07T00:00:00Z", "updated_at": "2026-11-07T03:30:21.905Z", "member_count": 2]
        try database.writeAndWait { session in
            try session.saveCurrentUser(payload: account, projectId: "project")
            let channelPayload = try JSONDecoder.ermis.decode(ChannelPayload.self,
                from: JSONSerialization.data(withJSONObject: ["channel": channel, "messages": [canonical], "read": []]))
            try session.saveChannel(payload: channelPayload)
            try session.saveMessageDecrypt(payload: E2ePayload(text: "QAATT-caption-original", attachments: [],
                e2eeAttachments: [manifest], stickerUrl: nil,
                authenticatedMetadata: .init(forwardCid: nil, forwardMessageId: nil, forwardParentCid: nil, attachmentIds: [attachmentId])),
                messageId: id, ciphertextHash: Data(SHA256.hash(data: Data([1, 2, 3]))))
        }
        let url = try XCTUnwrap(URL(string: "https://caption-fixture.invalid"))
        let encoder = DefaultRequestEncoder(baseURL: url, authURL: url, stickerURL: url, apiKey: APIKey("fixture"))
        let decoder = DefaultRequestDecoder(), config = URLSessionConfiguration.ephemeral
        let api = TransportAPI(sessionConfiguration: config, requestEncoder: encoder, requestDecoder: decoder,
            uploader: ErmisUploader(uploadClient: ErmisUploadClient(encoder: encoder, decoder: decoder, sessionConfiguration: config)),
            downloader: ErmisDownloader(client: ErmisDownloadClient(sessionConfiguration: config)))
        let e2e = E2eRepository(database: database, eventNotificationCenter: EventNotificationCenter(database: database), mlsClient: client, apiClient: api)
        let repository = MessageRepository(database: database, apiClient: api, e2eRepository: e2e)
        let updater = MessageUpdater(isLocalStorageEnabled: true, messageRepository: repository,
            paginationStateHandler: MessagesPaginationStateHandler(), database: database, apiClient: api)
        var editPosts = 0, queries = 0, sentCiphertexts: [Data] = [], editVersions: [[String: Any]] = []
        api.transport = { path, body in
            if path.hasSuffix("/query") {
                queries += 1
                return try JSONSerialization.data(withJSONObject: ["channel": channel, "messages": [canonical], "read": []])
            }
            XCTAssertTrue(path.hasSuffix("/" + id))
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            var wire = try XCTUnwrap(root["message"] as? [String: Any])
            XCTAssertNil(wire["old_texts"]); XCTAssertNil(wire["text"]); XCTAssertNil(wire["attachments"])
            XCTAssertEqual(wire["id"] as? String, id)
            XCTAssertEqual(wire["e2ee_attachment_ids"] as? [String], [attachmentId])
            let cipher = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(wire["mls_ciphertext"] as? String)))
            let processed = try peerGroup.processMessageDeferred(provider: peerProvider, msg: cipher)
            let plain = try E2eeArchiveMessageValidator.validate(
                JSONDecoder().decode(E2ePayload.self, from: XCTUnwrap(processed.content)),
                processedAAD: processed.aad, messageId: id, cid: cid.rawValue, groupCid: cid.rawValue)
            XCTAssertEqual(plain.e2eeAttachments, [manifest]); XCTAssertEqual(plain.oldTexts?.count, editPosts + 1)
            XCTAssertEqual(plain.oldTexts?.first?.text, "QAATT-caption-original")
            sentCiphertexts.append(cipher); editPosts += 1
            wire["created_at"] = canonical["created_at"]; wire["updated_at"] = "2026-11-07T03:31:21.957Z"
            wire["msg_seq"] = 7; wire["last_event_seq"] = 10 + editPosts
            wire["user"] = canonical["user"]; wire["device_id"] = client.currentDeviceId
            canonical = wire
            editVersions.append(wire)
            if editPosts == 1 { throw URLError(.timedOut) }
            return try JSONSerialization.data(withJSONObject: ["message": canonical])
        }
        func stage(_ text: String) throws -> E2eeCaptionEditSnapshot {
            let staged = expectation(description: "caption intent staged")
            updater.editMessage(messageId: id, text: text) { error in XCTAssertNil(error); staged.fulfill() }
            wait(for: [staged], timeout: 5)
            var result: E2eeCaptionEditSnapshot?
            try database.writeAndWait { session in result = try E2eeCaptionEditSnapshot.decode(XCTUnwrap(session.message(id: id)?.e2eeCaptionEditData)) }
            return try XCTUnwrap(result)
        }
        let first = try stage("QAATT-caption-one")
        let lost = expectation(description: "lost response remains unresolved")
        repository.editCaptionMessage(with: id) { result in
            if case .success = result { XCTFail("Timeout cannot imply acceptance") }; lost.fulfill()
        }
        wait(for: [lost], timeout: 10)
        XCTAssertEqual(editPosts, 1)
        let conflict = expectation(description: "unresolved competing edit rejected")
        updater.editMessage(messageId: id, text: "QAATT-caption-competing") { error in XCTAssertNotNil(error); conflict.fulfill() }
        wait(for: [conflict], timeout: 5)
        let recovered = expectation(description: "canonical reconciliation after reopen boundary")
        repository.editCaptionMessage(with: id) { result in
            if case .failure(let error) = result { XCTFail("Canonical edit reconciliation failed: \(error)") }
            recovered.fulfill()
        }
        wait(for: [recovered], timeout: 10)
        XCTAssertEqual(editPosts, 1); XCTAssertEqual(queries, 1)
        try database.writeAndWait { session in
            let dto = try XCTUnwrap(session.message(id: id)); XCTAssertNil(dto.e2eeCaptionEditData); XCTAssertNil(dto.localMessageState)
            XCTAssertEqual(try dto.decryptedMessage?.asPayload().e2eeAttachments, [manifest])
            XCTAssertEqual(try dto.asModel().oldTexts?.count, 1)
        }
        let second = try stage("QAATT-caption-two")
        XCTAssertNotEqual(first.operationId, second.operationId); XCTAssertEqual(first.messageId, second.messageId)
        let final = expectation(description: "second caption version accepted")
        repository.editCaptionMessage(with: id) { result in
            if case .failure(let error) = result { XCTFail("Second caption edit failed: \(error)") }
            final.fulfill()
        }
        wait(for: [final], timeout: 10)
        XCTAssertEqual(editPosts, 2); XCTAssertNotEqual(sentCiphertexts.first, sentCiphertexts.last)
        let accepted = try e2e.prepareOutgoingCaptionEdit(second)
        XCTAssertEqual(accepted.phase, .accepted); XCTAssertTrue(accepted.nativeRetired)
        try database.writeAndWait { session in
            let dto = try XCTUnwrap(session.message(id: id)); let payload = try XCTUnwrap(dto.decryptedMessage?.asPayload())
            XCTAssertEqual(payload.text, "QAATT-caption-two"); XCTAssertEqual(payload.oldTexts?.map(\.text), ["QAATT-caption-original", "QAATT-caption-one"])
            XCTAssertEqual(payload.e2eeAttachments, [manifest]); XCTAssertNil(dto.localMessageState)
        }
        // Ordered scope replay may encounter earlier own-device accepted edits after the
        // timeline already holds the latest ciphertext. Recover from accepted exact intents,
        // then apply the later version, without consuming our own sender ratchet.
        for version in editVersions {
            let wire: [String: Any] = ["message": version, "sender": canonical["user"] as Any,
                "created_at": "2026-11-07T03:32:21.957Z"]
            let update = try JSONDecoder.ermis.decode(MessageUpdatedSyncData.self,
                from: JSONSerialization.data(withJSONObject: wire))
            try e2e.handleMessageUpdatedSyncEvent(update, cid: cid)
            try database.writeAndWait { session in
                let row = try XCTUnwrap(session.message(id: id))
                XCTAssertEqual(row.encryptedData, Data(base64Encoded: try XCTUnwrap(version["mls_ciphertext"] as? String)))
                XCTAssertNotNil(try row.asModel().decryptedMessage)
            }
        }
        XCTAssertEqual(editPosts, 2, "Replay must never POST another edit")
    }

    private func scenario(cancelAfterDispatch: Bool, cancelBeforeIntent: Bool = false,
                          automaticReconcile: Bool = false, coalescedWake: Bool = false,
                          directAcceptance: Bool = false) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("message-repository-" + UUID().uuidString)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "message-repository-" + UUID().uuidString))
        let devices = MlsDeviceIdStore(defaults: defaults, legacyDefaults: defaults, secureStore: SecureStore())
        let client = MlsClient(storageFolderURL: root, deviceIdStore: devices, userDefaults: defaults, importLegacyStorage: false)
        try client.setup(with: "native-sender")
        let cid = try ChannelId(cid: "team:project:repository-transport")
        let native = try XCTUnwrap(client.provider), signer = try XCTUnwrap(client.identity)
        let group = try Group.createWithCid(provider: native, founder: signer, cid: cid.rawValue)
        try group.saveState(provider: native)
        let database = DatabaseContainer(kind: .inMemory, shouldResetEphemeralValuesOnStart: false)
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !database.persistentStoreCoordinator.persistentStores.isEmpty }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 5), .completed)
        let now = Date()
        let account = CurrentUserPayload(id: "native-sender", projectId: "project", name: "Fixture", imageURL: nil,
            phone: nil, email: nil, role: .user, createdAt: now, updatedAt: now, deactivatedAt: nil,
            lastActiveAt: now, isOnline: false, isInvisible: false, isBanned: false, isBlocked: false,
            language: nil, isEmailVerified: true, bellBoyId: "", aboutMe: "")
        let channel = try JSONDecoder.ermis.decode(ChannelPayload.self, from: Data("""
        {"channel":{"cid":"\(cid.rawValue)","type":"team","name":"Fixture","mls_enabled":true,
        "created_at":"2026-11-02T00:00:00Z","updated_at":"2026-11-02T00:00:00Z","member_count":1},"messages":[],"read":[]}
        """.utf8))
        let uuid = UUID().uuidString.lowercased()
        try database.writeAndWait { session in
            try session.saveCurrentUser(payload: account, projectId: "project")
            try session.saveChannel(payload: channel)
            let dto = try session.createNewMessage(in: cid, messageId: uuid, text: "QA-exact-lost-ack", quotedMessageId: nil)
            dto.localMessageState = .pendingSend
        }
        let url = URL(string: "https://transport-fixture.invalid")!
        let encoder = DefaultRequestEncoder(baseURL: url, authURL: url, stickerURL: url, apiKey: APIKey("fixture"))
        let decoder = DefaultRequestDecoder(), config = URLSessionConfiguration.ephemeral
        let api = TransportAPI(sessionConfiguration: config, requestEncoder: encoder, requestDecoder: decoder,
            uploader: ErmisUploader(uploadClient: ErmisUploadClient(encoder: encoder, decoder: decoder, sessionConfiguration: config)),
            downloader: ErmisDownloader(client: ErmisDownloadClient(sessionConfiguration: config)))
        let e2e = CancelBeforePrepareRepository(database: database, eventNotificationCenter: EventNotificationCenter(database: database), mlsClient: client, apiClient: api)
        let repository = MessageRepository(database: database, apiClient: api, e2eRepository: e2e)
        e2e.beforeAccept = {
            // Reproduce the opposing inbox read from a separate thread. A callback
            // still holding writableContext would prevent this queued read from
            // executing until the callback returns, causing the production cycle.
            let writerAvailable = DispatchSemaphore(value: 0)
            database.writableContext.perform { writerAvailable.signal() }
            XCTAssertEqual(writerAvailable.wait(timeout: .now() + 2), .success,
                "Canonical acceptance must release the database writer before entering MLS")
        }
        if cancelBeforeIntent {
            e2e.beforePrepare = {
                // Reproduce cancellation's journal lookup before the sender creates its
                // first intent, then its completed Core Data deletion before seal returns.
                XCTAssertNil(try e2e.cancelOutgoingSend(uuid: uuid, destination: cid))
                try database.writeAndWait { session in
                    let row = try XCTUnwrap(session.message(id: uuid))
                    row.isHardDeleted = true
                    row.type = MessageType.deleted.rawValue
                    row.deletedAt = DBDate()
                    row.text = ""
                    row.localMessageState = .sendingFailed
                }
            }
        }
        api.holdReconciliation = !automaticReconcile
        var reconcileResponses = 0
        var paths: [String] = [], envelopes: [Data] = []
        api.transport = { path, body in
            paths.append(path); envelopes.append(body)
            if paths.count == 1 && !directAcceptance { throw URLError(.timedOut) }
            reconcileResponses += 1
            if coalescedWake && reconcileResponses == 1 { throw URLError(.networkConnectionLost) }
            var root = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            var message = root["message"] as! [String: Any]
            message["msg_seq"] = 1; message["device_id"] = client.currentDeviceId
            message["user"] = ["id":"native-sender", "project_id":"project"]
            message["created_at"] = "2026-11-02T00:00:00Z"; message["updated_at"] = "2026-11-02T00:00:00Z"
            root["message"] = message
            return try JSONSerialization.data(withJSONObject: root)
        }
        let first = expectation(description: "lost ack ends once")
        repository.sendMessage(with: uuid) { result in
            if directAcceptance {
                if case .failure = result { XCTFail("Canonical direct response must complete") }
            } else if case .success = result { XCTFail("Lost acknowledgement is not canonical acceptance") }
            first.fulfill()
        }
        wait(for: [first], timeout: 10)
        if directAcceptance {
            XCTAssertEqual(paths.count, 1)
            let accepted = try XCTUnwrap(e2e.outgoingSendIntent(uuid: uuid))
            XCTAssertEqual(accepted.phase, .accepted)
            XCTAssertTrue(accepted.nativeRetired)
            try database.writeAndWait { session in XCTAssertNil(session.message(id: uuid)?.localMessageState) }
            return
        }
        if cancelBeforeIntent {
            let canceled = try XCTUnwrap(e2e.outgoingSendIntent(uuid: uuid))
            XCTAssertEqual(canceled.phase, .canceled)
            XCTAssertTrue(canceled.nativeRetired)
            XCTAssertTrue(paths.isEmpty)
            XCTAssertThrowsError(try e2e.retryOutgoingSend(uuid: uuid))
            return
        }
        let unknown = try XCTUnwrap(e2e.outgoingSendIntent(uuid: uuid))
        if !automaticReconcile { XCTAssertEqual(unknown.phase, .dispatched) }
        if automaticReconcile || coalescedWake {
            if coalescedWake {
                // The first read-only result is still unknown. A real wake during that
                // in-flight request must survive and cause one bounded follow-up.
                e2e.resumeOutgoingReconciliation?()
                e2e.resumeOutgoingReconciliation?()
                let inFlight = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in api.heldReconciliationCount == 1 }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [inFlight], timeout: 10), .completed)
                api.releaseReconciliations()
            }
            let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                (try? e2e.outgoingSendIntent(uuid: uuid)?.phase) == .accepted
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 10), .completed)
        } else if cancelAfterDispatch {
            var model: ChatMessage?
            try database.writeAndWait { session in model = try session.message(id: uuid)?.asModel() }
            let updater = MessageUpdater(isLocalStorageEnabled: true, messageRepository: repository,
                paginationStateHandler: MessagesPaginationStateHandler(), database: database, apiClient: api)
            let canceled = expectation(description: "cancel retains unknown acceptance")
            updater.deleteMessage(message: try XCTUnwrap(model), cid: cid, onlyForMe: true) { error in
                XCTAssertNil(error); canceled.fulfill()
            }
            wait(for: [canceled], timeout: 10)
            XCTAssertEqual(try e2e.outgoingSendIntent(uuid: uuid)?.phase, .canceledDispatched)
            XCTAssertThrowsError(try e2e.retryOutgoingSend(uuid: uuid))
            let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                (try? e2e.outgoingSendIntent(uuid: uuid)?.phase) == .accepted
            }, object: nil)
            e2e.resumeOutgoingReconciliation?()
            api.releaseReconciliations()
            XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 10), .completed)
        } else {
            try e2e.retryOutgoingSend(uuid: uuid)
            try database.writeAndWait { session in session.message(id: uuid)?.localMessageState = .pendingSend }
            let second = expectation(description: "canonical reconcile")
            var retryResult: Result<ChatMessage, MessageRepositoryError>?
            repository.sendMessage(with: uuid) { result in
                retryResult = result
                second.fulfill()
            }
            // A concurrent explicit Retry may join the existing unknown outcome;
            // both must remain read-only and preserve the same wire intent.
            api.releaseReconciliations()
            wait(for: [second], timeout: 10)
            if case .failure(let error) = try XCTUnwrap(retryResult) {
                // Automatic acceptance can win while Retry is preparing its local
                // projection. Only this typed terminal guard is an allowed skip;
                // the durable/native and Core Data assertions below must still pass.
                switch error {
                case .messageNotPendingSend: break
                case .failedToEncryptedMessage(let underlying):
                    guard case MessageRepositoryError.messageNotPendingSend = underlying else {
                        XCTFail("Unexpected Retry preparation failure: \(underlying)"); return
                    }
                default: XCTFail("Unexpected Retry failure: \(error)"); return
                }
            }
        }
        XCTAssertEqual(paths.first, "v1/e2ee/channels/" + cid.apiPath + "/message")
        XCTAssertTrue(paths.dropFirst().allSatisfy { $0 == "v1/e2ee/channels/" + cid.apiPath + "/message/reconcile" })
        XCTAssertTrue((2...3).contains(paths.count), "One POST and a bounded read-only reconciliation, never POST replay")
        if automaticReconcile { XCTAssertEqual(paths.count, 2) }
        if coalescedWake { XCTAssertEqual(paths.count, 3) }
        let exactEnvelope = try XCTUnwrap(envelopes.first)
        XCTAssertTrue(envelopes.allSatisfy { $0 == exactEnvelope })
        let accepted = try XCTUnwrap(e2e.outgoingSendIntent(uuid: uuid))
        XCTAssertEqual(accepted.phase, .accepted)
        XCTAssertTrue(accepted.nativeRetired)
        try database.writeAndWait { session in
            XCTAssertNil(session.message(id: uuid)?.localMessageState)
            XCTAssertEqual(session.message(id: uuid)?.isHardDeleted, cancelAfterDispatch)
        }
    }
}
