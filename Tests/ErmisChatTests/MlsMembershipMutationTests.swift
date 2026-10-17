import XCTest
@testable import ErmisChat
import open_mls_ios
import CryptoKit
import CoreData

/// Actual native groups and disk provider. The sender seam injects transport outcomes only.
final class MlsMembershipMutationTests: XCTestCase {
    private final class SecureStore: MlsDeviceIdSecureStoring {
        var values: [UserId: String] = [:]
        func load(userId: UserId) throws -> String? { values[userId] }
        func save(deviceId: String, userId: UserId) throws { values[userId] = deviceId }
        func remove(userId: UserId) throws { values.removeValue(forKey: userId) }
    }
    private final class ProcessDeviceIdStore: MlsDeviceIdSecureStoring {
        let defaults: UserDefaults
        init(_ defaults: UserDefaults) { self.defaults = defaults }
        func load(userId: UserId) throws -> String? { defaults.string(forKey: "device-\(userId)") }
        func save(deviceId: String, userId: UserId) throws {
            defaults.set(deviceId, forKey: "device-\(userId)"); defaults.synchronize()
        }
        func remove(userId: UserId) throws { defaults.removeObject(forKey: "device-\(userId)") }
    }
    private struct Fixture {
        let client: MlsClient
        let repository: E2eRepository
        let database: DatabaseContainer
        let root: URL
        let defaults: UserDefaults
        let deviceStore: MlsDeviceIdStore
        let cid: ChannelId
        let peerProvider: Provider
        let peerIdentity: Identity
        let peerGroup: Group
    }
    private func makeClient(root: URL, defaults: UserDefaults, store: MlsDeviceIdStore) throws -> MlsClient {
        let client = MlsClient(storageFolderURL: root, deviceIdStore: store, userDefaults: defaults)
        try client.setup(with: "admin")
        return client
    }
    private func makeRepository(_ client: MlsClient, database: DatabaseContainer) throws -> E2eRepository {
        let base = try XCTUnwrap(URL(string: "https://example.invalid"))
        let encoder = DefaultRequestEncoder(baseURL: base, authURL: base, stickerURL: base, apiKey: APIKey("fixture"))
        let decoder = DefaultRequestDecoder()
        let configuration = URLSessionConfiguration.ephemeral
        let api = APIClient(sessionConfiguration: configuration, requestEncoder: encoder, requestDecoder: decoder,
            uploader: ErmisUploader(uploadClient: ErmisUploadClient(encoder: encoder, decoder: decoder, sessionConfiguration: configuration)),
            downloader: ErmisDownloader(client: ErmisDownloadClient(sessionConfiguration: configuration)))
        return E2eRepository(database: database, eventNotificationCenter: EventNotificationCenter(database: database), mlsClient: client, apiClient: api)
    }
    private func fixture(size: Int = 4, _ body: (Fixture) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("membership-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "membership-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MlsDeviceIdStore(defaults: defaults, legacyDefaults: defaults, secureStore: SecureStore())
        let client = try makeClient(root: root, defaults: defaults, store: store)
        let provider = try XCTUnwrap(client.provider)
        let identity = try XCTUnwrap(client.identity)
        let cid = try ChannelId(cid: "team:project:\(UUID().uuidString)")
        let group = try Group.createWithCid(provider: provider, founder: identity, cid: cid.rawValue)
        let users = ["ios", "ios", "ghost", "target"] + (4..<max(4, size)).map { "user-\($0)" }
        let providers = users.map { _ in Provider() }
        let identities = try zip(users, providers).map { try Identity(provider: $0.1, userId: $0.0) }
        let keys = try zip(identities, providers).map {
            try $0.0.keyPackage(provider: $0.1)
        }
        let initial = try group.addMembers(provider: provider, sender: identity, newMembers: keys)
        try group.mergePendingCommit(provider: provider)
        try group.saveState(provider: provider)
        let peerGroup = try Group.joinWithWelcome(provider: providers[3], welcome: XCTUnwrap(initial.welcome), ratchetTree: group.exportRatchetTree())
        XCTAssertEqual(peerGroup.members().first(where: { $0.index == peerGroup.ownLeafIndex() })?.userId, "target")
        let database = DatabaseContainer(kind: .inMemory, shouldResetEphemeralValuesOnStart: false)
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !database.persistentStoreCoordinator.persistentStores.isEmpty
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 5), .completed)
        let repository = try makeRepository(client, database: database)
        try database.writeAndWait { session in
            session.savePendingRemoveMember(userId: "ghost", channelCid: cid.rawValue)
            session.savePendingRemoveMember(userId: "ios", channelCid: cid.rawValue)
        }
        try body(Fixture(client: client, repository: repository, database: database, root: root, defaults: defaults, deviceStore: store, cid: cid,
                         peerProvider: providers[3], peerIdentity: identities[3], peerGroup: peerGroup))
    }
    private func stage(_ f: Fixture) throws -> MlsMembershipMutation {
        try f.repository.prepareMembershipRemove(cid: f.cid, targets: ["target"], ghosts: ["ghost"])
        return try XCTUnwrap(f.client.membershipMutationStore().load(cid: f.cid.rawValue))
    }
    func testDelayedRemovalTombstonePreservesReaddedNativeGroupAndPendingInbox() throws {
        for role in [MemberRole.member, .pending] {
            try fixture { f in
                let memberJSON = """
                {"user_id":"admin","channel_role":"\(role.rawValue)","created_at":"1970-01-01T00:16:41.000Z","user":{"id":"admin","name":"admin"}}
                """
                let member = try JSONDecoder.default.decode(MemberPayload.self, from: Data(memberJSON.utf8))
                try f.database.writeAndWait { session in
                    let context = try XCTUnwrap(session as? NSManagedObjectContext)
                    let channel = ChannelDTO.loadOrCreate(cid: f.cid, context: context, cache: nil)
                    channel.createdAt = Date(timeIntervalSince1970: 999).bridgeDate
                    channel.updatedAt = Date(timeIntervalSince1970: 1_001).bridgeDate
                    channel.mlsEnabled = true
                    let saved = try session.saveMember(payload: member, channelId: f.cid)
                    channel.members.insert(saved)
                    channel.membership = saved
                    channel.mlsGroupJoinedAt = Date(timeIntervalSince1970: 999).bridgeDate
                }
                let eventId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
                let eventJSON = """
                {"event_id":"\(eventId)","created_at":"1970-01-01T00:16:41.000Z","type":"future_event","data":{"value":1}}
                """
                let event = try JSONDecoder.default.decode(E2eSyncEventEnvelope.self, from: Data(eventJSON.utf8))
                let store = E2eeDurableInboxStore(database: f.database)
                let cursor = ScopeSyncCursorPayload(createdAt: event.createdAtRaw, eventId: eventId)
                _ = try store.persistPage(accountId: "admin", scopeCid: f.cid.rawValue, events: [event], hasMore: false, nextCursor: cursor)
                let removedJSON = """
                {"events":[{"cid":"\(f.cid.rawValue)","event_id":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","removed_at":"1970-01-01T00:16:40.000Z","removal_type":"self_remove","self_remove":true}],"has_more":false,"next_cursor":{"removed_at":"1970-01-01T00:33:20.000Z","event_id":"cccccccc-cccc-4ccc-8ccc-cccccccccccc"}}
                """
                let removed = try JSONDecoder.default.decode(RemovedChannelsPayload.self, from: Data(removedJSON.utf8))
                let done = expectation(description: "Delayed removal tombstone processed")
                f.repository.handleRemovedChannels(removed) { result in
                    if case .failure(let error) = result { XCTFail("Unexpected removal failure: \(type(of: error))") }
                    done.fulfill()
                }
                wait(for: [done], timeout: 5)
                XCTAssertTrue(f.client.isGroupLoaded(cid: f.cid.rawValue), "New active/pending membership must protect the current native group")
                if let group = try? f.client.loadGroup(with: f.cid.rawValue) {
                    XCTAssertTrue(group.isOperational())
                    XCTAssertEqual(group.membersByUserId(userId: "ios").count, 2)
                }
                XCTAssertEqual(try store.fetchCursor(accountId: "admin", scopeCid: f.cid.rawValue), cursor)
                XCTAssertEqual(try store.loadPendingEvents(accountId: "admin", scopeCid: f.cid.rawValue).map(\.eventId), [eventId])
                XCTAssertEqual(try store.removedCursor(accountId: "admin"), removed.nextCursor)
            }
        }
    }
    func testCurrentRemovalPersistsOwnScopeBoundaryInsteadOfWallClockOrGlobalTail() throws {
        try fixture { f in
            let removedAt = "2026-08-06T10:01:00.123456789Z"
            let json = """
            {"events":[{"cid":"\(f.cid.rawValue)","event_id":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","removed_at":"\(removedAt)","removal_type":"self_remove","self_remove":true}],"has_more":false,"next_cursor":{"removed_at":"2026-08-06T11:00:00.987654321Z","event_id":"cccccccc-cccc-4ccc-8ccc-cccccccccccc"}}
            """
            let removed = try JSONDecoder.default.decode(RemovedChannelsPayload.self, from: Data(json.utf8))
            let done = expectation(description: "Current removal applied")
            f.repository.handleRemovedChannels(removed) { result in
                if case .failure(let error) = result { XCTFail("Unexpected removal failure: \(type(of: error))") }
                done.fulfill()
            }
            wait(for: [done], timeout: 5)
            XCTAssertFalse(f.client.isGroupLoaded(cid: f.cid.rawValue))
            let store = E2eeDurableInboxStore(database: f.database)
            let boundary = ScopeSyncCursorPayload(createdAt: removedAt, eventId: "00000000-0000-0000-0000-000000000000")
            XCTAssertEqual(try store.fetchCursor(accountId: "admin", scopeCid: f.cid.rawValue), boundary)
            XCTAssertEqual(try store.applyCursor(accountId: "admin", scopeCid: f.cid.rawValue), boundary)
            XCTAssertEqual(try store.removedCursor(accountId: "admin"), removed.nextCursor)
        }
    }
    func testAdminCompositeRetainsBothActiveIosLeavesAndAdvancesOnlyAfterAck() throws {
        try fixture { f in
            let record = try stage(f)
            XCTAssertEqual(Set(f.repository.getPendingRemoveMemberUserIds(channelCid: f.cid.rawValue)), ["ghost", "ios"])
            XCTAssertEqual(try f.client.loadGroup(with: f.cid.rawValue).epoch(), UInt64(record.epoch))
            XCTAssertEqual(f.repository.readiness(for: f.cid), .needsRetry)
            f.repository.membershipMutationSender = { _, settle in settle(nil) }
            let done = expectation(description: "ACK merged")
            XCTAssertTrue(try f.repository.resumeMembershipMutation(cid: f.cid) { error in
                XCTAssertNil(error); done.fulfill()
            })
            wait(for: [done], timeout: 5)
            let group = try f.client.loadGroup(with: f.cid.rawValue)
            XCTAssertEqual(group.epoch(), UInt64(record.epoch + 1))
            XCTAssertEqual(group.membersByUserId(userId: "ios").count, 2)
            XCTAssertTrue(group.membersByUserId(userId: "ghost").isEmpty)
            XCTAssertEqual(f.repository.getPendingRemoveMemberUserIds(channelCid: f.cid.rawValue), ["ios"])
            XCTAssertNil(try f.client.membershipMutationStore().load(cid: f.cid.rawValue))
        }
    }
    func testNetworkFailureAndProviderReopenResumeIdenticalArtifact() throws {
        try fixture { f in
            let record = try stage(f)
            f.repository.membershipMutationSender = { _, settle in settle(NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)) }
            let failed = expectation(description: "network failure")
            try f.repository.resumeMembershipMutation(cid: f.cid) { error in XCTAssertNotNil(error); failed.fulfill() }
            wait(for: [failed], timeout: 5)
            XCTAssertTrue(f.repository.getPendingRemoveMemberUserIds(channelCid: f.cid.rawValue).contains("ghost"))
            let reopened = try makeClient(root: f.root, defaults: f.defaults, store: f.deviceStore)
            let repository = try makeRepository(reopened, database: f.database)
            repository.membershipMutationSender = { retry, settle in
                XCTAssertEqual(retry.commit, record.commit)
                XCTAssertEqual(retry.groupInfo, record.groupInfo)
                XCTAssertEqual(retry.epoch, record.epoch)
                XCTAssertEqual(retry.targets, record.targets)
                settle(nil)
            }
            let done = expectation(description: "retry merged")
            try repository.resumeMembershipMutation(cid: f.cid) { error in XCTAssertNil(error); done.fulfill() }
            wait(for: [done], timeout: 5)
            XCTAssertEqual(try reopened.loadGroup(with: f.cid.rawValue).epoch(), UInt64(record.epoch + 1))
        }
    }
    func testServerRejectAndTransitionPendingRetainArtifactAndActiveLeaves() throws {
        try fixture { f in
            let record = try stage(f)
            for (status, message) in [(400, "mls_transition_pending: retry later"), (403, "permission_denied")] {
                f.repository.membershipMutationSender = { retry, settle in
                    XCTAssertEqual(retry.commit, record.commit)
                    settle(ErmisApiError(type: .inputNotCorrect, statusCode: status, message: message))
                }
                let rejected = expectation(description: "server reject retained")
                try f.repository.resumeMembershipMutation(cid: f.cid) { error in
                    XCTAssertNotNil(error); rejected.fulfill()
                }
                wait(for: [rejected], timeout: 5)
                let retained = try XCTUnwrap(f.client.membershipMutationStore().load(cid: f.cid.rawValue))
                XCTAssertEqual(retained.commit, record.commit)
                XCTAssertFalse(retained.acknowledged)
                XCTAssertNotEqual(retained.needsEpochSync, true)
                XCTAssertEqual(try f.client.loadGroup(with: f.cid.rawValue).epoch(), UInt64(record.epoch))
                XCTAssertEqual(try f.client.loadGroup(with: f.cid.rawValue).membersByUserId(userId: "ios").count, 2)
                XCTAssertTrue(f.repository.getPendingRemoveMemberUserIds(channelCid: f.cid.rawValue).contains("ghost"))
            }
            f.repository.membershipMutationSender = { retry, settle in
                XCTAssertEqual(retry.commit, record.commit); settle(nil)
            }
            let accepted = expectation(description: "same artifact accepted")
            try f.repository.resumeMembershipMutation(cid: f.cid) { error in
                XCTAssertNil(error); accepted.fulfill()
            }
            wait(for: [accepted], timeout: 5)
            XCTAssertEqual(try f.client.loadGroup(with: f.cid.rawValue).epoch(), UInt64(record.epoch + 1))
            XCTAssertEqual(try f.client.loadGroup(with: f.cid.rawValue).membersByUserId(userId: "ios").count, 2)
        }
    }

    func testAckBeforeMergeRestartFinishesWithoutAnotherRequest() throws {
        try fixture { f in
            let record = try stage(f)
            f.repository.membershipMutationStageHook = { stage in
                if stage == "acknowledged" { throw NSError(domain: "InjectedProcessBoundary", code: 1) }
            }
            f.repository.membershipMutationSender = { _, settle in settle(nil) }
            let stopped = expectation(description: "ACK persisted")
            try f.repository.resumeMembershipMutation(cid: f.cid) { error in XCTAssertNotNil(error); stopped.fulfill() }
            wait(for: [stopped], timeout: 5)
            XCTAssertTrue(try XCTUnwrap(f.client.membershipMutationStore().load(cid: f.cid.rawValue)).acknowledged)
            XCTAssertTrue(f.repository.getPendingRemoveMemberUserIds(channelCid: f.cid.rawValue).contains("ghost"))
            let reopened = try makeClient(root: f.root, defaults: f.defaults, store: f.deviceStore)
            let repository = try makeRepository(reopened, database: f.database)
            repository.membershipMutationSender = { _, _ in XCTFail("Already ACKed artifact must not be sent again") }
            let done = expectation(description: "local merge after restart")
            try repository.resumeMembershipMutation(cid: f.cid) { error in XCTAssertNil(error); done.fulfill() }
            wait(for: [done], timeout: 5)
            XCTAssertEqual(try reopened.loadGroup(with: f.cid.rawValue).epoch(), UInt64(record.epoch + 1))
            XCTAssertNil(try reopened.membershipMutationStore().load(cid: f.cid.rawValue))
        }
    }
    func testCompositeReaddReplacesOldIosLeavesInOneEpoch() throws {
        try fixture { f in
            let provider = Provider()
            let identity = try Identity(provider: provider, userId: "ios")
            let key = try identity.keyPackage(provider: provider)
            let before = try f.client.loadGroup(with: f.cid.rawValue).epoch()
            try f.repository.prepareMembershipAdd(cid: f.cid, targets: ["ios"], ghosts: ["ios", "ghost"], keyPackages: [key])
            f.repository.membershipMutationSender = { _, settle in settle(nil) }
            let done = expectation(description: "composite readd")
            try f.repository.resumeMembershipMutation(cid: f.cid) { error in XCTAssertNil(error); done.fulfill() }
            wait(for: [done], timeout: 5)
            let group = try f.client.loadGroup(with: f.cid.rawValue)
            XCTAssertEqual(group.epoch(), before + 1)
            XCTAssertEqual(group.membersByUserId(userId: "ios").count, 1)
            XCTAssertTrue(group.isOperational())
        }
    }
    func testBoundedSmallAndLargeMutationCost() throws {
        for size in [4, 100] {
            try fixture(size: size) { f in
                let started = ProcessInfo.processInfo.systemUptime
                let record = try stage(f)
                let prepareMs = (ProcessInfo.processInfo.systemUptime - started) * 1000
                let mergeStarted = ProcessInfo.processInfo.systemUptime
                f.repository.membershipMutationSender = { _, settle in settle(nil) }
                let done = expectation(description: "measured ACK and merge")
                try f.repository.resumeMembershipMutation(cid: f.cid) { error in XCTAssertNil(error); done.fulfill() }
                wait(for: [done], timeout: 5)
                let mergeMs = (ProcessInfo.processInfo.systemUptime - mergeStarted) * 1000
                print("QA_MEMBERSHIP_COST users=\(size) leaves=\(size + 1) ghosts=1 prepare_lock_ms=\(prepareMs) ack_merge_ms=\(mergeMs) commit_bytes=\(record.commit.count) group_info_bytes=\(record.groupInfo.count)")
                XCTAssertEqual(try f.client.loadGroup(with: f.cid.rawValue).members().count, size - 1)
            }
        }
    }

    func testRestartDuringPreparationCannotLoseIntentOrSubmitOrphanCandidate() throws {
        try fixture { f in
            let before = try f.client.loadGroup(with: f.cid.rawValue).epoch()
            f.repository.membershipMutationStageHook = { stage in
                if stage == "native_prepared" { throw NSError(domain: "InjectedPreparationBoundary", code: 1) }
            }
            XCTAssertThrowsError(try stage(f))
            XCTAssertNil(try f.client.membershipMutationStore().load(cid: f.cid.rawValue))
            XCTAssertTrue(try f.client.membershipMutationStore().hasIntent(cid: f.cid.rawValue))
            let reopened = try makeClient(root: f.root, defaults: f.defaults, store: f.deviceStore)
            let repository = try makeRepository(reopened, database: f.database)
            // A different logical request must not consume the preparing intent.
            XCTAssertThrowsError(try repository.prepareMembershipRemove(cid: f.cid, targets: ["ios"], ghosts: []))
            try repository.prepareMembershipRemove(cid: f.cid, targets: ["target"], ghosts: ["ghost"])
            repository.membershipMutationSender = { _, settle in settle(nil) }
            let done = expectation(description: "same intent resumed")
            try repository.resumeMembershipMutation(cid: f.cid) { error in XCTAssertNil(error); done.fulfill() }
            wait(for: [done], timeout: 5)
            XCTAssertEqual(try reopened.loadGroup(with: f.cid.rawValue).epoch(), before + 1)
            XCTAssertEqual(try reopened.loadGroup(with: f.cid.rawValue).membersByUserId(userId: "ios").count, 2)
        }
    }

    func testEpochStaleKeepsCandidateUntilCanonicalWinnerThenRevalidatesSameIntent() throws {
        try fixture { f in
            let losing = try stage(f)
            f.repository.membershipMutationSender = { _, settle in
                settle(ErmisApiError(type: .inputNotCorrect, statusCode: 400, message: "epoch_stale: membership epoch"))
            }
            let rejected = expectation(description: "stale rejected")
            try f.repository.resumeMembershipMutation(cid: f.cid) { error in XCTAssertNotNil(error); rejected.fulfill() }
            wait(for: [rejected], timeout: 5)
            let store = try f.client.membershipMutationStore()
            XCTAssertEqual(try store.load(cid: f.cid.rawValue)?.needsEpochSync, true)
            XCTAssertEqual(try store.load(cid: f.cid.rawValue)?.commit, losing.commit)
            f.repository.membershipMutationSender = { _, _ in XCTFail("Stale artifact must wait for canonical sync") }
            try f.repository.resumeMembershipMutation(cid: f.cid) { XCTAssertNotNil($0) }
            XCTAssertTrue(f.repository.getPendingRemoveMemberUserIds(channelCid: f.cid.rawValue).contains("ghost"))

            let winner = try f.peerGroup.commitMemberRemovals(provider: f.peerProvider, sender: f.peerIdentity, removeUserIds: ["ghost"])
            try f.peerGroup.mergePendingCommit(provider: f.peerProvider)
            let epoch = losing.epoch + 1
            XCTAssertFalse(try f.repository.reconcileMembershipProtocolBeforeApply(cid: f.cid, epoch: epoch, commit: winner.commit))
            XCTAssertThrowsError(try f.repository.markMembershipCanonicalPersisted(cid: f.cid, epoch: epoch, commit: winner.commit))
            let group = try f.client.loadGroup(with: f.cid.rawValue)
            _ = try f.repository.persistCanonicalMembershipProtocol(cid: f.cid, group: group, epoch: epoch, commit: winner.commit)
            try f.repository.markMembershipCanonicalPersisted(cid: f.cid, epoch: epoch, commit: winner.commit)
            XCTAssertEqual(try store.load(cid: f.cid.rawValue)?.canRebase, true)
            XCTAssertEqual(group.membersByUserId(userId: "ios").count, 2)
            XCTAssertEqual(group.epoch(), UInt64(epoch))
            XCTAssertFalse(try f.repository.resumeMembershipMutation(cid: f.cid, action: "remove", targets: ["target"]) { _ in XCTFail("Caller must fetch fresh roster") })
            XCTAssertTrue(store.hasIntent(cid: f.cid.rawValue))
            // The caller's refreshed roster still contains target and both active iOS devices.
            try f.repository.prepareMembershipRemove(cid: f.cid, targets: ["target"], ghosts: [])
            f.repository.membershipMutationSender = { _, settle in settle(nil) }
            let accepted = expectation(description: "rebased mutation")
            try f.repository.resumeMembershipMutation(cid: f.cid) { error in XCTAssertNil(error); accepted.fulfill() }
            wait(for: [accepted], timeout: 5)
            XCTAssertEqual(try f.client.loadGroup(with: f.cid.rawValue).epoch(), UInt64(epoch + 1))
            XCTAssertEqual(try f.client.loadGroup(with: f.cid.rawValue).membersByUserId(userId: "ios").count, 2)
        }
    }

    func testLostAckThenStaleRetryReconcilesOwnCanonicalCommitOnce() throws {
        try fixture { f in
            let record = try stage(f)
            try f.repository.markMembershipEpochStale(cid: f.cid)
            XCTAssertTrue(try f.repository.reconcileMembershipProtocolBeforeApply(cid: f.cid, epoch: record.epoch + 1, commit: record.commit))
            XCTAssertNil(try f.client.membershipMutationStore().load(cid: f.cid.rawValue))
            XCTAssertFalse(try f.repository.reconcileMembershipProtocolBeforeApply(cid: f.cid, epoch: record.epoch + 1, commit: record.commit))
            XCTAssertEqual(try f.client.loadGroup(with: f.cid.rawValue).epoch(), UInt64(record.epoch + 1))
            XCTAssertEqual(try f.client.loadGroup(with: f.cid.rawValue).membersByUserId(userId: "ios").count, 2)
        }
    }

    /// Host-driven: terminate this process at READY, then launch the verify phase in a new process.
    func testMembershipCheckpointAcrossRealProcessKill() throws {
        let env = ProcessInfo.processInfo.environment
        guard let caseId = env["QA_MEMBERSHIP_PROCESS_CASE"], UUID(uuidString: caseId) != nil,
              let phase = env["QA_MEMBERSHIP_PROCESS_PHASE"],
              let killStage = env["QA_MEMBERSHIP_PROCESS_STAGE"], ["before_ack", "after_ack"].contains(killStage) else {
            throw XCTSkip("Requires the process-kill host runner")
        }
        let documents = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        let root = documents.appendingPathComponent("qa-membership-process-\(caseId)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "qa-membership-process-\(caseId)"))
        let deviceStore = MlsDeviceIdStore(defaults: defaults, legacyDefaults: defaults, secureStore: ProcessDeviceIdStore(defaults))
        let client = try makeClient(root: root, defaults: defaults, store: deviceStore)
        let cid = try ChannelId(cid: "team:project:\(caseId)")
        if phase == "prepare" {
            let provider = try XCTUnwrap(client.provider), identity = try XCTUnwrap(client.identity)
            let group = try Group.createWithCid(provider: provider, founder: identity, cid: cid.rawValue)
            let peer = Provider()
            let packages = try ["ios", "ios", "ghost", "target"].map {
                try Identity(provider: peer, userId: $0).keyPackage(provider: peer)
            }
            _ = try group.addMembers(provider: provider, sender: identity, newMembers: packages)
            try group.mergePendingCommit(provider: provider)
            try group.saveState(provider: provider)
        }
        let database = DatabaseContainer(kind: .onDisk(databaseFileURL: root.appendingPathComponent("membership.sqlite")),
                                         shouldResetEphemeralValuesOnStart: false)
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !database.persistentStoreCoordinator.persistentStores.isEmpty
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 5), .completed)
        let repository = try makeRepository(client, database: database)
        let store = try client.membershipMutationStore()
        func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        if phase == "prepare" {
            try database.writeAndWait { session in
                session.savePendingRemoveMember(userId: "ghost", channelCid: cid.rawValue)
                session.savePendingRemoveMember(userId: "ios", channelCid: cid.rawValue)
            }
            try repository.prepareMembershipRemove(cid: cid, targets: ["target"], ghosts: ["ghost"])
            let record = try XCTUnwrap(store.load(cid: cid.rawValue))
            defaults.set(record.epoch, forKey: "epoch")
            defaults.set(hash(record.commit), forKey: "commit-hash")
            defaults.synchronize()
            func readyAndWaitForHostTermination() {
                print("QA_MEMBERSHIP_PROCESS_READY case=\(caseId) stage=\(killStage)")
                fflush(stdout)
                DispatchSemaphore(value: 0).wait()
            }
            if killStage == "before_ack" { readyAndWaitForHostTermination() }
            repository.membershipMutationStageHook = { if $0 == "acknowledged" { readyAndWaitForHostTermination() } }
            repository.membershipMutationSender = { _, settle in settle(nil) }
            try repository.resumeMembershipMutation(cid: cid) { _ in XCTFail("Host must terminate at ACK boundary") }
            XCTFail("Process-kill checkpoint returned")
        } else {
            XCTAssertEqual(phase, "verify")
            let record = try XCTUnwrap(store.load(cid: cid.rawValue))
            XCTAssertEqual(hash(record.commit), defaults.string(forKey: "commit-hash"))
            XCTAssertEqual(record.acknowledged, killStage == "after_ack")
            XCTAssertTrue(repository.getPendingRemoveMemberUserIds(channelCid: cid.rawValue).contains("ghost"))
            XCTAssertEqual(try client.loadGroup(with: cid.rawValue).epoch(), UInt64(defaults.integer(forKey: "epoch")))
            var sends = 0
            repository.membershipMutationSender = { retry, settle in
                sends += 1
                XCTAssertEqual(killStage, "before_ack")
                XCTAssertEqual(hash(retry.commit), defaults.string(forKey: "commit-hash"))
                settle(nil)
            }
            let completed = expectation(description: "process restart resumes")
            try repository.resumeMembershipMutation(cid: cid) { error in XCTAssertNil(error); completed.fulfill() }
            wait(for: [completed], timeout: 5)
            XCTAssertEqual(sends, killStage == "before_ack" ? 1 : 0)
            let group = try client.loadGroup(with: cid.rawValue)
            XCTAssertEqual(group.epoch(), UInt64(defaults.integer(forKey: "epoch") + 1))
            XCTAssertEqual(group.membersByUserId(userId: "ios").count, 2)
            XCTAssertTrue(group.membersByUserId(userId: "target").isEmpty)
            XCTAssertTrue(group.membersByUserId(userId: "ghost").isEmpty)
            XCTAssertFalse(repository.getPendingRemoveMemberUserIds(channelCid: cid.rawValue).contains("ghost"))
            XCTAssertNil(try store.load(cid: cid.rawValue))
        }
    }

}
