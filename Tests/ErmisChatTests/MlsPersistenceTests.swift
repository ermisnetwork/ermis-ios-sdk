import XCTest
@testable import ErmisChat
import open_mls_ios
import CryptoKit

final class MlsPersistenceTests: XCTestCase {
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

        let client = MlsClient(storageFolderURL: root, applicationGroupIdentifier: suite)
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

        let client = MlsClient(storageFolderURL: root, applicationGroupIdentifier: suite)
        try client.setup(with: "alice")
        XCTAssertNotNil(client.currentDeviceId)

        try client.purgeCurrentUserData()

        let deviceIds = defaults.dictionary(forKey: MlsClient.deviceIdKey) as? [String: String]
        XCTAssertNil(deviceIds?["alice"])
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
        ) {
            guard case MlsError.InvalidMessage = $0 else {
                return XCTFail("Expected InvalidMessage, got \($0)")
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

        let processed = try pair.bobGroup.processMessage(
            provider: pair.bobProvider,
            msg: commit.commit
        )
        XCTAssertEqual(processed.messageType, .commit)
        XCTAssertEqual(pair.bobGroup.epoch(), startingEpoch + 1)

        try pair.bobGroup.saveState(provider: pair.bobProvider)
        let reloaded = try Group.loadFromStorage(provider: pair.bobProvider, cid: cid)
        XCTAssertEqual(reloaded.epoch(), startingEpoch + 1)
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
