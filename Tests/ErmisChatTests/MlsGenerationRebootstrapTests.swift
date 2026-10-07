//
// Copyright 2026 Ermis Inc.
//

import Foundation
import XCTest
import open_mls_ios
@testable import ErmisChat

final class MlsGenerationRebootstrapTests: XCTestCase {
    func testGenerationContractDecodesFixedCapabilityAndBinaryIdentity() throws {
        let data = Data(#"""
        {
          "group_generation":2,
          "group_id":"AQIDBA==",
          "current_epoch":1,
          "membership_version":"membership-v2",
          "state":"activated",
          "reason":"delivery_pending",
          "retryable":true,
          "first_unresolved_at":null,
          "incident_deadline_at":null,
          "capability":{
            "protocol_version":1,
            "automatic_enabled":true,
            "repair_timeout_seconds":900,
            "max_group_info_bytes":1048576,
            "max_ratchet_tree_bytes":1048576,
            "max_welcome_recipients":200,
            "max_welcome_bytes":6291456
          }
        }
        """#.utf8)
        let state = try JSONDecoder.ermis.decode(MlsGenerationStatePayload.self, from: data)

        XCTAssertEqual(state.groupGeneration, 2)
        XCTAssertEqual(state.groupId, [1, 2, 3, 4])
        XCTAssertEqual(state.state, .activated)
        XCTAssertEqual(state.capability.protocolVersion, 1)
        XCTAssertEqual(state.capability.repairTimeoutSeconds, 15 * 60)
        XCTAssertEqual(state.capability.maxWelcomeRecipients, 200)
    }

    func testTypedFailureAndOldServerRouteMapToDistinctReadiness() throws {
        let typedData = Data(#"""
        {
          "ermis_code":1,
          "message":"MLS generation recovery request could not proceed",
          "state":"eligible",
          "reason":"lease_unavailable",
          "retryable":true,
          "expected_generation":0,
          "current_generation":0,
          "current_epoch":9,
          "operation_key":"00000000-0000-0000-0000-000000000001"
        }
        """#.utf8)
        let payload = try JSONDecoder.ermis.decode(ErmisErrorPayload.self, from: typedData)
        let typed = ErmisApiError(payload: payload, httpStatusCode: 409)
        XCTAssertEqual(typed.mlsRebootstrapState, .eligible)
        XCTAssertEqual(typed.mlsRebootstrapReason, .leaseUnavailable)
        XCTAssertEqual(typed.mlsRebootstrapRetryable, true)
        XCTAssertEqual(E2eeMlsRebootstrapFailureClassifier.readiness(for: typed), .waitingForRepair)

        let oldServer = ErmisApiError(type: .unknown, statusCode: 404, message: "Not found")
        XCTAssertEqual(
            E2eeMlsRebootstrapFailureClassifier.readiness(for: oldServer),
            .clientUpgradeRequired
        )
        XCTAssertEqual(
            E2eeMlsRebootstrapFailureClassifier.readiness(for: URLError(.notConnectedToInternet)),
            .infrastructureRetryable
        )
    }

    func testClaimIntentSurvivesRestartAndReusesOperationKeyOnlyForSameBoundary() throws {
        let stateData = Data(#"""
        {
          "group_generation":0,
          "group_id":null,
          "current_epoch":9,
          "membership_version":"membership-v0",
          "state":"eligible",
          "reason":"repair_timeout_elapsed",
          "retryable":true,
          "first_unresolved_at":"2026-09-10T00:00:00Z",
          "incident_deadline_at":"2026-09-10T00:15:00Z",
          "capability":{
            "protocol_version":1,
            "automatic_enabled":true,
            "repair_timeout_seconds":900,
            "max_group_info_bytes":1048576,
            "max_ratchet_tree_bytes":1048576,
            "max_welcome_recipients":200,
            "max_welcome_bytes":6291456
          }
        }
        """#.utf8)
        let state = try JSONDecoder.ermis.decode(MlsGenerationStatePayload.self, from: stateData)
        let intent = E2eeMlsRebootstrapClaimIntent(
            cid: "messaging:stable-cid",
            operationKey: UUID().uuidString.lowercased(),
            expectedGeneration: 0,
            expectedEpoch: 9,
            protocolVersion: 1
        )
        let restarted = try JSONDecoder().decode(
            E2eeMlsRebootstrapClaimIntent.self,
            from: JSONEncoder().encode(intent)
        )

        XCTAssertEqual(restarted.operationKey, intent.operationKey)
        XCTAssertTrue(restarted.matches(cid: intent.cid, state: state))
        XCTAssertFalse(restarted.matches(cid: "messaging:other", state: state))

        let stateJSON = try XCTUnwrap(String(data: stateData, encoding: .utf8))
        let advancedData = Data(stateJSON
            .replacingOccurrences(of: "\"group_generation\":0", with: "\"group_generation\":1")
            .utf8)
        let advanced = try JSONDecoder.ermis.decode(MlsGenerationStatePayload.self, from: advancedData)
        XCTAssertFalse(restarted.matches(cid: intent.cid, state: advanced))
    }

    func testCompleteBodyRoundTripsBinaryArtifactsWithoutArrayWireFallback() throws {
        let body = CompleteMlsRebootstrapRequestBody(
            operationId: UUID().uuidString,
            operationKey: UUID().uuidString,
            leaseToken: UUID().uuidString,
            expectedGeneration: 0,
            expectedEpoch: 42,
            newGeneration: 1,
            newEpoch: 1,
            membershipVersion: "membership-v1",
            groupId: [0, 1, 2, 255],
            groupInfo: [3, 4, 5],
            ratchetTree: [6, 7],
            welcome: [8, 9],
            recipients: [
                .init(userId: "bob", deviceId: "ios-b", keyPackageId: UUID().uuidString)
            ]
        )

        let encoded = try JSONEncoder.ermis.encode(body)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(object["group_id"] as? String, "AAEC/w==")
        XCTAssertEqual(object["welcome"] as? String, "CAk=")
        XCTAssertEqual(try JSONDecoder.ermis.decode(
            CompleteMlsRebootstrapRequestBody.self,
            from: encoded
        ), body)
    }

    func testApplicationWireAndDurableSendIntentCarryGroupGeneration() throws {
        let application = Data(#"""
        {
          "id":"message-1",
          "cid":"messaging:stable-cid",
          "type":"regular",
          "content_type":"mls",
          "mls_ciphertext":"AQID",
          "mls_epoch":7,
          "group_generation":2,
          "created_at":"2026-09-10T00:00:00.000Z",
          "e2ee_attachment_ids":[]
        }
        """#.utf8)
        let decoded = try JSONDecoder.ermis.decode(E2eSyncApplicationData.self, from: application)
        XCTAssertEqual(decoded.groupGeneration, 2)

        var request = MessageRequestBody(
            id: UUID().uuidString,
            user: UserRequestBody(id: "alice", name: nil, imageURL: nil),
            text: "encrypted"
        )
        request.bindE2eeNetworkIntent(ciphertext: [1, 2, 3], epoch: 7, groupGeneration: 2)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder.default.encode(request)) as? [String: Any]
        )
        XCTAssertEqual(object["group_generation"] as? Int, 2)
        XCTAssertEqual(object["mls_epoch"] as? Int, 7)
    }

    func testCandidateUsesExplicitGroupIdAndSurvivesProviderRestart() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mls-rebootstrap-" + UUID().uuidString, isDirectory: true)
        let suite = "mls-rebootstrap-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let groupId = Data((0..<32).map(UInt8.init))
        let operationId = UUID().uuidString.lowercased()
        let client = MlsClient(storageFolderURL: root, userDefaults: defaults)
        try client.setup(with: "alice")

        let candidate = try client.prepareRebootstrapCandidate(
            operationId: operationId,
            groupId: groupId,
            keyPackages: []
        )
        XCTAssertEqual(candidate.groupId, groupId)
        XCTAssertEqual(candidate.epoch, 0)
        XCTAssertNil(candidate.welcome)
        try client.activateRebootstrapCandidate(
            cid: "messaging:stable-cid",
            generation: 1,
            operationId: operationId,
            candidate: candidate
        )
        try client.reset()

        let restarted = MlsClient(storageFolderURL: root, userDefaults: defaults)
        try restarted.setup(with: "alice")
        let loaded = try restarted.loadGroup(
            cid: "messaging:stable-cid",
            generation: 1,
            groupId: groupId
        )
        XCTAssertEqual(loaded.groupId(), groupId)
        XCTAssertEqual(loaded.epoch(), 0)
        XCTAssertTrue(loaded.isOperational())
    }

    func testOneBootstrapAddProducesOneWelcomeForRecipientProvider() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mls-rebootstrap-" + UUID().uuidString, isDirectory: true)
        let suite = "mls-rebootstrap-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let recipientProvider = Provider()
        let recipient = try Identity(provider: recipientProvider, userId: "bob")
        let keyPackage = recipient.keyPackage(provider: recipientProvider).toBytes()
        let client = MlsClient(storageFolderURL: root, userDefaults: defaults)
        try client.setup(with: "alice")

        let candidate = try client.prepareRebootstrapCandidate(
            operationId: UUID().uuidString.lowercased(),
            groupId: Data(UUID().uuidString.utf8),
            keyPackages: [keyPackage]
        )
        let welcome = try XCTUnwrap(candidate.welcome)
        let tree = try RatchetTree.fromBytes(data: candidate.ratchetTree)
        let joined = try Group.joinWithWelcome(
            provider: recipientProvider,
            welcome: welcome,
            ratchetTree: tree
        )

        XCTAssertEqual(candidate.epoch, 1)
        XCTAssertEqual(joined.groupId(), candidate.groupId)
        XCTAssertEqual(joined.epoch(), candidate.epoch)
    }

    func testLinkedArchiveArtifactRestoresHistoricalGenerationAndRejectsTamperedSnapshot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mls-archive-generation-" + UUID().uuidString, isDirectory: true)
        let suite = "mls-archive-generation-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        let client = MlsClient(storageFolderURL: root, userDefaults: defaults)
        try client.setup(with: "bob")
        let bobProvider = try XCTUnwrap(client.provider)
        let bob = try XCTUnwrap(client.identity)
        let aliceProvider = Provider()
        let alice = try Identity(provider: aliceProvider, userId: "alice")
        let generationOneGroupId = Data("generation-one-group-id".utf8)
        let aliceGroup = try Group.createWithGroupId(
            provider: aliceProvider,
            founder: alice,
            groupId: generationOneGroupId
        )
        let add = try aliceGroup.addMembers(
            provider: aliceProvider,
            sender: alice,
            newMembers: [bob.keyPackage(provider: bobProvider)]
        )
        try aliceGroup.mergePendingCommit(provider: aliceProvider)
        let bobGroup = try Group.joinWithWelcome(
            provider: bobProvider,
            welcome: try XCTUnwrap(add.welcome),
            ratchetTree: aliceGroup.exportRatchetTree()
        )
        try bobGroup.saveState(provider: bobProvider)

        let cid = "messaging:stable-archive-cid"
        try client.saveGenerationMarker(
            .init(
                cid: cid,
                generation: 1,
                groupId: generationOneGroupId,
                epoch: bobGroup.epoch(),
                status: "active",
                operationId: UUID().uuidString.lowercased()
            )
        )
        let exported = try client.exportEpochArchive(of: bobGroup)
        let payload = E2ePayload(text: "historical generation", attachments: [], stickerUrl: nil)
        let ciphertext = try aliceGroup.createMessage(
            provider: aliceProvider,
            sender: alice,
            plaintext: JSONEncoder().encode(payload)
        )

        try client.saveGenerationMarker(
            .init(
                cid: cid,
                generation: 2,
                groupId: Data("generation-two-group-id".utf8),
                epoch: 0,
                status: "active",
                operationId: UUID().uuidString.lowercased()
            )
        )
        XCTAssertEqual(client.loadGenerationMarker(cid: cid)?.generation, 2)
        XCTAssertEqual(client.loadGenerationMarker(cid: cid, generation: 1)?.groupId, generationOneGroupId)

        let restored = try client.decryptArchivedApplication(
            cid: cid,
            generation: 1,
            archive: exported.archiveBytes,
            snapshot: exported.snapshotBytes,
            ciphertext: ciphertext
        )
        XCTAssertEqual(restored.payload, payload)
        XCTAssertEqual(restored.epoch, bobGroup.epoch())
        XCTAssertFalse(restored.ownMessage)

        var tamperedSnapshot = exported.snapshotBytes
        tamperedSnapshot[0] ^= 1
        XCTAssertThrowsError(
            try client.decryptArchivedApplication(
                cid: cid,
                generation: 1,
                archive: exported.archiveBytes,
                snapshot: tamperedSnapshot,
                ciphertext: ciphertext
            )
        )
    }
}
