import XCTest
import CoreData
import CryptoKit
import open_mls_ios
@testable import ErmisChat

/// Native provider + repository + durable control DB. Keychain is injected only for this
/// component fixture; physical protected-storage/Keychain acceptance remains a separate gate.
final class MlsRecoveryControlRepositoryTests: XCTestCase {
    private final class SecureStore: MlsDeviceIdSecureStoring {
        var values: [String: String] = [:]
        func load(userId: String) throws -> String? { values[userId] }
        func save(deviceId: String, userId: String) throws { values[userId] = deviceId }
        func remove(userId: String) throws { values.removeValue(forKey: userId) }
    }
    private func withFixture(_ body: (MlsClient, E2eRepository, ChannelId) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "control-repository-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        // Retain native fixture files for failure/reopen investigation; no private bytes in logs.
        let devices = MlsDeviceIdStore(defaults: defaults, legacyDefaults: defaults, secureStore: SecureStore())
        let client = MlsClient(storageFolderURL: root, deviceIdStore: devices, userDefaults: defaults)
        try client.setup(with: "control-fixture")
        let cid = try ChannelId(cid: "team:project:control-fixture")
        let group = try Group.createWithCid(provider: XCTUnwrap(client.provider), founder: XCTUnwrap(client.identity), cid: cid.rawValue)
        try group.saveState(provider: XCTUnwrap(client.provider))
        let database = DatabaseContainer(kind: .inMemory, shouldResetEphemeralValuesOnStart: false)
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !database.persistentStoreCoordinator.persistentStores.isEmpty
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 5), .completed)
        let url = try XCTUnwrap(URL(string: "https://control-fixture.invalid"))
        let encoder = DefaultRequestEncoder(baseURL: url, authURL: url, stickerURL: url, apiKey: APIKey("fixture"))
        let decoder = DefaultRequestDecoder()
        let config = URLSessionConfiguration.ephemeral
        let api = APIClient(sessionConfiguration: config, requestEncoder: encoder, requestDecoder: decoder,
            uploader: ErmisUploader(uploadClient: ErmisUploadClient(encoder: encoder, decoder: decoder, sessionConfiguration: config)),
            downloader: ErmisDownloader(client: ErmisDownloadClient(sessionConfiguration: config)))
        let repository = E2eRepository(database: database, eventNotificationCenter: EventNotificationCenter(database: database), mlsClient: client, apiClient: api)
        try body(client, repository, cid)
    }
    private func observe(_ action: String, revision: String, client: MlsClient, cid: ChannelId,
                         generation: UInt64 = 0, groupId: Data? = nil) throws {
        let bytes = try JSONSerialization.data(withJSONObject: ["incident_id": "00000000-0000-4000-8000-000000000001",
            "recovery_action": action, "recovery_revision": revision, "repair_retry_until": NSNull()])
        let control = try JSONDecoder().decode(MlsRecoveryControl.self, from: bytes)
        let signer = SHA256.hash(data: try XCTUnwrap(client.identity).signaturePublicKey()).map { String(format: "%02x", $0) }.joined()
        let checkpoint = MlsRecoveryControlCheckpoint(userId: "control-fixture", deviceId: try XCTUnwrap(client.currentDeviceId),
            signerSha256: signer, cid: cid.rawValue, generation: generation, groupId: groupId, control: control)
        _ = try client.recoveryControlStore().observe(checkpoint, assertCurrent: {})
    }
    func testMissingControlCannotPublishCachedReadyAndManualBlocksNativeSend() throws {
        try withFixture { client, repository, cid in
            XCTAssertEqual(repository.readiness(for: cid), .restoring)
            try observe("none", revision: "1", client: client, cid: cid)
            XCTAssertEqual(repository.readiness(for: cid), .ready)
            try observe("manual_intervention_required", revision: "2", client: client, cid: cid)
            XCTAssertNotEqual(repository.readiness(for: cid), .ready)
            XCTAssertThrowsError(try repository.encryptedMessage(E2ePayload(text: "QA-manual-must-not-encrypt", attachments: [], stickerUrl: nil), in: cid))
            XCTAssertTrue(try client.loadGroup(with: cid.rawValue).isOperational())
        }
    }
    func testRepairAndWaitingControlsRetainValidNativeGroupAndAllowLocalValidation() throws {
        try withFixture { client, repository, cid in
            let identity = try XCTUnwrap(client.identity).toBytes()
            for (action, revision) in [("repair", "1"), ("waiting_for_evidence", "2")] {
                try observe(action, revision: revision, client: client, cid: cid)
                XCTAssertEqual(repository.readiness(for: cid), .ready)
                XCTAssertEqual(try XCTUnwrap(client.identity).toBytes(), identity)
            }
        }
    }
    func testFutureGenerationControlCannotAuthorizeInstalledLegacyGroup() throws {
        try withFixture { client, repository, cid in
            try observe("none", revision: "1", client: client, cid: cid, generation: 1, groupId: Data([1, 2, 3]))
            XCTAssertNotEqual(repository.readiness(for: cid), .ready)
        }
    }
    func testReobservedActivatedReceiptDoesNotRejectOrRewindAdvancedNativeGroup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "activation-replay-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let devices = MlsDeviceIdStore(defaults: defaults, legacyDefaults: defaults, secureStore: SecureStore())
        // Native client fixture has no repository owner. Repository tests above continue to use
        // the real mutation executor; never remove its assertion to exercise this primitive.
        let client = MlsClient(storageFolderURL: root, deviceIdStore: devices, userDefaults: defaults)
        try client.setup(with: "activation-fixture")
        let cid = try ChannelId(cid: "team:project:activation-replay")
        do {
            let operation = UUID().uuidString.lowercased()
            let candidate = try client.prepareRebootstrapCandidate(operationId: operation, groupId: Data(UUID().uuidString.utf8), keyPackages: [])
            try client.activateRebootstrapCandidate(cid: cid.rawValue, generation: 1, operationId: operation, candidate: candidate)
            let provider = try Provider.newWithPath(dbPath: candidate.providerPath)
            let identity = try Identity.fromBytes(provider: provider, data: XCTUnwrap(provider.loadIdentity()))
            let group = try Group.loadFromStorageWithGroupId(provider: provider, groupId: candidate.groupId)
            let peer = Provider()
            let peerIdentity = try Identity(provider: peer, userId: "native-receipt-peer")
            _ = try group.addMembers(provider: provider, sender: identity, newMembers: [peerIdentity.keyPackage(provider: peer)])
            try group.mergePendingCommit(provider: provider)
            try group.saveState(provider: provider)
            let epoch = group.epoch()
            XCTAssertGreaterThan(epoch, candidate.epoch)
            XCTAssertNoThrow(try client.activateRebootstrapCandidate(cid: cid.rawValue, generation: 1, operationId: operation, candidate: candidate))
            XCTAssertEqual(try client.loadGroup(with: cid.rawValue).epoch(), epoch)
            XCTAssertThrowsError(try client.activateRebootstrapCandidate(cid: cid.rawValue, generation: 1, operationId: UUID().uuidString, candidate: candidate))
        }
    }

    func testIdentityAndMonotoneControlMigrateTogetherWithProvider() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "control-provider-migration-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let devices = MlsDeviceIdStore(defaults: defaults, legacyDefaults: defaults, secureStore: SecureStore())
        let first = MlsClient(storageFolderURL: root.appendingPathComponent("legacy"), deviceIdStore: devices, userDefaults: defaults)
        try first.setup(with: "control-fixture")
        let identity = try XCTUnwrap(first.identity).toBytes()
        let device = try XCTUnwrap(first.currentDeviceId)
        let signer = SHA256.hash(data: try XCTUnwrap(first.identity).signaturePublicKey()).map { String(format: "%02x", $0) }.joined()
        let cid = try ChannelId(cid: "team:project:control-migration")
        try observe("none", revision: "18446744073709551615", client: first, cid: cid)
        let before = try first.recoveryControlStore().load(userId: "control-fixture", deviceId: device, signerSha256: signer, cid: cid.rawValue)
        XCTAssertNotNil(before)
        try first.reset()
        let second = MlsClient(storageFolderURL: root.appendingPathComponent("destination"),
            legacyStorageFolderURLs: [root.appendingPathComponent("legacy")], deviceIdStore: devices, userDefaults: defaults)
        try second.setup(with: "control-fixture")
        XCTAssertEqual(try XCTUnwrap(second.identity).toBytes(), identity)
        XCTAssertEqual(second.currentDeviceId, device)
        XCTAssertEqual(try second.recoveryControlStore().load(userId: "control-fixture", deviceId: device, signerSha256: signer, cid: cid.rawValue), before)
    }

    private final class BootstrapDiscoveryFailureAPI: APIClient {
        var discoveries = 0
        override func request<Response: Decodable>(endpoint: Endpoint<Response>, completion: @escaping (Result<Response, Error>) -> Void) {
            guard Response.self == MlsGenerationStatePayload.self else {
                completion(.failure(ClientError("Unexpected fixture endpoint"))); return
            }
            discoveries += 1
            completion(.failure(URLError(.notConnectedToInternet)))
        }
    }

    func testChannelListRefreshDoesNotRetryFailedScopeButExplicitOpenCanResume() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "bootstrap-list-" + UUID().uuidString))
        let devices = MlsDeviceIdStore(defaults: defaults, legacyDefaults: defaults, secureStore: SecureStore())
        let client = MlsClient(storageFolderURL: root, deviceIdStore: devices, userDefaults: defaults)
        try client.setup(with: "bootstrap-fixture")
        let identity = try XCTUnwrap(client.identity).toBytes()
        let provider = try XCTUnwrap(client.provider)
        let healthy = try ChannelId(cid: "team:project:healthy-fixture")
        let group = try Group.createWithCid(provider: provider, founder: XCTUnwrap(client.identity), cid: healthy.rawValue)
        try group.saveState(provider: provider)
        let missing = try ChannelId(cid: "team:project:missing-fixture")
        let database = DatabaseContainer(kind: .inMemory, shouldResetEphemeralValuesOnStart: false)
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !database.persistentStoreCoordinator.persistentStores.isEmpty }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 5), .completed)
        let base = URL(string: "https://bootstrap-list.invalid")!, config = URLSessionConfiguration.ephemeral
        let encoder = DefaultRequestEncoder(baseURL: base, authURL: base, stickerURL: base, apiKey: APIKey("fixture"))
        let decoder = DefaultRequestDecoder()
        let api = BootstrapDiscoveryFailureAPI(sessionConfiguration: config, requestEncoder: encoder, requestDecoder: decoder,
            uploader: ErmisUploader(uploadClient: ErmisUploadClient(encoder: encoder, decoder: decoder, sessionConfiguration: config)),
            downloader: ErmisDownloader(client: ErmisDownloadClient(sessionConfiguration: config)))
        let repository = E2eRepository(database: database, eventNotificationCenter: EventNotificationCenter(database: database), mlsClient: client, apiClient: api)
        repository.handleNewEncryptedChannels([missing])
        XCTAssertEqual(api.discoveries, 1)
        XCTAssertEqual(repository.readiness(for: missing), .infrastructureRetryable)
        for _ in 0..<12 { repository.handleNewEncryptedChannels([missing, missing]) }
        XCTAssertEqual(api.discoveries, 1, "List hydration must not renew a failed bootstrap retry budget")
        let retry = expectation(description: "explicit open completes bounded recovery")
        repository.ensureE2eeReady(for: missing) { state in
            XCTAssertEqual(state, .infrastructureRetryable); retry.fulfill()
        }
        wait(for: [retry], timeout: 5)
        XCTAssertEqual(api.discoveries, 2, "Explicit scope demand can still retry; no permanent failure quarantine")
        XCTAssertEqual(try Group.loadFromStorage(provider: provider, cid: healthy.rawValue).groupId(), group.groupId())
        XCTAssertEqual(try XCTUnwrap(provider.loadIdentity()), identity)
    }

    private final class WelcomeOnJoinFailureClient: MlsClient {
        var welcome: Data!
        var tree: RatchetTree!
        var didInstallWelcome = false
        override func externalJoinIsolated(cid: String, generation: UInt64, groupInfo: Data, expectedGroupId: Data?) throws -> ExternalJoinResult {
            do { return try super.externalJoinIsolated(cid: cid, generation: generation, groupInfo: groupInfo, expectedGroupId: expectedGroupId) }
            catch {
                // Deterministic failure-boundary interleaving: the candidate failed, and a
                // valid independently received Welcome is installed before catch cleanup.
                _ = try joinWithWelcome(cid: cid, welcome: welcome, ratchetTree: tree)
                didInstallWelcome = true
                throw error
            }
        }
    }
    private final class GroupInfoAPI: APIClient {
        var payload: Data!
        override func request<Response: Decodable>(endpoint: Endpoint<Response>, completion: @escaping (Result<Response, Error>) -> Void) {
            do {
                guard Response.self == GroupInfoPayload.self else { throw ClientError("Unselected fixture endpoint") }
                completion(.success(try JSONDecoder.ermis.decode(Response.self, from: payload)))
            } catch { completion(.failure(error)) }
        }
    }
    func testFailedIsolatedJoinPreservesWelcomeInstalledAtFailureBoundary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("welcome-race-" + UUID().uuidString)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "welcome-race-" + UUID().uuidString))
        let devices = MlsDeviceIdStore(defaults: defaults, legacyDefaults: defaults, secureStore: SecureStore())
        let client = WelcomeOnJoinFailureClient(storageFolderURL: root, deviceIdStore: devices, userDefaults: defaults, importLegacyStorage: false)
        try client.setup(with: "welcome-race-user")
        let provider = try XCTUnwrap(client.provider)
        let signer = try XCTUnwrap(client.identity).signaturePublicKey()
        let cid = try ChannelId(cid: "team:project:welcome-race")
        let peer = Provider(), founder = try Identity(provider: peer, userId: "welcome-founder")
        let group = try Group.createWithCid(provider: peer, founder: founder, cid: cid.rawValue)
        let add = try group.addMembers(provider: peer, sender: founder, newMembers: [KeyPackage.fromBytes(data: XCTUnwrap(client.getKeyPackage()))])
        try group.mergePendingCommit(provider: peer)
        client.welcome = try XCTUnwrap(add.welcome); client.tree = group.exportRatchetTree()
        let database = DatabaseContainer(kind: .inMemory, shouldResetEphemeralValuesOnStart: false)
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !database.persistentStoreCoordinator.persistentStores.isEmpty }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 5), .completed)
        let base = URL(string: "https://welcome-race.invalid")!, config = URLSessionConfiguration.ephemeral
        let encoder = DefaultRequestEncoder(baseURL: base, authURL: base, stickerURL: base, apiKey: APIKey("fixture"))
        let api = GroupInfoAPI(sessionConfiguration: config, requestEncoder: encoder, requestDecoder: DefaultRequestDecoder(),
            uploader: ErmisUploader(uploadClient: ErmisUploadClient(encoder: encoder, decoder: DefaultRequestDecoder(), sessionConfiguration: config)),
            downloader: ErmisDownloader(client: ErmisDownloadClient(sessionConfiguration: config)))
        api.payload = try JSONSerialization.data(withJSONObject: ["channel": ["cid": cid.rawValue, "type": "team", "created_at": "2026-11-02T00:00:00Z", "updated_at": "2026-11-02T00:00:00Z", "mls_enabled": true], "group_info": "AQID", "epoch": 1, "hash": "fixture", "is_stale": false, "group_generation": 0])
        let repository = E2eRepository(database: database, eventNotificationCenter: EventNotificationCenter(database: database), mlsClient: client, apiClient: api)
        let finished = expectation(description: "invalid candidate completes")
        repository.externalJoinChannel(cid: cid, retriesRemaining: 0) { error in XCTAssertNotNil(error); finished.fulfill() }
        wait(for: [finished], timeout: 5)
        XCTAssertTrue(client.didInstallWelcome)
        let kept = try Group.loadFromStorage(provider: provider, cid: cid.rawValue)
        XCTAssertEqual(kept.epoch(), group.epoch())
        XCTAssertEqual(kept.groupId(), group.groupId())
        XCTAssertEqual(try Identity.fromBytes(provider: provider, data: XCTUnwrap(provider.loadIdentity())).signaturePublicKey(), signer)
    }

    func testConflictingApplicationIndexTimestampCannotAdvanceDurableCursorOrReplaceGroup() throws {
        try withFixture { client, _, cid in
            let provider = try XCTUnwrap(client.provider)
            let group = try client.loadGroup(with: cid.rawValue)
            let groupId = group.groupId(), epoch = group.epoch()
            let signer = try XCTUnwrap(provider.loadIdentity())
            let database = DatabaseContainer(kind: .inMemory, shouldResetEphemeralValuesOnStart: false)
            let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                !database.persistentStoreCoordinator.persistentStores.isEmpty
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 5), .completed)
            let store = E2eeDurableInboxStore(database: database)
            let id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
            func event(_ id: String, _ indexedAt: String) throws -> E2eSyncEventEnvelope {
                let data = try JSONSerialization.data(withJSONObject: [
                    "cid": cid.rawValue, "event_id": id, "created_at": indexedAt,
                    "type": "application", "data": [
                        "id": id, "type": "regular", "content_type": "text/plain",
                        "mls_ciphertext": "AQID", "mls_epoch": 2,
                        "created_at": "2026-11-03T05:57:19.940474Z"
                    ]
                ])
                return try JSONDecoder.default.decode(E2eSyncEventEnvelope.self, from: data)
            }
            let original = try event(id, "2026-11-03T05:57:19.940474Z")
            let conflict = try event(id, "2026-11-03T05:57:19.940481Z")
            let tail = try event("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "2026-11-03T08:26:39.211290Z")
            let cursor = ScopeSyncCursorPayload(createdAt: original.createdAtRaw, eventId: original.eventId)
            _ = try store.persistPage(accountId: "control-fixture", scopeCid: cid.rawValue,
                                      events: [original], hasMore: false, nextCursor: cursor)
            let next = ScopeSyncCursorPayload(createdAt: tail.createdAtRaw, eventId: tail.eventId)
            XCTAssertThrowsError(try store.persistPage(accountId: "control-fixture", scopeCid: cid.rawValue,
                events: [conflict, tail], hasMore: false, nextCursor: next)) {
                XCTAssertEqual($0 as? E2eeDurableInboxError, .duplicateEventPayloadMismatch(eventId: id))
            }
            XCTAssertEqual(try store.fetchCursor(accountId: "control-fixture", scopeCid: cid.rawValue), cursor)
            let pending = try store.loadPendingEvents(accountId: "control-fixture", scopeCid: cid.rawValue)
            XCTAssertEqual(pending.map(\.eventId), [id])
            XCTAssertEqual(pending.first?.rawEnvelope, original.rawEnvelope)
            XCTAssertEqual(try client.loadGroup(with: cid.rawValue).groupId(), groupId)
            XCTAssertEqual(try client.loadGroup(with: cid.rawValue).epoch(), epoch)
            XCTAssertEqual(try XCTUnwrap(provider.loadIdentity()), signer)
        }
    }

}
