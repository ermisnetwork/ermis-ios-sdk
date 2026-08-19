import XCTest
@testable import ErmisChat
import open_mls_ios
import CryptoKit

final class MlsPersistenceTests: XCTestCase {
    private final class DeviceIdSecureStore: MlsDeviceIdSecureStoring {
        var values: [UserId: String] = [:]

        func load(userId: UserId) throws -> String? {
            values[userId]
        }

        func save(deviceId: String, userId: UserId) throws {
            values[userId] = deviceId
        }

        func remove(userId: UserId) throws {
            values.removeValue(forKey: userId)
        }
    }

    private struct GroupPair {
        let aliceProvider: Provider
        let alice: Identity
        let aliceGroup: Group
        let bobProvider: Provider
        let bobGroup: Group
    }

    private func makeGroupPair(cid: String) throws -> GroupPair {
        let aliceProvider = Provider()
        let bobProvider = Provider()
        let alice = try Identity(provider: aliceProvider, userId: "alice")
        let bob = try Identity(provider: bobProvider, userId: "bob")
        let aliceGroup = try Group.createWithCid(
            provider: aliceProvider,
            founder: alice,
            cid: cid
        )
        let bundle = try aliceGroup.addMembers(
            provider: aliceProvider,
            sender: alice,
            newMembers: [bob.keyPackage(provider: bobProvider)]
        )
        try aliceGroup.mergePendingCommit(provider: aliceProvider)
        let welcome = try XCTUnwrap(bundle.welcome)
        let bobGroup = try Group.joinWithWelcome(
            provider: bobProvider,
            welcome: welcome,
            ratchetTree: aliceGroup.exportRatchetTree()
        )
        return GroupPair(
            aliceProvider: aliceProvider,
            alice: alice,
            aliceGroup: aliceGroup,
            bobProvider: bobProvider,
            bobGroup: bobGroup
        )
    }

    func testUserScopedStorageNamespaceIsStableAndIsolated() {
        let first = ErmisClientFactory.storageNamespace(apiKey: "api", userId: "alice")
        XCTAssertEqual(first, ErmisClientFactory.storageNamespace(apiKey: "api", userId: "alice"))
        XCTAssertNotEqual(first, ErmisClientFactory.storageNamespace(apiKey: "api", userId: "bob"))
        XCTAssertNotEqual(first, ErmisClientFactory.storageNamespace(apiKey: "other", userId: "alice"))
    }

    func testMlsResetPreservesProviderAndDeviceIdentity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ermis-mls-reset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suite = "io.ermis.tests.mls-reset.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let secureStore = DeviceIdSecureStore()
        let deviceIdStore = MlsDeviceIdStore(
            defaults: defaults,
            legacyDefaults: defaults,
            secureStore: secureStore
        )
        let client = MlsClient(storageFolderURL: root, deviceIdStore: deviceIdStore)
        try client.setup(with: "alice")
        let originalDeviceId = try XCTUnwrap(client.currentDeviceId)
        XCTAssertNotNil(client.identity)
        let providerFiles = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("mls"),
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(providerFiles.contains(where: { $0.pathExtension == "db" }))

        try client.reset()
        try client.setup(with: "alice")

        XCTAssertEqual(client.currentDeviceId, originalDeviceId)
        XCTAssertNotNil(client.identity)
    }

    func testExplicitMlsPurgeDeletesProviderAndUserDeviceId() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ermis-mls-purge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suite = "io.ermis.tests.mls-purge.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let secureStore = DeviceIdSecureStore()
        let deviceIdStore = MlsDeviceIdStore(
            defaults: defaults,
            legacyDefaults: defaults,
            secureStore: secureStore
        )
        let client = MlsClient(storageFolderURL: root, deviceIdStore: deviceIdStore)
        try client.setup(with: "alice")
        XCTAssertNotNil(client.currentDeviceId)

        try client.purgeCurrentUserData()

        let deviceIds = defaults.dictionary(forKey: MlsClient.deviceIdKey) as? [String: String]
        XCTAssertNil(deviceIds?["alice"])
        XCTAssertNil(secureStore.values["alice"])
        let files = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("mls"),
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(files.contains(where: { $0.pathExtension == "db" }))
    }

    func testNoMatchingWelcomeIsTypedAndDoesNotDeleteExistingGroupForRetry() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ermis-mls-welcome-error-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let client = MlsClient(storageFolderURL: root)
        try client.setup(with: "local-user")
        let provider = try XCTUnwrap(client.provider)
        let identity = try XCTUnwrap(client.identity)
        let cid = "team:typed-welcome"
        _ = try Group.createWithCid(provider: provider, founder: identity, cid: cid)

        let senderProvider = Provider()
        let targetProvider = Provider()
        let sender = try Identity(provider: senderProvider, userId: "sender")
        let target = try Identity(provider: targetProvider, userId: "other-device")
        let senderGroup = try Group.createWithCid(
            provider: senderProvider,
            founder: sender,
            cid: cid
        )
        let bundle = try senderGroup.addMembers(
            provider: senderProvider,
            sender: sender,
            newMembers: [target.keyPackage(provider: targetProvider)]
        )
        try senderGroup.mergePendingCommit(provider: senderProvider)

        XCTAssertThrowsError(
            try client.joinWithWelcome(
                cid: cid,
                welcome: try XCTUnwrap(bundle.welcome),
                ratchetTree: senderGroup.exportRatchetTree()
            )
        ) { error in
            guard let mlsError = error as? MlsError,
                  case .NoMatchingKeyPackage = mlsError else {
                return XCTFail("Expected typed NoMatchingKeyPackage, received \(error)")
            }
        }
        XCTAssertTrue(client.isGroupLoaded(cid: cid))
    }

    func testRealtimeDecryptFailureRequestsCanonicalGroupScopeRecovery() throws {
        let groupCid = try ChannelId(cid: "team:project:realtime-recovery")
        let failure: Result<E2ePayload, Error> = .failure(
            NSError(domain: "io.ermis.tests.realtime-decrypt", code: 1)
        )

        XCTAssertEqual(
            E2eRepository.realtimeRecoveryScope(after: failure, groupCid: groupCid),
            groupCid
        )

        let success: Result<E2ePayload, Error> = .success(
            E2ePayload(text: "decrypted", attachments: [], stickerUrl: nil)
        )
        XCTAssertNil(E2eRepository.realtimeRecoveryScope(after: success, groupCid: groupCid))
    }

    func testOwnRealtimeEchoSkipsDecryptOnlyWhenPlaintextIsAlreadyCached() {
        XCTAssertTrue(
            E2eRepository.shouldSkipRealtimeDecrypt(
                isSentByCurrentUser: true,
                hasCachedPlaintext: true
            )
        )
        XCTAssertFalse(
            E2eRepository.shouldSkipRealtimeDecrypt(
                isSentByCurrentUser: true,
                hasCachedPlaintext: false
            )
        )
        XCTAssertFalse(
            E2eRepository.shouldSkipRealtimeDecrypt(
                isSentByCurrentUser: false,
                hasCachedPlaintext: true
            )
        )
    }

    func testThreeSequentialApplicationMessagesSurviveSaveAndReload() throws {
        let cid = "team:project:sequential-message-persistence"
        let pair = try makeGroupPair(cid: cid)
        var ciphertexts: [Data] = []

        for index in 1...3 {
            let senderGroup = try Group.loadFromStorage(provider: pair.aliceProvider, cid: cid)
            let plaintext = Data("message-\(index)".utf8)
            let ciphertext = try senderGroup.createMessage(
                provider: pair.aliceProvider,
                sender: pair.alice,
                plaintext: plaintext
            )
            try senderGroup.saveState(provider: pair.aliceProvider)
            ciphertexts.append(ciphertext)
        }

        for (offset, ciphertext) in ciphertexts.enumerated() {
            let receiverGroup = try Group.loadFromStorage(provider: pair.bobProvider, cid: cid)
            let processed = try receiverGroup.processMessage(
                provider: pair.bobProvider,
                msg: ciphertext
            )
            XCTAssertEqual(processed.content, Data("message-\(offset + 1)".utf8))
            try receiverGroup.saveState(provider: pair.bobProvider)
        }
    }

    func testAadRoundTripAndPersistedReplayClassification() throws {
        let cid = "team:project:aad-test"
        let pair = try makeGroupPair(cid: cid)
        let plaintext = Data("hello".utf8)
        let aad = Data("authenticated-metadata".utf8)
        let ciphertext = try pair.aliceGroup.createMessageWithAad(
            provider: pair.aliceProvider,
            sender: pair.alice,
            plaintext: plaintext,
            aad: aad
        )

        let processed = try pair.bobGroup.processMessage(
            provider: pair.bobProvider,
            msg: ciphertext
        )
        XCTAssertEqual(processed.content, plaintext)
        XCTAssertEqual(processed.aad, aad)
        try pair.bobGroup.saveState(provider: pair.bobProvider)

        let reloaded = try Group.loadFromStorage(provider: pair.bobProvider, cid: cid)
        XCTAssertThrowsError(try reloaded.processMessage(provider: pair.bobProvider, msg: ciphertext)) {
            guard case MlsError.MessageAlreadyConsumed = $0 else {
                return XCTFail("Expected MessageAlreadyConsumed, got \($0)")
            }
        }
    }

    func testCrashAfterPlaintextBeforeProviderSaveReprocessesAndPersistsReceiverState() throws {
        let cid = "team:project:plaintext-before-provider-save"
        let pair = try makeGroupPair(cid: cid)
        let plaintext = Data("crash-recovery".utf8)
        let ciphertext = try pair.aliceGroup.createMessage(
            provider: pair.aliceProvider,
            sender: pair.alice,
            plaintext: plaintext
        )
        try pair.aliceGroup.saveState(provider: pair.aliceProvider)

        // First attempt represents plaintext already committed to Core Data. Deliberately do not
        // save this mutated Group, as if the process stopped immediately before provider save.
        let firstAttempt = try Group.loadFromStorage(provider: pair.bobProvider, cid: cid)
        XCTAssertEqual(
            try firstAttempt.processMessageDeferred(provider: pair.bobProvider, msg: ciphertext).content,
            plaintext
        )

        // Relaunch reloads the last durable provider state, so the exact raw inbox event can be
        // processed again and the receiver ratchet can now be persisted.
        let replay = try Group.loadFromStorage(provider: pair.bobProvider, cid: cid)
        XCTAssertEqual(
            try replay.processMessageDeferred(provider: pair.bobProvider, msg: ciphertext).content,
            plaintext
        )
        try replay.saveState(provider: pair.bobProvider)

        let persisted = try Group.loadFromStorage(provider: pair.bobProvider, cid: cid)
        XCTAssertThrowsError(try persisted.processMessage(provider: pair.bobProvider, msg: ciphertext)) {
            guard case MlsError.MessageAlreadyConsumed = $0 else {
                return XCTFail("Expected persisted receiver state, got \($0)")
            }
        }
    }

    func testConsumedReplayFinalizesOnlyWithExactCiphertextProof() throws {
        let cid = "team:project:consumed-proof"
        let pair = try makeGroupPair(cid: cid)
        let ciphertext = try pair.aliceGroup.createMessage(
            provider: pair.aliceProvider,
            sender: pair.alice,
            plaintext: Data("exact-proof".utf8)
        )
        let receiver = try Group.loadFromStorage(provider: pair.bobProvider, cid: cid)
        _ = try receiver.processMessage(provider: pair.bobProvider, msg: ciphertext)
        try receiver.saveState(provider: pair.bobProvider)

        let persisted = try Group.loadFromStorage(provider: pair.bobProvider, cid: cid)
        XCTAssertThrowsError(try persisted.processMessage(provider: pair.bobProvider, msg: ciphertext)) { error in
            let exactHash = Data(SHA256.hash(data: ciphertext))
            XCTAssertTrue(
                E2eeApplicationReplayRecovery.canFinalizeFromCachedPlaintext(
                    error: error,
                    cachedCiphertextHash: exactHash,
                    ciphertext: ciphertext
                )
            )
            XCTAssertFalse(
                E2eeApplicationReplayRecovery.canFinalizeFromCachedPlaintext(
                    error: error,
                    cachedCiphertextHash: Data(repeating: 0, count: 32),
                    ciphertext: ciphertext
                )
            )
            XCTAssertFalse(
                E2eeApplicationReplayRecovery.canFinalizeFromCachedPlaintext(
                    error: error,
                    cachedCiphertextHash: nil,
                    ciphertext: ciphertext
                )
            )
        }
    }

    func testCorruptCiphertextIsNotClassifiedAsConsumed() throws {
        let pair = try makeGroupPair(cid: "team:project:corrupt-test")
        var ciphertext = try pair.aliceGroup.createMessageWithAad(
            provider: pair.aliceProvider,
            sender: pair.alice,
            plaintext: Data("hello".utf8),
            aad: Data("authenticated-metadata".utf8)
        )
        ciphertext[ciphertext.index(before: ciphertext.endIndex)] ^= 0x01

        XCTAssertThrowsError(
            try pair.bobGroup.processMessage(provider: pair.bobProvider, msg: ciphertext)
        ) { error in
            XCTAssertFalse(
                E2eeApplicationReplayRecovery.canFinalizeFromCachedPlaintext(
                    error: error,
                    cachedCiphertextHash: Data(SHA256.hash(data: ciphertext)),
                    ciphertext: ciphertext
                )
            )
            guard case MlsError.InvalidMessage = error else {
                return XCTFail("Expected InvalidMessage, got \(error)")
            }
        }
    }

    func testTamperedEnvelopeAADIsRejectedAfterDecrypt() throws {
        let pair = try makeGroupPair(cid: "team:project:aad-envelope-test")
        let originalAAD = try E2eeMessageAADV1(
            cid: "team:project:aad-envelope-test",
            e2eeGroupId: "team:project:aad-envelope-test",
            messageId: "11111111-1111-4111-8111-111111111111",
            forwardCid: "messaging:source",
            forwardMessageId: "22222222-2222-4222-8222-222222222222"
        ).encoded()
        let ciphertext = try pair.aliceGroup.createMessageWithAad(
            provider: pair.aliceProvider,
            sender: pair.alice,
            plaintext: Data("hello".utf8),
            aad: originalAAD
        )
        let processed = try pair.bobGroup.processMessage(
            provider: pair.bobProvider,
            msg: ciphertext
        )
        try E2eeMessageAADV1.verify(processedAAD: processed.aad, expectedAAD: originalAAD)

        let tamperedEnvelopeAAD = try E2eeMessageAADV1(
            cid: "team:project:aad-envelope-test",
            e2eeGroupId: "team:project:aad-envelope-test",
            messageId: "11111111-1111-4111-8111-111111111111",
            forwardCid: "messaging:tampered-source",
            forwardMessageId: "22222222-2222-4222-8222-222222222222"
        ).encoded()
        XCTAssertThrowsError(
            try E2eeMessageAADV1.verify(
                processedAAD: processed.aad,
                expectedAAD: tamperedEnvelopeAAD
            )
        ) {
            guard case E2eeMessageAADError.authenticatedMetadataMismatch = $0 else {
                return XCTFail("Expected authenticatedMetadataMismatch, got \($0)")
            }
        }
    }

    func testCommitProcessingAdvancesExpectedEpochBeforeExplicitSave() throws {
        let cid = "team:project:commit-replay-test"
        let pair = try makeGroupPair(cid: cid)
        let startingEpoch = pair.bobGroup.epoch()
        let commit = try pair.aliceGroup.selfUpdate(
            provider: pair.aliceProvider,
            sender: pair.alice
        )

        let client = MlsClient()
        client.provider = pair.bobProvider
        let processed = try client.processProtocolMessage(data: commit.commit, in: pair.bobGroup)
        guard case .commit(let metadata) = processed else {
            return XCTFail("Expected a typed commit result")
        }
        XCTAssertEqual(metadata.messageEpoch, startingEpoch)
        XCTAssertEqual(metadata.groupEpochBefore, startingEpoch)
        XCTAssertEqual(metadata.groupEpochAfter, startingEpoch + 1)
        XCTAssertEqual(metadata.aad, Data())
        XCTAssertEqual(pair.bobGroup.epoch(), startingEpoch + 1)

        try client.saveState(of: pair.bobGroup)
        let reloaded = try Group.loadFromStorage(provider: pair.bobProvider, cid: cid)
        XCTAssertEqual(reloaded.epoch(), startingEpoch + 1)
    }

    func testTypedApplicationProcessingPreservesPlaintextAndMetadataBeforeExplicitSave() throws {
        let cid = "team:project:typed-application"
        let pair = try makeGroupPair(cid: cid)
        let payload = E2ePayload(text: "typed application", attachments: [], stickerUrl: nil)
        let plaintext = try JSONEncoder().encode(payload)
        let aad = Data("typed-aad".utf8)
        let startingEpoch = pair.bobGroup.epoch()
        let ciphertext = try pair.aliceGroup.createMessageWithAad(
            provider: pair.aliceProvider,
            sender: pair.alice,
            plaintext: plaintext,
            aad: aad
        )
        try pair.aliceGroup.saveState(provider: pair.aliceProvider)

        let client = MlsClient()
        client.provider = pair.bobProvider
        let processed = try client.processApplicationMessage(data: ciphertext, in: pair.bobGroup)
        XCTAssertEqual(processed.plaintext, plaintext)
        XCTAssertEqual(processed.payload, payload)
        XCTAssertEqual(processed.aad, aad)
        XCTAssertEqual(processed.epoch, startingEpoch)
        XCTAssertEqual(processed.senderIndex, 0)
        XCTAssertEqual(processed.resultingGroupEpoch, startingEpoch)

        // Deferred processing leaves the durable receiver ratchet replayable until the caller
        // stores plaintext and explicitly saves the mutated group state.
        let replay = try Group.loadFromStorage(provider: pair.bobProvider, cid: cid)
        XCTAssertEqual(
            try client.processApplicationMessage(data: ciphertext, in: replay).plaintext,
            plaintext
        )
        try client.saveState(of: replay)
    }

    func testTypedProposalReportsBindingPersistenceWithoutEnablingBellboyProposalFlow() throws {
        let cid = "team:project:typed-proposal"
        let pair = try makeGroupPair(cid: cid)
        let charlieProvider = Provider()
        let charlie = try Identity(provider: charlieProvider, userId: "charlie")
        let proposal = try pair.aliceGroup.proposeAddMember(
            provider: pair.aliceProvider,
            sender: pair.alice,
            newMember: charlie.keyPackage(provider: charlieProvider)
        )
        let startingEpoch = pair.bobGroup.epoch()

        let client = MlsClient()
        client.provider = pair.bobProvider
        let processed = try client.processProtocolMessage(data: proposal.bytes, in: pair.bobGroup)
        guard case .proposal(let metadata) = processed else {
            return XCTFail("Expected a typed proposal result")
        }
        XCTAssertEqual(metadata.messageEpoch, startingEpoch)
        XCTAssertEqual(metadata.groupEpochBefore, startingEpoch)
        XCTAssertEqual(metadata.groupEpochAfter, startingEpoch)
        XCTAssertEqual(pair.bobGroup.pendingProposalsCount(), 1)

        // OpenMLS stores a received pending proposal during processMessage. Bellboy has no active
        // standalone-proposal producer; production sync still rejects that reserved wire type.
        let reloaded = try Group.loadFromStorage(provider: pair.bobProvider, cid: cid)
        XCTAssertEqual(reloaded.pendingProposalsCount(), 1)
    }

    func testOutgoingCrashBeforeProviderSaveCanReencryptFromDurableSenderState() throws {
        let cid = "team:project:outgoing-before-provider-save"
        let pair = try makeGroupPair(cid: cid)
        let plaintext = Data("replacement generation".utf8)

        let discardedGeneration = try Group.loadFromStorage(provider: pair.aliceProvider, cid: cid)
        _ = try discardedGeneration.createMessage(
            provider: pair.aliceProvider,
            sender: pair.alice,
            plaintext: plaintext
        )
        // Simulate termination before the sender group is explicitly stored.

        let replacementGeneration = try Group.loadFromStorage(provider: pair.aliceProvider, cid: cid)
        let replacementCiphertext = try replacementGeneration.createMessage(
            provider: pair.aliceProvider,
            sender: pair.alice,
            plaintext: plaintext
        )
        try replacementGeneration.saveState(provider: pair.aliceProvider)

        let processed = try pair.bobGroup.processMessage(
            provider: pair.bobProvider,
            msg: replacementCiphertext
        )
        XCTAssertEqual(processed.content, plaintext)
    }

    func testOutgoingCrashAfterProviderSaveBeforeIntentCanSendLaterGeneration() throws {
        let cid = "team:project:outgoing-after-provider-save"
        let pair = try makeGroupPair(cid: cid)

        let abandonedGeneration = try Group.loadFromStorage(provider: pair.aliceProvider, cid: cid)
        _ = try abandonedGeneration.createMessage(
            provider: pair.aliceProvider,
            sender: pair.alice,
            plaintext: Data("not posted".utf8)
        )
        try abandonedGeneration.saveState(provider: pair.aliceProvider)
        // Simulate termination before the exact ciphertext is committed to Core Data. The next
        // launch must create a later sender generation; it must never POST unknown bytes.

        let replacementGeneration = try Group.loadFromStorage(provider: pair.aliceProvider, cid: cid)
        let replacementPlaintext = Data("durable replacement".utf8)
        let replacementCiphertext = try replacementGeneration.createMessage(
            provider: pair.aliceProvider,
            sender: pair.alice,
            plaintext: replacementPlaintext
        )
        try replacementGeneration.saveState(provider: pair.aliceProvider)

        // The receiver can advance over the abandoned sender generation and decrypt the exact
        // replacement intent that will be persisted before POST.
        let processed = try pair.bobGroup.processMessage(
            provider: pair.bobProvider,
            msg: replacementCiphertext
        )
        XCTAssertEqual(processed.content, replacementPlaintext)
    }

    func testClearPendingProposalCallsProposalApi() throws {
        let provider = Provider()
        let identity = try Identity(provider: provider, userId: "alice")
        let bobProvider = Provider()
        let bob = try Identity(provider: bobProvider, userId: "bob")
        let cid = try ChannelId(cid: "team:project:proposal-test")
        let group = try Group.createWithCid(
            provider: provider,
            founder: identity,
            cid: cid.rawValue
        )
        _ = try group.proposeAddMember(
            provider: provider,
            sender: identity,
            newMember: bob.keyPackage(provider: bobProvider)
        )
        XCTAssertEqual(group.pendingProposalsCount(), 1)

        let client = MlsClient()
        client.provider = provider
        client.identity = identity
        client.userId = "alice"
        try client.clearPendingProposal(in: cid)

        let reloaded = try Group.loadFromStorage(provider: provider, cid: cid.rawValue)
        XCTAssertEqual(reloaded.pendingProposalsCount(), 0)
        XCTAssertFalse(reloaded.hasPendingCommit())
    }

    func testClearPendingProposalsKeepsPendingCommit() throws {
        let provider = Provider()
        let identity = try Identity(provider: provider, userId: "alice")
        let cid = try ChannelId(cid: "team:project:pending-commit-test")
        let group = try Group.createWithCid(
            provider: provider,
            founder: identity,
            cid: cid.rawValue
        )
        _ = try group.selfUpdate(provider: provider, sender: identity)
        XCTAssertTrue(group.hasPendingCommit())

        let client = MlsClient()
        client.provider = provider
        client.identity = identity
        client.userId = "alice"
        try client.clearPendingProposal(in: cid)

        let reloaded = try Group.loadFromStorage(provider: provider, cid: cid.rawValue)
        XCTAssertTrue(reloaded.hasPendingCommit())
        XCTAssertEqual(reloaded.pendingProposalsCount(), 0)
    }

    func testClearPendingCommitKeepsPendingProposals() throws {
        let provider = Provider()
        let identity = try Identity(provider: provider, userId: "alice")
        let bobProvider = Provider()
        let bob = try Identity(provider: bobProvider, userId: "bob")
        let cid = try ChannelId(cid: "team:project:pending-proposal-test")
        let group = try Group.createWithCid(
            provider: provider,
            founder: identity,
            cid: cid.rawValue
        )
        _ = try group.proposeAddMember(
            provider: provider,
            sender: identity,
            newMember: bob.keyPackage(provider: bobProvider)
        )
        XCTAssertEqual(group.pendingProposalsCount(), 1)

        let client = MlsClient()
        client.provider = provider
        client.identity = identity
        client.userId = "alice"
        try client.clearPendingCommit(in: cid)

        let reloaded = try Group.loadFromStorage(provider: provider, cid: cid.rawValue)
        XCTAssertEqual(reloaded.pendingProposalsCount(), 1)
        XCTAssertFalse(reloaded.hasPendingCommit())
    }

    func testAADMatchesWebVectorAndCanonicalUUIDOrder() throws {
        let firstId = "00000000-0000-0000-0000-0000000000ff"
        let secondId = "00000000-0000-0000-0000-000000000001"
        let aad = E2eeMessageAADV1(
            cid: "messaging:dest",
            e2eeGroupId: "messaging:dest",
            messageId: "11111111-1111-4111-8111-111111111111",
            forwardCid: "messaging:source",
            forwardMessageId: "22222222-2222-4222-8222-222222222222",
            forwardParentCid: "team:parent",
            attachmentIds: [firstId, secondId]
        )

        XCTAssertEqual(
            try E2eeMessageAADV1.canonicalAttachmentIds([firstId, secondId]),
            [secondId, firstId]
        )
        XCTAssertEqual(
            SHA256.hash(data: try aad.encoded()).map { String(format: "%02x", $0) }.joined(),
            "10478e38376e07f02e5f7618355d21fa30fe70fe8a826505269705565d910fac"
        )
    }

    func testAADRejectsDuplicateAttachmentIds() {
        let duplicate = "00000000-0000-0000-0000-000000000001"
        XCTAssertThrowsError(
            try E2eeMessageAADV1(
                cid: "messaging:dest",
                e2eeGroupId: "messaging:dest",
                messageId: "11111111-1111-4111-8111-111111111111",
                attachmentIds: [duplicate, duplicate]
            ).encoded()
        ) {
            guard case E2eeMessageAADError.duplicateAttachmentId = $0 else {
                return XCTFail("Expected duplicateAttachmentId, got \($0)")
            }
        }
    }

    func testTextOnlyForwardRequiresAADWithEmptyAttachmentList() throws {
        let aad = E2eeMessageAADV1(
            cid: "messaging:dest",
            e2eeGroupId: "messaging:dest",
            messageId: "11111111-1111-4111-8111-111111111111",
            forwardCid: "messaging:source",
            forwardMessageId: "22222222-2222-4222-8222-222222222222"
        )
        XCTAssertTrue(aad.isRequired)
        XCTAssertFalse(try aad.encoded().isEmpty)
    }

    func testLegacyNoAADLaneRejectsForwardAndAttachmentMetadata() {
        let user = UserRequestBody(id: "user-1", name: nil, imageURL: nil)
        let plainText = MessageRequestBody(id: "message-1", user: user, text: "hello")
        let forward = MessageRequestBody(
            id: "message-2",
            user: user,
            text: "hello",
            forwardCid: "messaging:source",
            forwardMessageId: "source-message"
        )
        let attachment = MessageRequestBody(
            id: "message-3",
            user: user,
            text: "",
            attachments: [MessageAttachmentPayload(type: .file, payload: .dictionary([:]))]
        )

        XCTAssertFalse(plainText.requiresE2eeAuthenticatedSendLane)
        XCTAssertTrue(forward.requiresE2eeAuthenticatedSendLane)
        XCTAssertTrue(attachment.requiresE2eeAuthenticatedSendLane)
    }

    func testConstantTimeAADComparison() {
        XCTAssertTrue(E2eeMessageAADV1.constantTimeEqual(Data([1, 2, 3]), Data([1, 2, 3])))
        XCTAssertFalse(E2eeMessageAADV1.constantTimeEqual(Data([1, 2, 3]), Data([1, 2, 4])))
        XCTAssertFalse(E2eeMessageAADV1.constantTimeEqual(Data([1, 2]), Data([1, 2, 0])))
    }
}
