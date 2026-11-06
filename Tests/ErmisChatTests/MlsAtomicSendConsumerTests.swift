import XCTest
import CoreData
import CryptoKit
import open_mls_ios
@testable import ErmisChat

final class MlsAtomicSendConsumerTests: XCTestCase {
    private final class SecureStore: MlsDeviceIdSecureStoring {
        var values: [String: String] = [:]
        func load(userId: String) throws -> String? { values[userId] }
        func save(deviceId: String, userId: String) throws { values[userId] = deviceId }
        func remove(userId: String) throws { values.removeValue(forKey: userId) }
    }
    private func repository(_ client: MlsClient) throws -> E2eRepository {
        let database = DatabaseContainer(kind: .inMemory, shouldResetEphemeralValuesOnStart: false)
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !database.persistentStoreCoordinator.persistentStores.isEmpty }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 5), .completed)
        let url = URL(string: "https://native-send-fixture.invalid")!
        let encoder = DefaultRequestEncoder(baseURL: url, authURL: url, stickerURL: url, apiKey: APIKey("fixture"))
        let decoder = DefaultRequestDecoder(), config = URLSessionConfiguration.ephemeral
        let api = APIClient(sessionConfiguration: config, requestEncoder: encoder, requestDecoder: decoder,
            uploader: ErmisUploader(uploadClient: ErmisUploadClient(encoder: encoder, decoder: decoder, sessionConfiguration: config)),
            downloader: ErmisDownloader(client: ErmisDownloadClient(sessionConfiguration: config)))
        return E2eRepository(database: database, eventNotificationCenter: EventNotificationCenter(database: database), mlsClient: client, apiClient: api)
    }
    func testNativeCommitBeforeClientCipherWriteRecoversSameUUIDAndPeerDecrypt() throws {
        try nativeCommitGap(cancelBeforeClientCipher: false)
    }
    func testCancelAfterNativeCommitBeforeClientCipherWriteRetiresArtifact() throws {
        try nativeCommitGap(cancelBeforeClientCipher: true)
    }
    func testAcceptedGenerationZeroIsolatedProviderRetiresAfterReopen() throws {
        try nativeCommitGap(cancelBeforeClientCipher: false, isolated: true)
    }
    func testAcceptedRootArtifactRetiresAfterIsolatedProviderReplacement() throws {
        try nativeCommitGap(cancelBeforeClientCipher: false, replaceRootBeforeRetire: true)
    }
    private func selectIsolatedProvider(_ client: MlsClient, cid: String, peer: Provider,
                                        peerIdentity: Identity, peerGroup: Group) throws {
        // Generation zero can have a different provider after normal External Join.
        // The peer advances while the installed original group remains intact.
        _ = try peerGroup.selfUpdate(provider: peer, sender: peerIdentity)
        try peerGroup.mergePendingCommit(provider: peer)
        let info = try peerGroup.exportGroupInfo(provider: peer, sender: peerIdentity, withRatchetTree: true)
        let candidate = try client.externalJoinIsolated(cid: cid, generation: 0, groupInfo: info, expectedGroupId: nil)
        var pending = try XCTUnwrap(client.loadPendingGenerationJoin(cid: cid))
        pending.externalJoinBody = try JSONSerialization.data(withJSONObject: [
            "commit": candidate.commit.base64EncodedString(),
            "group_info": client.exportGroupInfo(of: candidate.group).base64EncodedString(),
            "operation_id": UUID().uuidString.lowercased()
        ])
        try client.savePendingGenerationJoin(pending)
        _ = try peerGroup.processMessage(provider: peer, msg: candidate.commit)
        try client.activateExternalJoinCandidate(cid: cid, expected: pending, group: candidate.group)
        try client.finishExternalJoinCandidate(cid: cid, expected: pending)
        XCTAssertNotNil(client.loadGenerationMarker(cid: cid)?.providerPath)
        XCTAssertNotEqual(try client.applicationSendBinding(cid: cid).2, try XCTUnwrap(client.provider).keyPackageUploadProviderId())
    }
    private func nativeCommitGap(cancelBeforeClientCipher: Bool, isolated: Bool = false, replaceRootBeforeRetire: Bool = false) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("atomic-consumer-" + UUID().uuidString)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "atomic-consumer-" + UUID().uuidString))
        let devices = MlsDeviceIdStore(defaults: defaults, legacyDefaults: defaults, secureStore: SecureStore())
        let client = MlsClient(storageFolderURL: root, deviceIdStore: devices, userDefaults: defaults, importLegacyStorage: false)
        try client.setup(with: "native-sender")
        let cid = try ChannelId(cid: "team:project:native-consumer")
        let provider = try XCTUnwrap(client.provider), identity = try XCTUnwrap(client.identity)
        let group = try Group.createWithCid(provider: provider, founder: identity, cid: cid.rawValue)
        let peer = Provider()
        let peerIdentity = try Identity(provider: peer, userId: "native-peer")
        let bundle = try group.addMembers(provider: provider, sender: identity, newMembers: [peerIdentity.keyPackage(provider: peer)])
        try group.mergePendingCommit(provider: provider); try group.saveState(provider: provider)
        let peerGroup = try Group.joinWithWelcome(provider: peer, welcome: XCTUnwrap(bundle.welcome), ratchetTree: group.exportRatchetTree())
        if isolated {
            try selectIsolatedProvider(client, cid: cid.rawValue, peer: peer, peerIdentity: peerIdentity, peerGroup: peerGroup)
        }
        let request = MessageRequestBody(id: UUID().uuidString.lowercased(), user: UserRequestBody(id: "native-sender", name: nil, imageURL: nil), text: "QA-native-crash-gap")
        let payload = E2ePayload(text: request.text, attachments: [], stickerUrl: nil)
        let owner = try client.sendIntentOwner(), binding = try client.applicationSendBinding(cid: cid.rawValue)
        let original = MlsSendIntent(version: 1, uuid: request.id, owner: owner, cid: cid.rawValue,
            scope: String(repeating: "a", count: 64), groupId: binding.1, generation: binding.0,
            providerId: binding.2, payload: try JSONEncoder().encode(payload), aad: Data(),
            originalEnvelope: try JSONEncoder.ermis.encode(["message": request]), phase: .unsealed,
            ciphertext: nil, epoch: nil, wireEnvelope: nil, revision: 0)
        try client.sendIntentStore().save(original, replacing: nil, assertCurrent: {})
        let sealed = try client.prepareApplicationSend(original)
        if replaceRootBeforeRetire {
            var accepted = original
            accepted.phase = .accepted; accepted.nativeSealed = true
            accepted.ciphertext = sealed.ciphertext; accepted.epoch = sealed.epoch
            accepted.wireEnvelope = Data("retained-exact-wire-fixture".utf8)
            try selectIsolatedProvider(client, cid: cid.rawValue, peer: peer, peerIdentity: peerIdentity, peerGroup: peerGroup)
            try client.reset()
            let resumed = MlsClient(storageFolderURL: root, deviceIdStore: devices, userDefaults: defaults, importLegacyStorage: false)
            try resumed.setup(with: "native-sender")
            XCTAssertNoThrow(try resumed.retireApplicationSend(accepted))
            XCTAssertThrowsError(try XCTUnwrap(resumed.identity).recoverApplicationSend(provider: XCTUnwrap(resumed.provider), operationId: accepted.uuid, scope: accepted.scope))
            return
        }
        // Client ciphertext is absent, as in the crash between native commit and Core Data write.
        XCTAssertNil(try client.sendIntentStore().load(uuid: request.id, owner: owner)?.ciphertext)
        try client.reset()
        let reopened = MlsClient(storageFolderURL: root, deviceIdStore: devices, userDefaults: defaults, importLegacyStorage: false)
        try reopened.setup(with: "native-sender")
        XCTAssertEqual(try reopened.recoverApplicationSend(original), sealed)
        let inspectionProvider: Provider
        let inspectionIdentity: Identity
        if let path = reopened.loadGenerationMarker(cid: cid.rawValue)?.providerPath {
            inspectionProvider = try Provider.newWithPath(dbPath: path)
            inspectionIdentity = try Identity.fromBytes(provider: inspectionProvider, data: XCTUnwrap(inspectionProvider.loadIdentity()))
        } else {
            inspectionProvider = try XCTUnwrap(reopened.provider)
            inspectionIdentity = try XCTUnwrap(reopened.identity)
        }
        let repo = try repository(reopened)
        if cancelBeforeClientCipher {
            let canceled = try XCTUnwrap(repo.cancelOutgoingSend(uuid: request.id, destination: cid))
            XCTAssertEqual(canceled.phase, .canceled)
            XCTAssertTrue(try XCTUnwrap(repo.outgoingSendIntent(uuid: request.id)).nativeRetired)
            XCTAssertThrowsError(try XCTUnwrap(reopened.identity).recoverApplicationSend(provider: XCTUnwrap(reopened.provider), operationId: original.uuid, scope: original.scope), "Read-only native inspection: cancellation must retire ciphertext even if the client cipher write never happened")
            XCTAssertThrowsError(try repo.retryOutgoingSend(uuid: request.id))
            return
        }
        let recovered = try repo.prepareOutgoingSend(request, payload: payload, cid: cid)
        XCTAssertEqual(recovered.uuid, request.id)
        XCTAssertEqual(recovered.ciphertext, sealed.ciphertext)
        let decoded = try peerGroup.processMessage(provider: peer, msg: XCTUnwrap(recovered.ciphertext))
        XCTAssertEqual(decoded.content, original.payload)
        let wire = try JSONSerialization.jsonObject(with: XCTUnwrap(recovered.wireEnvelope)) as! [String: Any]
        let message = try XCTUnwrap(wire["message"] as? [String: Any])
        XCTAssertNil(message["text"]); XCTAssertNil(message["attachments"])
        let dispatched = try repo.markOutgoingDispatch(recovered)
        XCTAssertTrue(dispatched.requiresReconcile)
        let retry = try repo.prepareOutgoingSend(request, payload: payload, cid: cid)
        XCTAssertEqual(retry, dispatched)
        XCTAssertThrowsError(try repo.markOutgoingDispatch(recovered), "Concurrent stale dispatch cannot get a second POST authority")
        try repo.acceptOutgoingSend(dispatched)
        let terminal = try XCTUnwrap(repo.outgoingSendIntent(uuid: request.id))
        XCTAssertThrowsError(try inspectionIdentity.recoverApplicationSend(provider: inspectionProvider, operationId: terminal.uuid, scope: terminal.scope), "Native journal must contain a retired tombstone")
        XCTAssertTrue(terminal.nativeRetired)
        XCTAssertEqual(terminal.phase, .accepted)
        XCTAssertNoThrow(try repo.acceptOutgoingSend(dispatched))
        XCTAssertThrowsError(try repo.prepareOutgoingSend(request, payload: payload, cid: cid))
    }
}
