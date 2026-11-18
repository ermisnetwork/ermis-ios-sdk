import XCTest
@testable import ErmisChat

final class E2eeChannelListPreviewTests: XCTestCase {
    private func row(_ n: Int, role: String = "member", encrypted: Bool = true, banned: Bool = false,
                     generation: Any = 0, newestEncrypted: Bool = true) throws -> ChannelPayload {
        let time = "2026-11-18T00:00:\(String(format: "%02d", n)).000Z"
        let message: (String, Bool) -> [String: Any] = { id, cipher in
            var raw: [String: Any] = ["id": id, "cid": "team:project:c\(n)", "user": ["id": "sender"],
                "created_at": time, "updated_at": time, "content_type": cipher ? "mls" : "standard"]
            if cipher { raw["mls_ciphertext"] = [1, 2, 3]; raw["mls_epoch"] = 1; raw["group_generation"] = generation }
            return raw
        }
        var newest = message("head-\(n)", newestEncrypted)
        newest["created_at"] = "2026-11-18T00:01:\(String(format: "%02d", n)).000Z"
        let raw: [String: Any] = ["channel": ["cid": "team:project:c\(n)", "type": "team", "mls_enabled": encrypted,
            "created_at": time, "updated_at": time, "member_count": 2],
            "membership": ["user_id": "recipient", "channel_role": role, "banned": banned],
            "messages": [message("old-\(n)", true), newest], "read": []]
        return try JSONDecoder.default.decode(ChannelPayload.self, from: JSONSerialization.data(withJSONObject: raw))
    }

    func testOnlyLatestHeadOfFiveMostRecentJoinedChannelsIsRequested() throws {
        let rows = try (0..<12).map { try row($0) }
        let selected = E2eeChannelListPreview.select(rows)
        XCTAssertEqual(selected.map { $0.message.id }, ["head-11", "head-10", "head-9", "head-8", "head-7"])
        XCTAssertEqual(Set(selected.map { $0.cid }).count, 5)
    }

    func testPendingBannedPlaintextAndUnprovenGenerationDoNotTriggerArchiveDemand() throws {
        let rows = [try row(1, role: "pending"), try row(2, banned: true), try row(3, encrypted: false),
                    try row(4, generation: NSNull()), try row(5, newestEncrypted: false), try row(6)]
        XCTAssertEqual(E2eeChannelListPreview.select(rows).map { $0.message.id }, ["head-6"])
    }

    func testDuplicateMetadataDoesNotExpandTheRequestedPage() throws {
        let payload = try row(1)
        XCTAssertEqual(E2eeChannelListPreview.select([payload, payload]).count, 1)
    }
    func testOlderMetadataPageKeepsNewerPreviewWaitingForAdmission() throws {
        let first = E2eeChannelListPreview.select(try (7..<12).map { try row($0) })
        let next = E2eeChannelListPreview.select(try (0..<5).map { try row($0) }, retaining: first)
        XCTAssertEqual(next.map { $0.message.id }, first.map { $0.message.id })
        XCTAssertEqual(E2eeChannelListPreview.select([], retaining: next).count, 5)
    }

    func testAuthoritativePendingOrPlaintextHeadRetiresPriorEncryptedDemand() throws {
        let first = E2eeChannelListPreview.select([try row(1), try row(2)])
        let next = E2eeChannelListPreview.select([try row(1, role: "pending"), try row(2, newestEncrypted: false)], retaining: first)
        XCTAssertTrue(next.isEmpty)
    }

    private final class TrackingRepository: E2eRepository {
        var requests: [(ChannelId, [MessagePayload], Bool)] = []
        var retired = false
        override func captureHistorySessionOwner() -> () throws -> Void {
            return { [weak self] in guard let self, !self.retired else { throw E2eeArchiveError.sessionEnded } }
        }
        override func readiness(for cid: ChannelId) -> E2eeChannelReadiness { .needsRetry }
        override func requestHistoryPage(messages: [MessagePayload], cid: ChannelId, pageOwner: (() throws -> Void)? = nil, retry: Bool = false) {
            do { try pageOwner?() } catch { return }
            requests.append((cid, messages, retry))
        }
    }

    private func repository() throws -> (ErmisClient, TrackingRepository) {
        var config = ErmisClientConfig(apiKeyString: "fixture-key",
            endpointEnviroment: .init(baseURL: URL(string: "https://example.invalid")!), isErmis: false)
        config.localStorageScope = .inMemory
        config.localStorageNamespace = "preview-test-\(UUID().uuidString)"
        config.isClientInActiveMode = false
        var environment = ErmisClient.Environment()
        environment.backgroundTaskSchedulerBuilder = { nil }
        environment.webSocketClientBuilder = nil
        environment.e2eRepositoryBuilder = { database, center, mls, api in
            TrackingRepository(database: database, eventNotificationCenter: center, mlsClient: mls, apiClient: api)
        }
        let client = ErmisClient(config: config, clientId: "fixture", projectId: "project", rootProjectId: "project", chainId: 1,
            environment: environment, notificationTokenProvider: DefaultNotificationTokenProvider(),
            factory: ErmisClientFactory(config: config, environment: environment))
        return (client, try XCTUnwrap(client.e2eRepository as? TrackingRepository))
    }

    func testJoinedPreviewUsesIndependentHistoryLaneEvenWhenLiveScopeNeedsRetry() throws {
        let (client, repository) = try repository(); defer { withExtendedLifetime(client) {} }
        repository.requestChannelListPreviews([try row(1)])
        XCTAssertEqual(repository.requests.map { $0.1.first?.id }, ["head-1"])
    }

    func testUnlockRetriesAllRetainedPreviewHeadsWithoutOpeningChannels() throws {
        let (client, repository) = try repository(); defer { withExtendedLifetime(client) {} }
        repository.requestChannelListPreviews([try row(1), try row(2)])
        repository.requests.removeAll()
        repository.retryRequestedHistoryPage(afterUnlock: true)
        XCTAssertEqual(Set(repository.requests.compactMap { $0.1.first?.id }), ["head-1", "head-2"])
    }

    func testRetiredMetadataOwnerCannotSchedulePreview() throws {
        let (client, repository) = try repository(); defer { withExtendedLifetime(client) {} }
        repository.retired = true
        repository.requestChannelListPreviews([try row(1)])
        XCTAssertTrue(repository.requests.isEmpty)
    }

    func testAuthoritativeMetadataRefreshCanRetryTheSamePartialHead() throws {
        let (client, repository) = try repository(); defer { withExtendedLifetime(client) {} }
        repository.requestChannelListPreviews([try row(1)])
        repository.requestChannelListPreviews([try row(1)])
        XCTAssertEqual(repository.requests.count, 2)
        XCTAssertTrue(repository.requests.allSatisfy { $0.2 }, "Only metadata authority can re-admit a settled head")
    }

}
