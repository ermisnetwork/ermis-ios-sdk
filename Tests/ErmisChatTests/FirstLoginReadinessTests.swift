import XCTest
import CoreData
import open_mls_ios
import CryptoKit
@testable import ErmisChat

final class FirstLoginReadinessTests: XCTestCase {
    private let user = "bootstrap-fixture"
    private func row(_ id: String, parent: String? = nil, scope: String? = nil,
                     role: String? = "member", encrypted: Bool = true, blocked: Bool = false,
                     topics: [[String: Any]] = []) -> [String: Any] {
        var channel: [String: Any] = ["cid": id, "type": parent == nil ? "team" : "topic",
            "created_at": "2026-11-19T00:00:00Z", "updated_at": "2026-11-19T00:00:00Z",
            "mls_enabled": encrypted]
        channel["gate"] = parent != nil && scope == id
        channel["topics_enabled"] = !topics.isEmpty
        channel["parent_cid"] = parent; channel["e2ee_group_id"] = scope
        var result: [String: Any] = ["channel": channel, "messages": [], "read": [], "topics": topics]
        if let role { result["membership"] = ["user_id": user, "user": ["id": user, "project_id": "project"],
            "channel_role": role, "blocked": blocked, "banned": false, "created_at": "2026-11-19T00:00:00Z"] }
        return result
    }
    private func payload(_ rows: [[String: Any]]) throws -> ChannelListPayload {
        try JSONDecoder.default.decode(ChannelListPayload.self, from: JSONSerialization.data(withJSONObject: ["channels": rows]))
    }
    private func database(_ kind: DatabaseContainer.Kind = .inMemory) throws -> DatabaseContainer {
        let db = DatabaseContainer(kind: kind, shouldResetEphemeralValuesOnStart: false)
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !db.persistentStoreCoordinator.persistentStores.isEmpty }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 5), .completed)
        return db
    }
    private final class SecureStore: MlsDeviceIdSecureStoring {
        var values: [String: String] = [:]
        func load(userId: String) throws -> String? { values[userId] }
        func save(deviceId: String, userId: String) throws { values[userId] = deviceId }
        func remove(userId: String) throws { values.removeValue(forKey: userId) }
    }
    private final class API: APIClient {
        let lock = NSLock()
        var roots: [[String: Any]] = [], topics: [[String: Any]] = []
        var failures = Set<String>(), blocked = Set<String>(), syncFailures = Set<String>()
        private var discoveries: [String: Int] = [:]
        private var offsets: [String: [Int]] = [:]
        private var joins = 0
        private var syncScopeHistory: [Set<String>] = []
        var synced: [Set<String>] { lock.lock(); defer { lock.unlock() }; return syncScopeHistory }
        var holdTopicPage = false
        var topicReply: (() -> Void)?
        var holdScope: String?
        var scopeReply: (() -> Void)?
        var holdSyncScope: String?
        var holdSyncAfter = 0
        var heldSyncFailure = false
        var syncReply: (() -> Void)?
        var events: [String: [[String: Any]]] = [:]
        var groupInfo: [String: Any]?
        var onSubmission: (([String: Any]) throws -> Void)?
        var syncPayload: ((E2eSyncRequestBody) -> [String: Any])?
        var submitted: [String: Any]?
        var holdSubmission = false, holdReceipt = false
        var receiptAcceptedAt: UInt64?
        var corruptReceiptContext = false
        var submitReply: (() -> Void)?, receiptReply: (() -> Void)?
        let commitEventId = "00000000-0000-4000-8000-000000000010"
        func setEvents(_ rows: [[String: Any]], scope: String) {
            // Match Bellboy scope_sync_event_from_send_event: protocol transport retains
            // route and server event identity inside ProtocolSyncData as well as its wrapper.
            // The WS normalizer constructs this exact shape; do not hide mismatches by
            // relaxing the product inbox's immutable-payload comparison.
            let canonical = rows.map { row -> [String: Any] in
                guard row["type"] as? String == "protocol", var data = row["data"] as? [String: Any] else { return row }
                var result = row
                result["cid"] = scope
                data["event_id"] = row["event_id"]
                data["created_at"] = row["created_at"]
                result["data"] = data
                return result
            }
            lock.lock(); events[scope] = canonical; lock.unlock()
        }
        var discovered: [String: Int] { lock.lock(); defer { lock.unlock() }; return discoveries }
        var pages: [String: [Int]] { lock.lock(); defer { lock.unlock() }; return offsets }
        var externalJoins: Int { lock.lock(); defer { lock.unlock() }; return joins }
        override func request<Response: Decodable>(endpoint: Endpoint<Response>, completion: @escaping (Result<Response, Error>) -> Void) {
            func reply(_ object: [String: Any]) {
                do { completion(.success(try JSONDecoder.default.decode(Response.self, from: JSONSerialization.data(withJSONObject: object)))) }
                catch { completion(.failure(error)) }
            }
            switch endpoint.path {
            case .channels:
                guard let query = endpoint.body as? ChannelListQuery,
                      let encoded = try? JSONEncoder.ermis.encode(query),
                      let body = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any],
                      let filter = body["filter_conditions"] as? [String: Any] else {
                    completion(.failure(ClientError("Invalid metadata fixture query"))); return
                }
                let isTopics = filter["type"] as? [String] == ["topic"]
                let kind = isTopics ? "topics" : "roots"
                let source = isTopics ? topics : roots, offset = query.pagination.offset
                lock.lock(); offsets[kind, default: []].append(offset); lock.unlock()
                let send = { reply(["channels": Array(source.dropFirst(offset).prefix(query.pagination.pageSize))]) }
                if isTopics && holdTopicPage { lock.lock(); topicReply = send; lock.unlock() } else { send() }
            case .mlsGeneration(let cid):
                lock.lock(); discoveries[cid.rawValue, default: 0] += 1; lock.unlock()
                let send = {
                    if self.failures.contains(cid.rawValue) { completion(.failure(URLError(.notConnectedToInternet))); return }
                    reply(["group_generation": 0, "current_epoch": 0, "membership_version": "fixture",
                        "state": "activated", "reason": "delivery_pending", "retryable": false,
                        "incident_id": self.blocked.contains(cid.rawValue) ? "00000000-0000-4000-8000-000000000001" as Any : NSNull(), "recovery_action": self.blocked.contains(cid.rawValue) ? "manual_intervention_required" : "none",
                        "recovery_revision": "1", "repair_retry_until": NSNull(),
                        "capability": ["protocol_version": 1, "automatic_enabled": false,
                            "repair_timeout_seconds": 900, "max_group_info_bytes": 1048576,
                            "max_ratchet_tree_bytes": 1048576, "max_welcome_recipients": 200, "max_welcome_bytes": 6291456]])
                }
                if holdScope == cid.rawValue { lock.lock(); scopeReply = send; lock.unlock() } else { send() }
            case .e2eSync:
                guard let body = endpoint.body as? E2eSyncRequestBody else { completion(.failure(ClientError("Invalid sync fixture"))); return }
                if !syncFailures.isDisjoint(with: body.cursors.keys) { completion(.failure(URLError(.notConnectedToInternet))); return }
                var scopes: [String: Any] = [:]
                lock.lock()
                syncScopeHistory.append(Set(body.cursors.keys))
                if let syncPayload {
                    let ordinal = syncScopeHistory.count
                    lock.unlock()
                    let response = syncPayload(body), send = { reply(response) }
                    if let scope = holdSyncScope, ordinal > holdSyncAfter, body.cursors[scope] != nil {
                        lock.lock(); syncReply = send; lock.unlock()
                    } else { send() }
                    return
                }
                for (cid, cursor) in body.cursors {
                    let page = events[cid] ?? []
                    let next: [String: Any] = ["created_at": page.last?["created_at"] ?? cursor.createdAt,
                        "event_id": page.last?["event_id"] ?? cursor.eventId]
                    scopes[cid] = ["events": page, "has_more": false, "next_cursor": page.isEmpty ? NSNull() as Any : next]
                }
                lock.unlock()
                let send = {
                    if self.heldSyncFailure { completion(.failure(URLError(.notConnectedToInternet))) }
                    else { reply(["channels": scopes]) }
                }
                if let holdSyncScope, body.cursors[holdSyncScope] != nil {
                    lock.lock(); syncReply = send; lock.unlock()
                } else { send() }
            case .getGroupInfo:
                if let groupInfo { reply(groupInfo) } else { completion(.failure(ClientError("No fixture GroupInfo"))) }
            case .externalJoin:
                do {
                    let bytes = try XCTUnwrap(endpoint.body as? Data)
                    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                    try onSubmission?(object)
                    lock.lock(); joins += 1; submitted = object; lock.unlock()
                    let send = { completion(.failure(URLError(.timedOut))) }
                    if holdSubmission { lock.lock(); submitReply = send; lock.unlock() } else { send() }
                } catch { completion(.failure(error)) }
            case .mlsControl(let path) where path.contains("/external_join/operations/"):
                let operation = String(path.split(separator: "/").last ?? "")
                let receiptCid = (groupInfo?["channel"] as? [String: Any])?["cid"] as? String ?? ""
                lock.lock(); let saved = submitted; lock.unlock()
                let send = {
                    guard let saved else { reply(["version": 1, "operation_id": operation, "cid": receiptCid, "state": "outcome_unknown"]); return }
                    let hash: (String) -> String = { key in
                        let data = (saved[key] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
                        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    }
                    var accepted: [String: Any] = ["version": 1, "operation_id": operation,
                        "cid": receiptCid,
                        "state": "accepted", "group_generation": saved["group_generation"] ?? 0,
                        "epoch": saved["epoch"] ?? 0, "commit_sha256": hash("commit"),
                        "group_info_sha256": hash("group_info"), "event_id": self.commitEventId]
                    if let at = self.receiptAcceptedAt {
                        accepted["acceptance_context"] = ["version": 1, "event_id": self.commitEventId, "cid": receiptCid,
                            "group_generation": saved["group_generation"] ?? 0, "epoch": saved["epoch"] ?? 0,
                            "accepted_at": at, "payload_sha256": self.corruptReceiptContext ? String(repeating: "0", count: 64) : hash("commit"),
                            "provenance": "bellboy_transition_v1"]
                    }
                    reply(accepted)
                }
                if saved != nil && holdReceipt { lock.lock(); receiptReply = send; lock.unlock() } else { send() }
            default:
                if endpoint.path.value.contains("external_join") { lock.lock(); joins += 1; lock.unlock() }
                completion(.failure(ClientError("Unselected fixture endpoint")))
            }
        }
    }
    private final class CountingMlsClient: MlsClient {
        private let loadLock = NSLock()
        private var loads = 0
        var groupLoads: Int { loadLock.lock(); defer { loadLock.unlock() }; return loads }
        override func loadGroup(with cid: String) throws -> Group {
            loadLock.lock(); loads += 1; loadLock.unlock()
            return try super.loadGroup(with: cid)
        }
    }
    private struct Fixture {
        let db: DatabaseContainer
        let client: CountingMlsClient
        let root: URL
        let defaults: UserDefaults
        let devices: MlsDeviceIdStore
        let api: API
        let repo: E2eRepository
        let updater: ChannelListUpdater
        let center: EventNotificationCenter
    }
    private func fixture(rows: [[String: Any]], topics: [[String: Any]] = [], groups: [String], store: DatabaseContainer? = nil,
                         prepare: ((MlsClient) throws -> Void)? = nil) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("full-bootstrap-" + UUID().uuidString)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "full-bootstrap-" + UUID().uuidString))
        let devices = MlsDeviceIdStore(defaults: defaults, legacyDefaults: defaults, secureStore: SecureStore())
        let client = CountingMlsClient(storageFolderURL: root, deviceIdStore: devices, userDefaults: defaults, importLegacyStorage: false)
        try client.setup(with: user)
        for cid in groups {
            let provider = try XCTUnwrap(client.provider)
            let group = try Group.createWithCid(provider: provider, founder: XCTUnwrap(client.identity), cid: cid)
            try group.saveState(provider: provider)
        }
        try prepare?(client)
        let db = try store ?? database(), base = try XCTUnwrap(URL(string: "https://bootstrap-fixture.invalid"))
        let encoder = DefaultRequestEncoder(baseURL: base, authURL: base, stickerURL: base, apiKey: APIKey("fixture"))
        let decoder = DefaultRequestDecoder(), config = URLSessionConfiguration.ephemeral
        let api = API(sessionConfiguration: config, requestEncoder: encoder, requestDecoder: decoder,
            uploader: ErmisUploader(uploadClient: ErmisUploadClient(encoder: encoder, decoder: decoder, sessionConfiguration: config)),
            downloader: ErmisDownloader(client: ErmisDownloadClient(sessionConfiguration: config)))
        api.roots = rows; api.topics = topics
        let center = EventNotificationCenter(database: db)
        center.add(middlewares: [EventDataProcessorMiddleware(), TypingStartCleanupMiddleware(emitEvent: { [weak center] in center?.process($0) }),
            ChannelReadUpdaterMiddleware(newProcessedMessageIds: { [weak center] in center?.newMessageIds ?? [] }),
            UserTypingStateUpdaterMiddleware(), ChannelTopicEventMiddleware(), ChannelTruncatedEventMiddleware(),
            MemberEventMiddleware(), UserChannelBanEventsMiddleware(), UserWatchingEventMiddleware(), UserUpdateMiddleware(),
            ChannelVisibilityEventMiddleware(), EventDTOConverterMiddleware()])
        let repo = E2eRepository(database: db, eventNotificationCenter: center, mlsClient: client, apiClient: api)
        return Fixture(db: db, client: client, root: root, defaults: defaults, devices: devices, api: api, repo: repo, updater: ChannelListUpdater(database: db, apiClient: api, e2eRepository: repo), center: center)
    }
    private func query() -> ChannelListQuery {
        var query = ChannelListQuery(filter: .allChannels(memberId: user, projectId: "project"), pageSize: 5)
        query.shouldLoadAllChannels = true; query.sessionReadinessProjectId = "project"
        return query
    }
    private func awaitState(_ f: Fixture, _ condition: @escaping () -> Bool) {
        let done = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 8), .completed)
    }

    private final class Peer {
        let provider = Provider()
        let identity: Identity
        let group: Group
        let cid: String
        init(_ cid: String) throws {
            self.cid = cid; identity = try Identity(provider: provider, userId: "fixture-peer")
            group = try Group.createWithCid(provider: provider, founder: identity, cid: cid)
            try group.saveState(provider: provider)
        }
        func message(_ id: String, at: String, text: String) throws -> [String: Any] {
            let body = try JSONEncoder().encode(E2ePayload(text: text, attachments: [], stickerUrl: nil))
            // The current text-only lane uses empty AAD. Nonempty authenticated metadata
            // is reserved for forwarding/attachments and must not be fabricated by a fixture.
            let cipher = try group.createMessage(provider: provider, sender: identity, plaintext: body)
            try group.saveState(provider: provider)
            return ["event_id": id, "created_at": at, "type": "application",
                "data": ["id": id, "cid": cid, "type": "regular", "content_type": "mls", "text": "",
                    "created_at": at, "updated_at": at, "user": ["id": "fixture-peer", "project_id": "project"],
                    "mls_ciphertext": cipher.base64EncodedString(), "mls_epoch": group.epoch(), "group_generation": 0,
                    "e2ee_group_id": cid]]
        }
        func welcome(_ client: MlsClient, user: String, at: String) throws -> ([String: Any], Data, RatchetTree) {
            let add = try group.addMembers(provider: provider, sender: identity, newMembers: [KeyPackage.fromBytes(data: XCTUnwrap(client.getKeyPackage()))])
            try group.mergePendingCommit(provider: provider); try group.saveState(provider: provider)
            let welcome = try XCTUnwrap(add.welcome), tree = group.exportRatchetTree()
            let event: [String: Any] = ["event_id": "00000000-0000-4000-8000-000000000002", "created_at": at, "type": "protocol",
                "data": ["type": "welcome", "epoch": group.epoch(), "group_generation": 0,
                    "user": ["id": "fixture-peer", "project_id": "project"], "created_at": at,
                    "target_user_ids": [user], "target_device_ids": [try XCTUnwrap(client.currentDeviceId)],
                    "welcome": welcome.base64EncodedString(), "ratchet_tree": tree.toBytes().base64EncodedString()]]
            return (event, welcome, tree)
        }
    }
    private func injectSocket(_ event: [String: Any], into f: Fixture) throws {
        let message = try XCTUnwrap(event["data"] as? [String: Any])
        let bytes = try JSONSerialization.data(withJSONObject: ["type": "message.new", "cid": message["cid"] ?? "",
            "message": message, "user": ["id": "fixture-peer", "project_id": "project"], "created_at": event["created_at"] ?? ""])
        let received = try EventDecoder().decode(from: bytes)
        let saved = expectation(description: "Socket event persists without opening a channel")
        f.center.process(received) { saved.fulfill() }
        wait(for: [saved], timeout: 5)
    }
    private func injectProtocol(_ envelope: [String: Any], cid: String, into f: Fixture) throws {
        let wire: [String: Any] = ["type": "protocol", "cid": cid,
            "event_id": try XCTUnwrap(envelope["event_id"]), "created_at": try XCTUnwrap(envelope["created_at"]),
            "protocol_data": try XCTUnwrap(envelope["data"])]
        let payload = try JSONDecoder.default.decode(EventPayload.self, from: JSONSerialization.data(withJSONObject: wire))
        var event = try MLSEvent(cid: ChannelId(cid: cid), parentCid: nil, topicCids: [], user: nil,
            mlsProtocol: XCTUnwrap(payload.mlsProtocol), createdAt: XCTUnwrap(payload.createdAt))
        event.protocolEnvelope = try XCTUnwrap(payload.mlsSyncEnvelope)
        f.repo.eventsController(EventsController(notificationCenter: f.center), didReceiveEvent: event)
    }
    private func hasPlaintext(_ f: Fixture, id: String, text: String) -> Bool {
        var found = false
        let context = f.db.backgroundReadOnlyContext
        context.performAndWait { found = MessageDTO.load(id: id, context: context)?.decryptedMessage?.text == text }
        return found
    }
    private func releaseHead(_ f: Fixture) {
        f.api.lock.lock(); let reply = f.api.scopeReply; f.api.scopeReply = nil; f.api.lock.unlock(); reply?()
    }

    private final class HeldProtocolDatabase: DatabaseContainer {
        var holdEventId: String?
        var entered: XCTestExpectation?
        let resume = DispatchSemaphore(value: 0)
        override func writeAndWait(_ actions: (DatabaseSession) throws -> Void, file: StaticString = #fileID, line: UInt = #line) throws {
            try super.writeAndWait({ session in
                try actions(session)
                guard let id = self.holdEventId, let context = session as? NSManagedObjectContext else { return }
                let request = NSFetchRequest<E2eeInboxEventDTO>(entityName: E2eeInboxEventDTO.entityName)
                request.predicate = NSPredicate(format: "eventId == %@ AND protocolCiphertextHash != nil AND mlsStatePersisted == NO", id)
                guard try !context.fetch(request).isEmpty else { return }
                self.holdEventId = nil; self.entered?.fulfill()
                XCTAssertEqual(self.resume.wait(timeout: .now() + 3), .success)
            }, file: file, line: line)
        }
    }

    func testRealtimePeerCommitAppliesWithoutSyncAndPreservesOfflineCursors() throws {
        let cid = "team:project:direct-realtime", peer = try Peer(cid)
        let timestamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(60))
        let f = try fixture(rows: [row(cid)], groups: [], prepare: { client in
            let (_, welcome, tree) = try peer.welcome(client, user: self.user, at: timestamp)
            _ = try client.joinWithWelcome(cid: cid, welcome: welcome, ratchetTree: tree)
        })
        let commit = try peer.group.selfUpdate(provider: peer.provider, sender: peer.identity)
        try peer.group.mergePendingCommit(provider: peer.provider)
        try peer.group.saveState(provider: peer.provider)
        let id = "12345678-1234-4234-8234-123456789012"
        let wire: [String: Any] = ["type": "protocol", "cid": cid, "event_id": id, "created_at": timestamp,
            "protocol_data": ["type": "commit", "epoch": peer.group.epoch(), "group_generation": 0,
                "user": ["id": "fixture-peer", "project_id": "project"], "device_id": "peer-device",
                "commit": commit.commit.base64EncodedString()]]
        let payload = try JSONDecoder.default.decode(EventPayload.self, from: JSONSerialization.data(withJSONObject: wire))
        var event = try MLSEvent(cid: ChannelId(cid: cid), parentCid: nil, topicCids: [], user: nil,
            mlsProtocol: XCTUnwrap(payload.mlsProtocol), createdAt: XCTUnwrap(payload.createdAt))
        event.protocolEnvelope = try XCTUnwrap(payload.mlsSyncEnvelope)
        let controller = EventsController(notificationCenter: f.center)
        var unbound = event; unbound.protocolEnvelope = nil
        f.repo.eventsController(controller, didReceiveEvent: unbound)
        f.repo.eventsController(controller, didReceiveEvent: event)
        let inbox = E2eeDurableInboxStore(database: f.db)
        awaitState(f) { (try? inbox.commitPersistenceProof(accountId: self.user, scopeCid: cid, eventId: id)?.mlsStatePersisted) == true }
        XCTAssertEqual(try f.client.loadGroup(with: cid).epoch(), peer.group.epoch())
        XCTAssertTrue(f.api.synced.isEmpty)
        XCTAssertNil(try inbox.fetchCursor(accountId: user, scopeCid: cid))
        XCTAssertNil(try inbox.applyCursor(accountId: user, scopeCid: cid))
        XCTAssertTrue(try inbox.loadPendingEvents(accountId: user, scopeCid: cid).isEmpty)
    }

    func testRealtimePredecessorUnblocksRetainedGapWithoutSync() throws {
        let cid = "team:project:realtime-order", peer = try Peer(cid)
        let base = Date().addingTimeInterval(60), formatter = ISO8601DateFormatter()
        let f = try fixture(rows: [row(cid)], groups: [], prepare: { client in
            let (_, welcome, tree) = try peer.welcome(client, user: self.user, at: formatter.string(from: base))
            _ = try client.joinWithWelcome(cid: cid, welcome: welcome, ratchetTree: tree)
        })
        func next(_ index: Int) throws -> MLSEvent {
            let commit = try peer.group.selfUpdate(provider: peer.provider, sender: peer.identity)
            try peer.group.mergePendingCommit(provider: peer.provider); try peer.group.saveState(provider: peer.provider)
            let wire: [String: Any] = ["type": "protocol", "cid": cid,
                "event_id": String(format: "12345678-1234-4234-8234-%012d", index),
                "created_at": formatter.string(from: base.addingTimeInterval(Double(index))),
                "protocol_data": ["type": "commit", "epoch": peer.group.epoch(), "group_generation": 0,
                    "user": ["id": "fixture-peer", "project_id": "project"], "device_id": "peer-device",
                    "commit": commit.commit.base64EncodedString()]]
            let payload = try JSONDecoder.default.decode(EventPayload.self, from: JSONSerialization.data(withJSONObject: wire))
            var event = try MLSEvent(cid: ChannelId(cid: cid), parentCid: nil, topicCids: [], user: nil,
                mlsProtocol: XCTUnwrap(payload.mlsProtocol), createdAt: XCTUnwrap(payload.createdAt))
            event.protocolEnvelope = try XCTUnwrap(payload.mlsSyncEnvelope); return event
        }
        let first = try next(20), second = try next(21)
        let controller = EventsController(notificationCenter: f.center), inbox = E2eeDurableInboxStore(database: f.db)
        f.repo.eventsController(controller, didReceiveEvent: second)
        awaitState(f) { (try? inbox.loadPendingEvents(accountId: self.user, scopeCid: cid).count) == 1 }
        f.repo.eventsController(controller, didReceiveEvent: first)
        awaitState(f) { (try? self.fEpoch(f, cid: cid)) == peer.group.epoch() && (try? inbox.loadPendingEvents(accountId: self.user, scopeCid: cid).isEmpty) == true }
        XCTAssertTrue(f.api.synced.isEmpty)
        XCTAssertNil(try inbox.fetchCursor(accountId: user, scopeCid: cid))
    }

    private func fEpoch(_ f: Fixture, cid: String) throws -> UInt64 { try f.client.loadGroup(with: cid).epoch() }

    func testRealtimeCommitBeforeScopeJoinedRetainsEnvelopeWithoutSync() throws {
        let cid = "team:project:queued-realtime", id = "12345678-1234-4234-8234-123456789014"
        let f = try fixture(rows: [row(cid)], groups: [])
        let wire: [String: Any] = ["type": "protocol", "cid": cid, "event_id": id,
            "created_at": "2026-11-22T00:00:00Z", "protocol_data": ["type": "commit", "epoch": 2,
                "user": ["id": "peer", "project_id": "project"], "device_id": "peer-device", "commit": "AQID"]]
        let payload = try JSONDecoder.default.decode(EventPayload.self, from: JSONSerialization.data(withJSONObject: wire))
        var event = try MLSEvent(cid: ChannelId(cid: cid), parentCid: nil, topicCids: [], user: nil,
            mlsProtocol: XCTUnwrap(payload.mlsProtocol), createdAt: XCTUnwrap(payload.createdAt))
        event.protocolEnvelope = try XCTUnwrap(payload.mlsSyncEnvelope)
        f.repo.eventsController(EventsController(notificationCenter: f.center), didReceiveEvent: event)
        let inbox = E2eeDurableInboxStore(database: f.db)
        awaitState(f) { (try? inbox.loadPendingEvents(accountId: self.user, scopeCid: cid).count) == 1 }
        XCTAssertTrue(f.api.synced.isEmpty)
        XCTAssertFalse(f.client.isGroupLoaded(cid: cid))
        XCTAssertNil(try inbox.fetchCursor(accountId: user, scopeCid: cid))
        XCTAssertNil(try inbox.commitPersistenceProof(accountId: user, scopeCid: cid, eventId: id))
    }

    func testRealtimeEnvelopeRequiresServerIdentityAndMatchesScopeSyncBytes() throws {
        let id = "12345678-1234-4234-8234-123456789013", time = "2026-11-22T00:00:00.123456Z"
        let protocolData: [String: Any] = ["type": "commit", "epoch": 2, "user": ["id": "peer", "project_id": "project"], "commit": "AQID"]
        var wire: [String: Any] = ["type": "protocol", "cid": "team:project:wire", "event_id": id, "created_at": time, "protocol_data": protocolData]
        func decode() throws -> EventPayload { try JSONDecoder.default.decode(EventPayload.self, from: JSONSerialization.data(withJSONObject: wire)) }
        let realtime = try XCTUnwrap(decode().mlsSyncEnvelope)
        var data = protocolData; data["event_id"] = id; data["created_at"] = time
        let sync: [String: Any] = ["type": "protocol", "cid": "team:project:wire", "event_id": id, "created_at": time, "data": data]
        let canonical = try JSONDecoder.default.decode(E2eSyncEventEnvelope.self, from: JSONSerialization.data(withJSONObject: sync))
        XCTAssertEqual(realtime.rawEnvelope, canonical.rawEnvelope)
        wire.removeValue(forKey: "event_id")
        XCTAssertNil(try decode().mlsSyncEnvelope)
    }

    func testReadyWaitsForAllDurablePrefixTurnsIncludingProtocolAfterLargeTimestampBucket() throws {
        // Protocol acceptance must fall inside newly generated leaf lifetimes.
        let base = Date().addingTimeInterval(60), formatter = ISO8601DateFormatter()
        let times = (0...3).map { formatter.string(from: base.addingTimeInterval(Double($0))) }
        let cid = "team:project:prefix-turns", peer = try Peer(cid)
        let db = HeldProtocolDatabase(kind: .inMemory, shouldResetEphemeralValuesOnStart: false)
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !db.persistentStoreCoordinator.persistentStores.isEmpty }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 5), .completed)
        let f = try fixture(rows: [row(cid)], groups: [], store: db, prepare: { client in
            let (_, welcome, tree) = try peer.welcome(client, user: self.user, at: times[0])
            _ = try client.joinWithWelcome(cid: cid, welcome: welcome, ratchetTree: tree)
        })
        let page = try (1...150).map { try peer.message(String(format: "00000000-0000-4000-8000-%012d", $0),
            at: times[1], text: "fixture-prefix") }
        let extra = Provider(), identity = try Identity(provider: extra, userId: "fixture-extra")
        let bundle = try peer.group.addMembers(provider: peer.provider, sender: peer.identity, newMembers: [identity.keyPackage(provider: extra)])
        try peer.group.mergePendingCommit(provider: peer.provider); try peer.group.saveState(provider: peer.provider)
        let commitId = "10000000-0000-4000-8000-000000000001", postId = "20000000-0000-4000-8000-000000000001"
        let commit: [String: Any] = ["event_id": commitId, "created_at": times[2], "type": "protocol",
            "data": ["type": "commit", "epoch": peer.group.epoch(), "group_generation": 0,
                "created_at": times[2], "commit": bundle.commit.base64EncodedString(),
                "user": ["id": "fixture-peer", "project_id": "project"]]]
        let post = try peer.message(postId, at: times[3], text: "fixture-after-prefix")
        f.api.syncPayload = { body in
            let cursor = body.cursors[cid]?.eventId ?? ""
            let tail = cursor == page.last?["event_id"] as? String
            let events = cursor == postId ? [] : tail ? [commit, post] : page
            return ["channels": [cid: ["events": events, "has_more": !tail && cursor != postId,
                "next_cursor": ["created_at": tail || cursor == postId ? times[3] : times[1],
                    "event_id": tail || cursor == postId ? postId : page.last?["event_id"] ?? ""]]]]
        }
        let entered = expectation(description: "Protocol behind the first100 applications is reached")
        db.holdEventId = commitId; db.entered = entered
        defer { db.resume.signal() }
        f.api.holdScope = cid; f.updater.update(channelListQuery: query(), userId: user)
        awaitState(f) { f.repo.sessionProgress.snapshot?.totalChannels == 1 && f.api.discovered[cid] == 1 }
        releaseHead(f)
        wait(for: [entered], timeout: 8)
        XCTAssertEqual(f.repo.sessionProgress.snapshot?.readyChannels, 0, "A barrier before the remaining durable turn is not current messaging readiness")
        XCTAssertEqual(f.repo.sessionProgress.snapshot?.status, "running")
        db.resume.signal()
        awaitState(f) { f.repo.sessionProgress.snapshot?.readyChannels == 1 }
        XCTAssertEqual(try f.client.loadGroup(with: cid).epoch(), peer.group.epoch())
        let inbox = E2eeDurableInboxStore(database: db)
        XCTAssertTrue(try inbox.loadPendingEvents(accountId: user, scopeCid: cid).isEmpty)
        XCTAssertEqual(try inbox.applyCursor(accountId: user, scopeCid: cid)?.eventId, postId)
        XCTAssertEqual(f.api.externalJoins, 0)
    }

    func testQueuedExistingGroupReceivesAndProjectsExactlyOnceBeforeItsBootstrapTurnAndAfterReady() throws {
        // Protocol acceptance must fall inside newly generated leaf lifetimes.
        let base = Date().addingTimeInterval(60), formatter = ISO8601DateFormatter()
        let times = (0...3).map { formatter.string(from: base.addingTimeInterval(Double($0))) }
        let ids = (0..<8).map { "team:project:scope-\($0)" }, tail = "team:project:scope-7"
        let peer = try Peer(tail)
        let f = try fixture(rows: ids.map { row($0) }, groups: Array(ids.dropLast()), prepare: { client in
            let (_, welcome, tree) = try peer.welcome(client, user: self.user, at: times[1])
            _ = try client.joinWithWelcome(cid: tail, welcome: welcome, ratchetTree: tree)
        })
        f.api.holdScope = ids[0]; f.updater.update(channelListQuery: query(), userId: user)
        awaitState(f) { f.api.lock.lock(); defer { f.api.lock.unlock() }; return f.api.scopeReply != nil }
        let id = "00000000-0000-4000-8000-000000000003"
        let extra = Provider(), extraIdentity = try Identity(provider: extra, userId: "fixture-extra-peer")
        let add = try peer.group.addMembers(provider: peer.provider, sender: peer.identity,
            newMembers: [extraIdentity.keyPackage(provider: extra)])
        try peer.group.mergePendingCommit(provider: peer.provider); try peer.group.saveState(provider: peer.provider)
        let catchup: [String: Any] = ["event_id": "00000000-0000-4000-8000-000000000002", "created_at": times[1], "type": "protocol",
            "data": ["type": "commit", "epoch": peer.group.epoch(), "group_generation": 0,
                "created_at": times[1], "commit": add.commit.base64EncodedString(),
                "user": ["id": "fixture-peer", "project_id": "project"]]]
        let event = try peer.message(id, at: times[2], text: "fixture-queued")
        f.api.setEvents([catchup, event], scope: tail)
        try injectSocket(event, into: f)
        try injectProtocol(catchup, cid: tail, into: f)
        awaitState(f) { self.hasPlaintext(f, id: id, text: "fixture-queued") }
        XCTAssertTrue(f.api.synced.isEmpty, "Realtime Commit repairs retained ciphertext locally while bootstrap head is held")
        XCTAssertNil(f.api.discovered[tail], "Realtime intake does not wait for the tail's bootstrap turn")
        try injectSocket(event, into: f)
        releaseHead(f)
        awaitState(f) { f.repo.sessionProgress.snapshot?.readyChannels == 8 }
        XCTAssertEqual(f.api.externalJoins, 0)
        let nextId = "00000000-0000-4000-8000-000000000004"
        let next = try peer.message(nextId, at: times[3], text: "fixture-ready")
        f.api.setEvents([catchup, event, next], scope: tail); try injectSocket(next, into: f)
        awaitState(f) { self.hasPlaintext(f, id: nextId, text: "fixture-ready") }
        try f.db.writeAndWait { session in
            let message = try XCTUnwrap(session.message(id: id))
            XCTAssertEqual(try message.asModel().text, "fixture-queued")
            let context = try XCTUnwrap(session as? NSManagedObjectContext)
            let request = NSFetchRequest<MessageDTO>(entityName: MessageDTO.entityName)
            request.predicate = NSPredicate(format: "id == %@", id)
            XCTAssertEqual(try context.count(for: request), 1)
        }
    }

    func testQueuedMissingGroupRetainsPreJoinCiphertextThenProcessesWelcomeBeforeAnyExternalJoin() throws {
        let ids = (0..<8).map { "team:project:scope-\($0)" }, tail = "team:project:scope-7"
        let peer = try Peer(tail), preId = "00000000-0000-4000-8000-000000000001"
        let pre = try peer.message(preId, at: "2026-11-19T00:00:00.100Z", text: "fixture-pre-join")
        var welcome: [String: Any] = [:]
        let f = try fixture(rows: ids.map { row($0) }, groups: Array(ids.dropLast()), prepare: { client in
            welcome = try peer.welcome(client, user: self.user, at: "2026-11-19T00:00:01Z").0
        })
        f.api.holdScope = ids[0]; f.updater.update(channelListQuery: query(), userId: user)
        awaitState(f) { f.api.lock.lock(); defer { f.api.lock.unlock() }; return f.api.scopeReply != nil }
        f.api.setEvents([pre], scope: tail); try injectSocket(pre, into: f)
        let inbox = E2eeDurableInboxStore(database: f.db)
        awaitState(f) {
            var retained = false
            let context = f.db.backgroundReadOnlyContext
            context.performAndWait { retained = MessageDTO.load(id: preId, context: context)?.encryptedData != nil }
            return retained
        }
        XCTAssertTrue(f.api.synced.isEmpty, "Missing-group realtime intake must retain ciphertext without an offline request")
        XCTAssertFalse(hasPlaintext(f, id: preId, text: "fixture-pre-join"))
        let postId = "00000000-0000-4000-8000-000000000003"
        let post = try peer.message(postId, at: "2026-11-19T00:00:02Z", text: "fixture-after-welcome")
        f.api.setEvents([pre, welcome, post], scope: tail); try injectSocket(post, into: f)
        try injectProtocol(welcome, cid: tail, into: f)
        awaitState(f) { self.hasPlaintext(f, id: postId, text: "fixture-after-welcome") }
        XCTAssertTrue(f.api.synced.isEmpty, "Welcome locally resumes the retained message before session catch-up")
        releaseHead(f)
        awaitState(f) { f.repo.sessionProgress.snapshot?.readyChannels == 8 }
        XCTAssertEqual(f.api.externalJoins, 0, "A valid Welcome wins; bootstrap must not construct an External Join")
        XCTAssertEqual(try inbox.loadApplicationEvents(accountId: user, scopeCid: tail, disposition: .preJoinHistorical).map(\.eventId), [preId])
        XCTAssertFalse(hasPlaintext(f, id: preId, text: "fixture-pre-join"), "An eventual join is not historical decryption entitlement")
    }

    func testIncomingExternalCommitDuringSubmitAndReceiptReconcileRetainsProtocolUntilActivation() throws {
        let ids = (0..<8).map { "team:project:scope-\($0)" }, tail = "team:project:scope-7"
        let peer = try Peer(tail)
        let preId = "00000000-0000-4000-8000-000000000001"
        let pre = try peer.message(preId, at: "2026-11-19T00:00:00.100Z", text: "fixture-before-external-join")
        let f = try fixture(rows: ids.map { row($0) }, groups: Array(ids.dropLast()))
        let info = try peer.group.exportGroupInfo(provider: peer.provider, sender: peer.identity, withRatchetTree: true)
        f.api.groupInfo = ["channel": row(tail)["channel"] ?? [:], "group_info": info.base64EncodedString(),
            "epoch": peer.group.epoch(), "hash": SHA256.hash(data: info).map { String(format: "%02x", $0) }.joined(),
            "is_stale": false, "group_generation": 0, "external_join_prerequisite": ["reason": "active_member_recovery"]]
        f.api.onSubmission = { body in
            let commit = try XCTUnwrap((body["commit"] as? String).flatMap { Data(base64Encoded: $0) })
            _ = try peer.group.processMessage(provider: peer.provider, msg: commit)
            try peer.group.saveState(provider: peer.provider)
        }
        f.api.holdSubmission = true; f.api.holdReceipt = true
        f.api.setEvents([pre], scope: tail)
        f.updater.update(channelListQuery: query(), userId: user)
        awaitState(f) { f.api.lock.lock(); defer { f.api.lock.unlock() }; return f.api.submitReply != nil }
        let original = try XCTUnwrap(f.client.loadPendingGenerationJoin(cid: tail))
        let postId = "00000000-0000-4000-8000-000000000011"
        let post = try peer.message(postId, at: "2026-11-19T00:00:02Z", text: "fixture-during-submit")
        let body = try XCTUnwrap(f.api.submitted)
        let commit: [String: Any] = ["event_id": f.api.commitEventId, "created_at": "2026-11-19T00:00:01Z", "type": "protocol",
            "data": ["type": "external_commit", "epoch": body["epoch"] ?? 1, "group_generation": 0,
                "created_at": "2026-11-19T00:00:01Z", "commit": body["commit"] ?? "",
                "device_id": try XCTUnwrap(f.client.currentDeviceId), "user": ["id": user, "project_id": "project"]]]
        f.api.setEvents([pre, commit, post], scope: tail); try injectSocket(post, into: f)
        try injectProtocol(commit, cid: tail, into: f)
        let inbox = E2eeDurableInboxStore(database: f.db)
        awaitState(f) { (try? inbox.loadPendingEvents(accountId: self.user, scopeCid: tail).contains { $0.eventId == f.api.commitEventId }) == true }
        XCTAssertNil(try inbox.fetchCursor(accountId: user, scopeCid: tail), "WS receipt retention cannot advance the offline fetch cursor")
        XCTAssertTrue(f.api.synced.isEmpty)
        try f.db.writeAndWait { session in
            let context = try XCTUnwrap(session as? NSManagedObjectContext)
            let stored = try XCTUnwrap(E2eeInboxEventDTO.load(accountId: self.user, scopeCid: tail, eventId: f.api.commitEventId, context: context))
            XCTAssertNil(stored.appliedAt, "A retained isolated candidate cannot let the canonical join commit be skipped as historical")
        }
        let opened = expectation(description: "Concurrent open awaits the original operation")
        f.repo.ensureE2eeReady(for: try ChannelId(cid: tail)) { state in XCTAssertEqual(state, .ready); opened.fulfill() }
        f.api.lock.lock(); let submitted = f.api.submitReply; f.api.submitReply = nil; f.api.lock.unlock(); submitted?()
        awaitState(f) { f.api.lock.lock(); defer { f.api.lock.unlock() }; return f.api.receiptReply != nil }
        XCTAssertEqual(f.client.loadPendingGenerationJoin(cid: tail)?.externalJoinBody, original.externalJoinBody)
        XCTAssertEqual(f.api.externalJoins, 1)
        XCTAssertFalse(hasPlaintext(f, id: postId, text: "fixture-during-submit"))
        let reconcileId = "00000000-0000-4000-8000-000000000012"
        let duringReceipt = try peer.message(reconcileId, at: "2026-11-19T00:00:03Z", text: "fixture-during-receipt")
        f.api.setEvents([pre, commit, post, duringReceipt], scope: tail); try injectSocket(duringReceipt, into: f)
        XCTAssertTrue(f.api.synced.isEmpty, "Receipt reconciliation retains its original owner without realtime sync")
        XCTAssertFalse(hasPlaintext(f, id: reconcileId, text: "fixture-during-receipt"))
        f.api.lock.lock(); let receipt = f.api.receiptReply; f.api.receiptReply = nil; f.api.lock.unlock(); receipt?()
        wait(for: [opened], timeout: 8)
        awaitState(f) { self.hasPlaintext(f, id: postId, text: "fixture-during-submit") }
        awaitState(f) { self.hasPlaintext(f, id: reconcileId, text: "fixture-during-receipt") }
        XCTAssertEqual(f.api.externalJoins, 1)
        XCTAssertNil(f.client.loadPendingGenerationJoin(cid: tail))
        XCTAssertEqual(f.repo.sessionProgress.snapshot?.readyChannels, 8)
        XCTAssertNil(try inbox.localJoinReceiptProof(accountId: user, scopeCid: tail))
        XCTAssertEqual(try inbox.loadApplicationEvents(accountId: user, scopeCid: tail, disposition: .preJoinHistorical).map(\.eventId), [preId])
        XCTAssertFalse(hasPlaintext(f, id: preId, text: "fixture-before-external-join"))
        let activeId = "00000000-0000-4000-8000-000000000013"
        let active = try peer.message(activeId, at: "2026-11-19T00:00:04Z", text: "fixture-after-activation")
        f.api.setEvents([pre, commit, post, duringReceipt, active], scope: tail); try injectSocket(active, into: f)
        awaitState(f) { self.hasPlaintext(f, id: activeId, text: "fixture-after-activation") }
    }

    func testFirstBatchAfterFreshJoinIncludesItsCanonicalCommitWithoutPresyncOrOpen() throws {
        try firstJoinCursor(canonicalReceipt: false)
    }

    func testPeerRealtimeCommitBeforeFirstCatchupStillFinalizesExactOwnJoinReceipt() throws {
        try advancedJoinCatchup()
    }

    func testHistoricalCommitCannotFinalizeUnmergedJoinReceipt() throws {
        try advancedJoinCatchup(unmergedReceipt: true)
    }

    func testHistoricalCommitFromOtherDeviceCannotFinalizeRetainedJoinReceipt() throws {
        try advancedJoinCatchup(otherDevice: true)
    }

    func testPreviouslySupersededOwnJoinCompletesWithoutReplayingCommitOrNewJoin() throws {
        try advancedJoinCatchup(previouslySuperseded: true)
    }

    private func advancedJoinCatchup(unmergedReceipt: Bool = false, otherDevice: Bool = false,
                                    previouslySuperseded: Bool = false) throws {
        let cid = "team:project:join-advanced-before-catchup", peer = try Peer("team:project:join-advanced-before-catchup")
        let f = try fixture(rows: [row(cid)], groups: [])
        let info = try peer.group.exportGroupInfo(provider: peer.provider, sender: peer.identity, withRatchetTree: true)
        f.api.groupInfo = ["channel": row(cid)["channel"] ?? [:], "group_info": info.base64EncodedString(),
            "epoch": peer.group.epoch(), "hash": SHA256.hash(data: info).map { String(format: "%02x", $0) }.joined(),
            "is_stale": false, "group_generation": 0, "external_join_prerequisite": ["reason": "active_member_recovery"]]
        f.api.holdSyncScope = cid
        f.api.onSubmission = { body in
            let ownDevice = try XCTUnwrap(f.client.currentDeviceId)
            let commit = try XCTUnwrap((body["commit"] as? String).flatMap { Data(base64Encoded: $0) })
            _ = try peer.group.processMessage(provider: peer.provider, msg: commit)
            try peer.group.saveState(provider: peer.provider)
            f.api.setEvents([["event_id": f.api.commitEventId, "created_at": "2026-11-19T00:00:01Z", "type": "protocol",
                "data": ["type": "external_commit", "epoch": body["epoch"] ?? 1, "group_generation": 0,
                    "created_at": "2026-11-19T00:00:01Z", "commit": body["commit"] ?? "",
                    "device_id": otherDevice ? "other-device" : ownDevice,
                    "user": ["id": self.user, "project_id": "project"]]]], scope: cid)
        }
        f.updater.update(channelListQuery: query(), userId: user)
        awaitState(f) { f.api.lock.lock(); defer { f.api.lock.unlock() }; return f.api.syncReply != nil }
        let inbox = E2eeDurableInboxStore(database: f.db)
        let receipt = try XCTUnwrap(inbox.localJoinReceiptProof(accountId: user, scopeCid: cid))
        XCTAssertEqual(receipt.status, .merged)

        let commit = try peer.group.selfUpdate(provider: peer.provider, sender: peer.identity)
        try peer.group.mergePendingCommit(provider: peer.provider)
        try peer.group.saveState(provider: peer.provider)
        let wire: [String: Any] = ["type": "protocol", "cid": cid,
            "event_id": "12345678-1234-4234-8234-123456789099", "created_at": "2026-11-19T00:00:02Z",
            "protocol_data": ["type": "commit", "epoch": peer.group.epoch(), "group_generation": 0,
                "user": ["id": "fixture-peer", "project_id": "project"], "device_id": "peer-device",
                "commit": commit.commit.base64EncodedString()]]
        let payload = try JSONDecoder.default.decode(EventPayload.self, from: JSONSerialization.data(withJSONObject: wire))
        var event = try MLSEvent(cid: ChannelId(cid: cid), parentCid: nil, topicCids: [], user: nil,
            mlsProtocol: XCTUnwrap(payload.mlsProtocol), createdAt: XCTUnwrap(payload.createdAt))
        event.protocolEnvelope = try XCTUnwrap(payload.mlsSyncEnvelope)
        f.repo.eventsController(EventsController(notificationCenter: f.center), didReceiveEvent: event)
        awaitState(f) { (try? self.fEpoch(f, cid: cid)) == peer.group.epoch() }
        XCTAssertGreaterThan(peer.group.epoch(), receipt.epoch)
        XCTAssertNotNil(try inbox.localJoinReceiptProof(accountId: user, scopeCid: cid))

        if previouslySuperseded {
            // Preserve exactly the persisted state left by the old historical branch. A
            // duplicate page will not put this already-applied event back in the pending queue.
            f.api.lock.lock(); let stored = f.api.events[cid] ?? []; f.api.lock.unlock()
            let raw = try XCTUnwrap(stored.first)
            let own = try JSONDecoder.default.decode(E2eSyncEventEnvelope.self, from: JSONSerialization.data(withJSONObject: raw))
            _ = try inbox.persistPage(accountId: user, scopeCid: cid, events: [own], hasMore: false,
                nextCursor: .init(createdAt: own.createdAtRaw, eventId: own.eventId))
            try inbox.markCommitSuperseded(accountId: user, scopeCid: cid, envelope: own,
                ciphertextHash: receipt.commitHash, targetEpoch: receipt.epoch)
            XCTAssertEqual(try inbox.commitPersistenceProof(accountId: user, scopeCid: cid, eventId: own.eventId)?.mlsStatePersisted, false)
        }

        if unmergedReceipt {
            // Model a crash after provider installation but before the durable merged checkpoint.
            try f.db.writeAndWait { session in
                let context = try XCTUnwrap(session as? NSManagedObjectContext)
                let stored = try XCTUnwrap(E2eeLocalJoinReceiptDTO.load(accountId: self.user, scopeCid: cid, context: context))
                stored.status = E2eeLocalJoinReceiptStatus.serverAccepted.rawValue
            }
        }

        let duringId = "12345678-1234-4234-8234-123456789097"
        let during = try peer.message(duringId, at: "2026-11-19T00:00:03Z", text: "arrived-after-http-admission")
        try injectSocket(during, into: f)
        XCTAssertFalse(hasPlaintext(f, id: duringId, text: "arrived-after-http-admission"))

        f.api.lock.lock(); let response = f.api.syncReply; f.api.syncReply = nil; f.api.holdSyncScope = nil; f.api.lock.unlock()
        response?()
        awaitState(f) { ["done", "partial"].contains(f.repo.sessionProgress.snapshot?.status ?? "") }
        if unmergedReceipt || otherDevice {
            XCTAssertEqual(f.repo.sessionProgress.snapshot?.status, "partial")
            XCTAssertNotNil(try inbox.localJoinReceiptProof(accountId: user, scopeCid: cid))
            XCTAssertNotEqual(try inbox.commitPersistenceProof(accountId: user, scopeCid: cid, eventId: f.api.commitEventId)?.mlsStatePersisted, true)
            XCTAssertEqual(try f.client.loadGroup(with: cid).epoch(), peer.group.epoch())
            XCTAssertEqual(f.api.externalJoins, 1)
            return
        }
        XCTAssertEqual(f.repo.sessionProgress.snapshot?.status, "done")
        XCTAssertEqual(f.repo.sessionProgress.snapshot?.readyChannels, 1)
        XCTAssertNil(try inbox.localJoinReceiptProof(accountId: user, scopeCid: cid))
        XCTAssertEqual(try inbox.commitPersistenceProof(accountId: user, scopeCid: cid, eventId: f.api.commitEventId)?.mlsStatePersisted, true)
        XCTAssertEqual(try inbox.localJoinBoundary(accountId: user, scopeCid: cid)?.eventId, f.api.commitEventId)
        XCTAssertEqual(try f.client.loadGroup(with: cid).epoch(), peer.group.epoch())
        XCTAssertEqual(f.api.externalJoins, 1)
        XCTAssertEqual(f.api.synced.count, 1, "Realtime delivery and receipt completion must not request another sync")
        awaitState(f) { self.hasPlaintext(f, id: duringId, text: "arrived-after-http-admission") }
        let message = try peer.message("12345678-1234-4234-8234-123456789098", at: "2026-11-19T00:00:04Z", text: "after-advanced-join")
        try injectSocket(message, into: f)
        awaitState(f) { self.hasPlaintext(f, id: "12345678-1234-4234-8234-123456789098", text: "after-advanced-join") }
    }

    func testFirstBatchUsesCanonicalReceiptSecondAndIncludesExactCommit() throws {
        try firstJoinCursor(canonicalReceipt: true)
    }

    func testInvalidReceiptContextRetainsConservativeFirstSync() throws {
        try firstJoinCursor(canonicalReceipt: true, corruptContext: true)
    }

    private func firstJoinCursor(canonicalReceipt: Bool, corruptContext: Bool = false) throws {
        let cid = "team:project:fresh-first-cursor", peer = try Peer("team:project:fresh-first-cursor")
        let f = try fixture(rows: [row(cid)], groups: [])
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.api.corruptReceiptContext = corruptContext
        let info = try peer.group.exportGroupInfo(provider: peer.provider, sender: peer.identity, withRatchetTree: true)
        f.api.groupInfo = ["channel": row(cid)["channel"] ?? [:], "group_info": info.base64EncodedString(),
            "epoch": peer.group.epoch(), "hash": SHA256.hash(data: info).map { String(format: "%02x", $0) }.joined(),
            "is_stale": false, "group_generation": 0, "external_join_prerequisite": ["reason": "active_member_recovery"]]
        f.api.onSubmission = { body in
            let commit = try XCTUnwrap((body["commit"] as? String).flatMap { Data(base64Encoded: $0) })
            _ = try peer.group.processMessage(provider: peer.provider, msg: commit)
            try peer.group.saveState(provider: peer.provider)
            if canonicalReceipt { f.api.receiptAcceptedAt = UInt64(Date().timeIntervalSince1970) }
            let time = f.api.receiptAcceptedAt.map { format.string(from: Date(timeIntervalSince1970: Double($0) + 0.15)) } ?? "2026-11-19T00:00:01Z"
            f.api.setEvents([["event_id": f.api.commitEventId, "created_at": time, "type": "protocol",
                "data": ["type": "external_commit", "epoch": body["epoch"] ?? 1, "group_generation": 0,
                    "created_at": time, "commit": body["commit"] ?? "",
                    "device_id": try XCTUnwrap(f.client.currentDeviceId), "user": ["id": self.user, "project_id": "project"]]]], scope: cid)
        }
        // Unlike the older unconditional fixture page, honor the requested cursor:
        // a timestamp after the commit must not magically return that commit.
        f.api.syncPayload = { body in
            var channels: [String: Any] = [:]
            for (scope, cursor) in body.cursors {
                if canonicalReceipt && !corruptContext, let at = f.api.receiptAcceptedAt {
                    XCTAssertEqual(cursor.createdAt, format.string(from: Date(timeIntervalSince1970: Double(at))))
                    XCTAssertEqual(cursor.eventId, "00000000-0000-0000-0000-000000000000", "Include the entire accepted second, including the exact Commit")
                } else if corruptContext {
                    XCTAssertLessThan(cursor.createdAt, "2026-11-20", "Untrusted optional context cannot select a later initial boundary")
                }
                f.api.lock.lock(); let stored = f.api.events[scope] ?? []; f.api.lock.unlock()
                let page = stored.filter {
                    let time = $0["created_at"] as? String ?? ""
                    return time > cursor.createdAt || (time == cursor.createdAt && ($0["event_id"] as? String ?? "") > cursor.eventId)
                }
                let next: Any = page.last.map { ["created_at": $0["created_at"]!, "event_id": $0["event_id"]!] as Any } ?? NSNull()
                channels[scope] = ["events": page, "has_more": false, "next_cursor": next]
            }
            return ["channels": channels]
        }
        f.updater.update(channelListQuery: query(), userId: user)
        awaitState(f) { ["done", "partial"].contains(f.repo.sessionProgress.snapshot?.status ?? "") }
        XCTAssertEqual(f.repo.sessionProgress.snapshot?.status, "done")
        XCTAssertEqual(f.repo.sessionProgress.snapshot?.readyChannels, 1)
        XCTAssertEqual(f.api.externalJoins, 1)
        XCTAssertEqual(f.api.synced.count, 1)
        XCTAssertNil(try E2eeDurableInboxStore(database: f.db).localJoinReceiptProof(accountId: user, scopeCid: cid))
    }

    func testStandardChannelsShareTotalButNeverEnterNativeBootstrap() throws {
        let secure = "team:project:secure", standard = "team:project:standard", child = "topic:project:standard-child"
        var plain = row(standard, encrypted: false, topics: [row(child, parent: standard, role: nil, encrypted: false)])
        var metadata = try XCTUnwrap(plain["channel"] as? [String: Any]); metadata["member_capabilities"] = ["send-message"]
        plain["channel"] = metadata
        let f = try fixture(rows: [row(secure), plain], groups: [secure])
        f.updater.update(channelListQuery: query(), userId: user)
        awaitState(f) { f.repo.sessionProgress.snapshot?.status == "done" }
        let state = try XCTUnwrap(f.repo.sessionProgress.snapshot)
        XCTAssertEqual(state.totalChannels, 3); XCTAssertEqual(state.readyChannels, 3)
        XCTAssertEqual(state.standardChannels, 2); XCTAssertEqual(state.totalScopes, 1)
        XCTAssertEqual(f.api.discovered, [secure: 1]); XCTAssertEqual(f.api.externalJoins, 0)
        XCTAssertThrowsError(try f.client.loadGroup(with: standard))
        XCTAssertThrowsError(try f.client.loadGroup(with: child))
    }

    func testBootstrapScopeMetadataReadDoesNotWaitForBusyMainQueue() throws {
        XCTAssertTrue(Thread.isMainThread)
        let root = "team:project:main-independent", topic = "topic:project:main-independent"
        let f = try fixture(rows: [row(root, topics: [row(topic, parent: root, role: nil)])], groups: [root])
        f.api.holdScope = root
        f.updater.update(channelListQuery: query(), userId: user)
        awaitState(f) { f.api.lock.lock(); defer { f.api.lock.unlock() }; return f.api.scopeReply != nil }
        let entered = DispatchSemaphore(value: 0), completed = DispatchSemaphore(value: 0)
        let topicId = try ChannelId(cid: topic)
        let finished = expectation(description: "Scope metadata worker finishes")
        DispatchQueue.global().async {
            entered.signal()
            XCTAssertEqual(f.repo.mlsGroupCid(for: topicId).rawValue, root)
            completed.signal(); finished.fulfill()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        // Deliberately occupy main while a background bootstrap reads committed metadata.
        // Release it after the assertion even on RED, so the fixture cannot hang teardown.
        XCTAssertEqual(completed.wait(timeout: .now() + 1), .success,
            "Background readiness metadata must not synchronously wait for the UI queue")
        wait(for: [finished], timeout: 5)
        releaseHead(f)
        awaitState(f) { f.repo.sessionProgress.snapshot?.status == "done" }
    }

    func testCompleteMetadataInventoryContinuesAllScopesWithoutScrollOrOpenAndFailuresDoNotStopTail() throws {
        let ids = (0..<12).map { String(format: "team:project:scope-%02d", $0) }
        let inherited = row("topic:project:general", parent: ids[0], scope: ids[0], role: nil)
        let child = row("topic:project:child", parent: ids[0], scope: ids[0], role: nil)
        let gated = row("topic:project:gated", parent: ids[0], scope: "topic:project:gated")
        var roots = ids.map { row($0) }
        roots[0] = row(ids[0], topics: [inherited, child, gated])
        let f = try fixture(rows: roots, topics: [gated], groups: Array(ids.dropLast()) + ["topic:project:gated"])
        f.api.failures = [ids[11]]; f.api.blocked = [ids[5]]; f.api.holdTopicPage = true
        let visible = expectation(description: "Root rows are usable while inventory is incomplete")
        f.updater.update(channelListQuery: query(), userId: user) { result in
            XCTAssertEqual(try? result.get().count, 12)
            XCTAssertNil(f.repo.sessionProgress.snapshot?.totalChannels)
            visible.fulfill()
        }
        wait(for: [visible], timeout: 5)
        awaitState(f) { f.api.lock.lock(); defer { f.api.lock.unlock() }; return f.api.topicReply != nil }
        f.api.lock.lock(); let reply = f.api.topicReply; f.api.topicReply = nil; f.api.lock.unlock(); reply?()
        awaitState(f) { f.repo.sessionProgress.snapshot?.status == "partial" && f.repo.sessionProgress.snapshot?.settledScopes == 13 }
        let state = try XCTUnwrap(f.repo.sessionProgress.snapshot)
        XCTAssertEqual(f.api.pages["roots"], [0, 5, 10])
        XCTAssertEqual(state.totalChannels, 15)
        XCTAssertEqual(state.totalScopes, 13)
        XCTAssertEqual(state.readyChannels, 13)
        XCTAssertEqual(state.blockedChannels, 1); XCTAssertEqual(state.failedChannels, 1)
        XCTAssertEqual(f.api.discovered.count, 13)
        XCTAssertTrue(f.api.discovered.values.allSatisfy { $0 == 1 })
        XCTAssertEqual(f.api.externalJoins, 0, "Valid restored groups do not External Join")
        let cycle = state.cycleId
        for _ in 0..<12 { f.repo.handleNewEncryptedChannels(try ids.map { try ChannelId(cid: $0) }) }
        let checked = expectation(description: "Serialized discovery callbacks drained")
        f.repo.localGroupEpoch(for: try ChannelId(cid: ids[0])) { _ in checked.fulfill() }
        wait(for: [checked], timeout: 5)
        XCTAssertEqual(f.repo.sessionProgress.snapshot?.cycleId, cycle)
        XCTAssertTrue(f.api.discovered.values.allSatisfy { $0 == 1 })
    }

    func testSessionPreparationRemainsUnnumberedUntilTheWholeCatchupBatchStarts() throws {
        let ids = (0..<8).map { "team:project:phase-\($0)" }
        let f = try fixture(rows: ids.map { row($0) }, groups: ids)
        f.api.holdScope = ids[0]; f.api.holdSyncScope = ids[7]
        f.updater.update(channelListQuery: query(), userId: user)
        awaitState(f) { f.api.lock.lock(); defer { f.api.lock.unlock() }; return f.api.scopeReply != nil }
        let cycle = f.repo.sessionProgress.snapshot?.cycleId
        XCTAssertEqual(f.repo.sessionProgress.snapshot?.phase, "preparing")
        releaseHead(f)
        awaitState(f) { f.api.lock.lock(); defer { f.api.lock.unlock() }; return f.api.syncReply != nil }
        XCTAssertEqual(f.repo.sessionProgress.snapshot?.phase, "readiness")
        XCTAssertEqual(f.repo.sessionProgress.snapshot?.cycleId, cycle)
        XCTAssertEqual(f.api.synced.map(\.count), [8])
        f.api.lock.lock(); let reply = f.api.syncReply; f.api.syncReply = nil; f.api.lock.unlock(); reply?()
        awaitState(f) { f.repo.sessionProgress.snapshot?.status == "done" }
        XCTAssertEqual(f.repo.sessionProgress.snapshot?.readyChannels, 8)
    }

    func testConcurrentOpenUsesAlreadyAdmittedScopeAndOldSessionResponseCannotPublish() throws {
        let ids = (0..<8).map { "team:project:scope-\($0)" }
        let f = try fixture(rows: ids.map { row($0) }, groups: ids)
        f.api.holdScope = ids[0]
        f.updater.update(channelListQuery: query(), userId: user)
        awaitState(f) { f.api.lock.lock(); defer { f.api.lock.unlock() }; return f.api.scopeReply != nil }
        let opened = expectation(description: "Open shares tail bootstrap")
        f.repo.ensureE2eeReady(for: try ChannelId(cid: ids[7])) { state in XCTAssertEqual(state, .ready); opened.fulfill() }
        f.api.lock.lock(); let reply = f.api.scopeReply; f.api.scopeReply = nil; f.api.lock.unlock(); reply?()
        wait(for: [opened], timeout: 8)
        awaitState(f) { f.repo.sessionProgress.snapshot?.readyChannels == 8 }
        XCTAssertEqual(f.api.discovered.count, 8)
        XCTAssertTrue(f.api.discovered.values.allSatisfy { $0 == 1 })
        XCTAssertEqual(f.api.externalJoins, 0)

        let oldOwner = f.repo.sessionProgress.owner
        f.repo.sessionProgress.invalidate()
        f.repo.sessionProgress.record(scope: ids[0], result: .ready, owner: oldOwner)
        XCTAssertNil(f.repo.sessionProgress.snapshot)
    }

    func testCatchupTransportFailureNeverCountsTheRequestedLocalGroupsReady() throws {
        let ids = (0..<25).map { String(format: "team:project:scope-%02d", $0) }
        let f = try fixture(rows: ids.map { row($0) }, groups: ids)
        f.api.syncFailures = [ids[3]]
        f.updater.update(channelListQuery: query(), userId: user)
        awaitState(f) { f.repo.sessionProgress.snapshot?.settledScopes == 25 }
        // The one session request failed: no successful delivery exists for any scope.
        XCTAssertEqual(f.repo.sessionProgress.snapshot?.readyChannels, 0)
        XCTAssertEqual(f.repo.sessionProgress.snapshot?.failedChannels, 25)
        XCTAssertEqual(f.repo.sessionProgress.snapshot?.status, "partial")
        XCTAssertEqual(f.api.discovered.count, 25)
        XCTAssertEqual(f.api.externalJoins, 0)
    }

    func testRealtimeDemandDuringInventoryPreparationSharesTheTwoExistingCatchupBatches() throws {
        let ids = (0..<26).map { String(format: "team:project:realtime-%02d", $0) }
        let f = try fixture(rows: ids.map { row($0) }, groups: ids)
        f.api.holdScope = ids[0]
        f.updater.update(channelListQuery: query(), userId: user)
        awaitState(f) { f.api.lock.lock(); defer { f.api.lock.unlock() }; return f.api.scopeReply != nil }
        for id in ids {
            // The protocol notification is a wakeup; preparation already owns its scope.
            f.repo.performE2eChannelSync(cid: try ChannelId(cid: id))
        }
        XCTAssertTrue(f.api.synced.isEmpty, "Realtime cannot start competing HTTP during admitted preparation")
        releaseHead(f)
        awaitState(f) { f.repo.sessionProgress.snapshot?.readyChannels == 26 && !f.repo.sessionProgress.hasPendingWork }
        XCTAssertEqual(f.api.synced.map(\.count), [26])
        XCTAssertEqual(f.api.synced.reduce(into: Set<String>()) { $0.formUnion($1) }, Set(ids))
        XCTAssertEqual(f.api.externalJoins, 0)
    }

    func testBootstrapAdmittedDuringAccountSyncReusesCompletedDelivery() throws {
        try overlappingAccountSync()
    }

    func testLateProtocolDemandAfterAccountSyncStillFetchesAgain() throws {
        try overlappingAccountSync(lateDemand: true)
    }

    func testProtocolDemandDuringAccountHTTPIsNotCoveredByItsOlderRequest() throws {
        try overlappingAccountSync(inFlightDemand: true)
    }

    func testChangedMembershipAfterAccountSyncCannotReuseOldDelivery() throws {
        try overlappingAccountSync(changedMembership: true)
    }

    func testMembershipChangedDuringAccountHTTPCannotReuseTheOldResponse() throws {
        try overlappingAccountSync(inFlightMembership: true)
    }

    private func overlappingAccountSync(lateDemand: Bool = false, changedMembership: Bool = false, inFlightDemand: Bool = false, inFlightMembership: Bool = false) throws {
        let cid = "team:project:overlap"
        let f = try fixture(rows: [row(cid)], groups: [cid])
        let saved = try payload([row(cid)])
        try f.db.writeAndWait { session in _ = try session.saveChannel(payload: saved.channels[0], query: nil, cache: nil) }
        f.api.holdSyncScope = cid
        f.repo.performE2eSync(trigger: "fixture_reconnect")
        awaitState(f) { f.api.lock.lock(); defer { f.api.lock.unlock() }; return f.api.syncReply != nil }
        f.api.holdScope = cid
        f.repo.handleNewEncryptedChannels([try ChannelId(cid: cid)])
        awaitState(f) { f.api.lock.lock(); defer { f.api.lock.unlock() }; return f.api.scopeReply != nil }
        if inFlightDemand { f.repo.performE2eChannelSync(cid: try ChannelId(cid: cid)) }
        if inFlightMembership {
            try f.db.writeAndWait { session in
                session.channel(cid: try ChannelId(cid: cid))?.membership?.memberCreatedAt = Date(timeIntervalSince1970: 1795046401).bridgeDate
            }
        }
        f.api.lock.lock(); let reply = f.api.syncReply; f.api.syncReply = nil; f.api.holdSyncScope = nil; f.api.lock.unlock()
        reply?()
        awaitState(f) { !f.repo.sessionProgress.hasPendingWork }
        if lateDemand { f.repo.performE2eChannelSync(cid: try ChannelId(cid: cid)) }
        if changedMembership {
            try f.db.writeAndWait { session in
                session.channel(cid: try ChannelId(cid: cid))?.membership?.memberCreatedAt = Date(timeIntervalSince1970: 1795046401).bridgeDate
            }
        }
        let ready = expectation(description: "Shared delivery still requires actual native readiness")
        f.repo.ensureE2eeReady(for: try ChannelId(cid: cid)) { state in XCTAssertEqual(state, .ready); ready.fulfill() }
        releaseHead(f)
        wait(for: [ready], timeout: 8)
        awaitState(f) { !f.repo.sessionProgress.hasPendingWork }
        XCTAssertEqual(f.api.synced.map(\.count), lateDemand || changedMembership || inFlightDemand || inFlightMembership ? [1, 1] : [1])
        XCTAssertEqual(f.api.externalJoins, 0)
    }

    func testRealtimeDuringTransportRetainsOneTrailingCatchup() throws {
        let cid = "team:project:late-realtime"
        let f = try fixture(rows: [row(cid)], groups: [cid])
        f.api.holdSyncScope = cid
        f.updater.update(channelListQuery: query(), userId: user)
        awaitState(f) { f.api.lock.lock(); defer { f.api.lock.unlock() }; return f.api.syncReply != nil }
        for _ in 0..<12 { f.repo.performE2eChannelSync(cid: try ChannelId(cid: cid)) }
        XCTAssertEqual(f.api.synced.count, 1)
        f.api.lock.lock(); let reply = f.api.syncReply; f.api.syncReply = nil; f.api.holdSyncScope = nil; f.api.lock.unlock()
        reply?()
        awaitState(f) { f.api.synced.count == 2 && !f.repo.sessionProgress.hasPendingWork }
        XCTAssertEqual(f.repo.sessionProgress.snapshot?.readyChannels, 1)
        XCTAssertEqual(f.api.externalJoins, 0)
    }

    private func protocolHint(_ byte: Int = 1) throws -> MLSProtocolMessagePayload {
        // Wake-up metadata only: the mock response remains empty and cannot
        // advance native state from these unauthenticated bytes.
        let value: [String: Any] = ["type": "commit", "epoch": 1, "group_generation": 0,
            "user": ["id": "peer", "project_id": "project"], "device_id": "peer-device", "commit": [byte]]
        return try JSONDecoder.default.decode(MLSProtocolMessagePayload.self, from: JSONSerialization.data(withJSONObject: value))
    }

    func testDuplicateProtocolNotificationsDuringHTTPDoNotReadAnEmptyTrailingPage() throws {
        try protocolNotificationBurst()
    }

    func testDifferentProtocolThenOldDuplicateStillRetainsTheNewDemand() throws {
        try protocolNotificationBurst(distinctThenOld: true)
    }

    func testDuplicateProtocolAfterFailedHTTPKeepsItsPendingRetry() throws {
        try protocolNotificationBurst(failed: true)
    }

    func testExplicitRepairCompletionIsNotLostWhenDuplicateProtocolIsCovered() throws {
        try protocolNotificationBurst(explicitRepair: true)
    }

    private func protocolNotificationBurst(distinctThenOld: Bool = false, failed: Bool = false, explicitRepair: Bool = false) throws {
        let raw = "team:project:duplicate-protocol", cid = try ChannelId(cid: raw)
        let f = try fixture(rows: [row(raw)], groups: [raw])
        f.updater.update(channelListQuery: query(), userId: user)
        awaitState(f) { f.repo.sessionProgress.snapshot?.readyChannels == 1 && !f.repo.sessionProgress.hasPendingWork }
        let epoch = try f.client.loadGroup(with: raw).epoch(), hint = try protocolHint()
        f.api.holdSyncScope = raw
        f.repo.performE2eChannelSync(cid: cid, protocolEvent: hint)
        awaitState(f) { f.api.lock.lock(); defer { f.api.lock.unlock() }; return f.api.syncReply != nil }
        for _ in 0..<12 { f.repo.performE2eChannelSync(cid: cid, protocolEvent: hint) }
        if distinctThenOld {
            f.repo.performE2eChannelSync(cid: cid, protocolEvent: try protocolHint(2))
            f.repo.performE2eChannelSync(cid: cid, protocolEvent: hint)
        }
        let repaired = expectation(description: "Explicit completion survives duplicate filtering")
        if explicitRepair { f.repo.repairLiveScope(cid) { _ in repaired.fulfill() } }
        else { repaired.fulfill() }
        f.api.lock.lock()
        let reply = f.api.syncReply; f.api.syncReply = nil; f.api.holdSyncScope = nil
        f.api.heldSyncFailure = failed
        f.api.lock.unlock()
        reply?()
        f.api.heldSyncFailure = false
        wait(for: [repaired], timeout: 8)
        awaitState(f) { !f.repo.sessionProgress.hasPendingWork }
        XCTAssertEqual(f.api.synced.map(\.count), distinctThenOld || failed || explicitRepair ? [1, 1, 1] : [1, 1])
        XCTAssertEqual(f.api.externalJoins, 0)
        XCTAssertEqual(try f.client.loadGroup(with: raw).epoch(), epoch, "A wake-up hint cannot advance the native epoch")
    }

    func testDeliveredInviteDoesNotRescheduleTheBootstrapTransport() throws {
        let cid = "team:project:historical-invite"
        let f = try fixture(rows: [row(cid)], groups: [cid])
        f.api.events[cid] = [["event_id": "00000000-0000-4000-8000-000000000031",
            "created_at": "2026-11-19T00:01:00Z", "type": "invite_rejected",
            "data": ["mls_enabled": true, "member": ["user_id": "other", "user": ["id": "other", "project_id": "project"], "channel_role": "member"]]]]
        f.updater.update(channelListQuery: query(), userId: user)
        awaitState(f) { f.repo.sessionProgress.snapshot?.readyChannels == 1 && !f.repo.sessionProgress.hasPendingWork }
        XCTAssertEqual(f.api.synced.map(\.count), [1], "A delivered invite is not a new realtime wakeup")
        XCTAssertEqual(f.api.externalJoins, 0)
    }

    func testFullSyncProcessesAllFortyFiveScopesInBoundedBatchesDuringQueuedBootstrap() throws {
        let ids = (0..<45).map { String(format: "team:project:scope-%02d", $0) }
        let f = try fixture(rows: ids.map { row($0) }, groups: ids)
        f.api.holdScope = ids[0]; f.updater.update(channelListQuery: query(), userId: user)
        awaitState(f) { f.api.lock.lock(); defer { f.api.lock.unlock() }; return f.api.scopeReply != nil }
        let cycle = f.repo.sessionProgress.snapshot?.cycleId
        f.repo.performE2eSync(trigger: "fixture_reconnect")
        XCTAssertTrue(f.api.synced.isEmpty, "Reconnect joins the admitted preparation before batch transport")
        releaseHead(f)
        awaitState(f) { f.repo.sessionProgress.snapshot?.readyChannels == 45 }
        XCTAssertEqual(Array(f.api.synced.prefix(3)).map(\.count), [45])
        XCTAssertEqual(f.api.synced.prefix(3).reduce(into: Set<String>()) { $0.formUnion($1) }, Set(ids))
        XCTAssertEqual(f.api.synced.count, 1)
        XCTAssertEqual(f.repo.sessionProgress.snapshot?.cycleId, cycle)
        XCTAssertEqual(f.api.discovered.count, 45)
        XCTAssertTrue(f.api.discovered.values.allSatisfy { $0 == 1 })
        XCTAssertEqual(f.api.externalJoins, 0)
    }

    func testRestartUsesDurableBootstrapMilestonesAndEmptyDeltaNeverLoadsAllNativeGroups() throws {
        let ids = (0..<13).map { "team:project:restart-\($0)" }
        let f = try fixture(rows: ids.map { row($0) }, groups: ids)
        f.updater.update(channelListQuery: query(), userId: user)
        awaitState(f) { f.repo.sessionProgress.snapshot?.readyChannels == 13 }
        f.repo.reset()
        let client = CountingMlsClient(storageFolderURL: f.root, deviceIdStore: f.devices,
            userDefaults: f.defaults, importLegacyStorage: false)
        try client.setup(with: user)
        let before = client.groupLoads, discovered = f.api.discovered
        let repo = E2eRepository(database: f.db, eventNotificationCenter: f.center, mlsClient: client, apiClient: f.api)
        let updater = ChannelListUpdater(database: f.db, apiClient: f.api, e2eRepository: repo)
        let loaded = expectation(description: "Restart metadata committed")
        updater.update(channelListQuery: query(), userId: user) { _ in loaded.fulfill() }
        wait(for: [loaded], timeout: 8)
        awaitState(f) { !repo.sessionProgress.isInventoryBootstrapDeferred }
        let batches = f.api.synced.count
        repo.performE2eSync(trigger: "fixture_restart")
        awaitState(f) { f.api.synced.count > batches && !repo.sessionProgress.hasPendingWork }
        XCTAssertEqual(client.groupLoads, before, "Empty delta must not native-load every installed group for popup readiness")
        XCTAssertEqual(f.api.discovered, discovered)
        XCTAssertEqual(f.api.externalJoins, 0)
        XCTAssertNil(repo.sessionProgress.snapshot, "Completed bootstrap is quiet on restart")
        let opened = expectation(description: "Point demand validates only its own group")
        repo.ensureE2eeReady(for: try ChannelId(cid: XCTUnwrap(ids.last))) { _ in opened.fulfill() }
        wait(for: [opened], timeout: 10)
        XCTAssertGreaterThan(client.groupLoads, before)
        XCTAssertEqual(f.api.externalJoins, 0)
        repo.reset()
        try client.setup(with: user)
        // Persisted work is re-read under the new owner, not inherited from a stale in-memory set.
        let reloaded = expectation(description: "Reused repository metadata committed")
        updater.update(channelListQuery: query(), userId: user) { _ in reloaded.fulfill() }
        wait(for: [reloaded], timeout: 8)
        awaitState(f) { !repo.sessionProgress.isInventoryBootstrapDeferred }
        XCTAssertNil(repo.sessionProgress.snapshot)
    }

    func testCompletedScopesBecomeReadyWhileOnlyAGenuineEventPageIsHeld() throws {
        let ids = (0..<45).map { String(format: "team:project:scope-%02d", $0) }
        let f = try fixture(rows: ids.map { row($0) }, groups: ids)
        let tail = ids[44]
        f.api.holdSyncScope = tail; f.api.holdSyncAfter = 1
        f.api.syncPayload = { body in
            let first = body.cursors.count == 45
            let event: [String: Any] = ["event_id": "00000000-0000-4000-8000-000000000031",
                "created_at": "2026-11-19T00:01:00Z", "type": "invite_rejected",
                "data": ["mls_enabled": true, "member": ["user_id": "other", "user": ["id": "other", "project_id": "project"], "channel_role": "member"]]]
            let channels = body.cursors.mapValues { _ in ["events": [] as [[String: Any]], "has_more": false, "next_cursor": NSNull()] as [String: Any] }
            var result = channels
            if first { result[tail] = ["events": [event], "has_more": true,
                "next_cursor": ["created_at": "2026-11-19T00:01:00Z", "event_id": "00000000-0000-4000-8000-000000000031"]] }
            return ["channels": result]
        }
        f.updater.update(channelListQuery: query(), userId: user)
        awaitState(f) { f.api.lock.lock(); defer { f.api.lock.unlock() }; return f.api.syncReply != nil }
        awaitState(f) { f.repo.sessionProgress.snapshot?.readyChannels == 44 }
        XCTAssertEqual(f.repo.sessionProgress.snapshot?.totalChannels, 45)
        XCTAssertEqual(f.api.synced.map(\.count), [45, 1])
        f.api.lock.lock(); let reply = f.api.syncReply; f.api.syncReply = nil; f.api.holdSyncScope = nil; f.api.lock.unlock()
        reply?()
        awaitState(f) { f.repo.sessionProgress.snapshot?.readyChannels == 45 }
        XCTAssertEqual(f.api.externalJoins, 0)
    }

    func testSessionBootstrapDrainsJoinPreparationBeforeItsOwnBatchSyncWithoutReconnect() throws {
        let ids = (0..<45).map { String(format: "team:project:scope-%02d", $0) }
        let f = try fixture(rows: ids.map { row($0) }, groups: ids)
        f.updater.update(channelListQuery: query(), userId: user)
        awaitState(f) { f.repo.sessionProgress.snapshot?.readyChannels == 45 }
        XCTAssertEqual(f.api.synced.map(\.count), [45])
        XCTAssertEqual(f.api.synced.reduce(into: Set<String>()) { $0.formUnion($1) }, Set(ids))
        XCTAssertEqual(f.api.discovered.count, 45)
        XCTAssertEqual(f.api.externalJoins, 0)
    }

    func testNewConnectionResumesTransportFailureOnceWithoutResetOrDuplicateBootstrap() throws {
        let ids = (0..<8).map { "team:project:scope-\($0)" }
        let f = try fixture(rows: ids.map { row($0) }, groups: ids)
        f.repo.resumeBootstrapAfterConnection("fixture-connection-a")
        f.api.failures = [ids[3]]; f.updater.update(channelListQuery: query(), userId: user)
        awaitState(f) { f.repo.sessionProgress.snapshot?.status == "partial" }
        let cycle = f.repo.sessionProgress.snapshot?.cycleId
        XCTAssertEqual(f.repo.sessionProgress.snapshot?.readyChannels, 7)
        f.api.failures = []
        for _ in 0..<8 { f.repo.resumeBootstrapAfterConnection("fixture-connection-a") }
        XCTAssertEqual(f.api.discovered[ids[3]], 1)
        for _ in 0..<8 { f.repo.resumeBootstrapAfterConnection("fixture-connection-b") }
        awaitState(f) { f.repo.sessionProgress.snapshot?.readyChannels == 8 }
        XCTAssertEqual(f.repo.sessionProgress.snapshot?.cycleId, cycle)
        XCTAssertEqual(f.api.discovered[ids[3]], 2)
        XCTAssertTrue(f.api.discovered.filter { $0.key != ids[3] }.values.allSatisfy { $0 == 1 })
        XCTAssertEqual(f.api.externalJoins, 0)
    }

    func testZeroEligibleInventoryCompletesWithoutUIJobsOrExternalJoin() throws {
        let f = try fixture(rows: [row("team:project:pending", role: "pending"), row("team:project:blocked", blocked: true)], groups: [])
        f.updater.update(channelListQuery: query(), userId: user)
        awaitState(f) { f.repo.sessionProgress.snapshot?.status == "done" }
        XCTAssertEqual(f.repo.sessionProgress.snapshot?.totalChannels, 0)
        XCTAssertTrue(f.api.discovered.isEmpty)
        XCTAssertEqual(f.api.externalJoins, 0)
    }

    func testMembershipLostWhileTopicInventoryIsPendingIsNotReintroducedByRootSnapshot() throws {
        let ids = ["team:project:a", "team:project:b"]
        let f = try fixture(rows: ids.map { row($0) }, groups: ids)
        f.api.holdTopicPage = true; f.updater.update(channelListQuery: query(), userId: user)
        awaitState(f) { f.api.lock.lock(); defer { f.api.lock.unlock() }; return f.api.topicReply != nil }
        try f.db.writeAndWait { session in
            let dto = try XCTUnwrap(session.channel(cid: try ChannelId(cid: ids[0])))
            dto.membership?.channelRoleRaw = MemberRole.pending.rawValue
        }
        f.api.lock.lock(); let reply = f.api.topicReply; f.api.topicReply = nil; f.api.lock.unlock(); reply?()
        awaitState(f) { f.repo.sessionProgress.snapshot?.status == "done" }
        XCTAssertEqual(f.repo.sessionProgress.snapshot?.totalChannels, 1)
        XCTAssertEqual(f.repo.sessionProgress.snapshot?.readyChannels, 1)
    }

    func testWholeInventoryRejectsDroppedMetadataInsteadOfPublishingShortDecodedPageAsFinal() throws {
        let f = try fixture(rows: [row("team:project:valid"), ["channel": ["invalid": true]]], groups: [])
        f.updater.update(channelListQuery: query(), userId: user)
        awaitState(f) { f.repo.sessionProgress.snapshot?.status == "partial" }
        XCTAssertNil(f.repo.sessionProgress.snapshot?.totalChannels)
        XCTAssertTrue(f.api.discovered.isEmpty)
        XCTAssertEqual(f.api.pages["roots"], [0])
        XCTAssertNil(f.api.pages["topics"])
    }

    func testInventoryMembershipAndEffectiveScopesIncludeInheritedTopicsButDoNotBorrowGatedRights() throws {
        let parent = "team:project:parent", own = "topic:project:gated"
        let child = row("topic:project:child", parent: parent, scope: parent, role: nil)
        let gated = row(own, parent: parent, scope: own, role: nil)
        let roots = try payload([row(parent, topics: [child, gated]), row("team:project:pending", role: "pending"),
            row("team:project:blocked", blocked: true), row("team:project:standard", encrypted: false)]).channels
        let initial = E2eeSessionInventory.channels(roots: roots, topics: [], userId: user)
        XCTAssertEqual(initial, [parent: parent, "topic:project:child": parent])
        let full = E2eeSessionInventory.channels(roots: roots, topics: try payload([row(own, parent: parent, scope: own)]).channels, userId: user)
        XCTAssertEqual(full[own], own)
        XCTAssertEqual(full.count, 3)
        XCTAssertTrue(E2eeSessionInventory.channels(roots: roots, topics: [], userId: "other-user").isEmpty)
        let standardGated = row("topic:project:standard-gated", parent: parent, scope: "topic:project:standard-gated", encrypted: false)
        let withStandardGated = try payload([row(parent, topics: [child, standardGated])]).channels
        XCTAssertEqual(E2eeSessionInventory.channels(roots: withStandardGated, topics: [], userId: user), [parent: parent, "topic:project:child": parent])
    }

    func testCanonicalTopicScopePersistsAndLegacyParentFallbackRemains() throws {
        let db = try database(), parent = "team:project:parent", own = "topic:project:gated"
        let rows = try payload([row(parent), row(own, parent: parent, scope: own), row("topic:project:legacy", parent: parent)]).channels
        try db.writeAndWait { session in
            for row in rows { _ = try session.saveChannel(payload: row, query: nil, cache: nil) }
            XCTAssertEqual(session.channel(cid: try ChannelId(cid: own))?.mlsGroupCid, own)
            XCTAssertEqual(session.channel(cid: try ChannelId(cid: "topic:project:legacy"))?.mlsGroupCid, parent)
        }
        var gatedWithoutScope = row("topic:project:gate-only", parent: parent, encrypted: false)
        var detail = try XCTUnwrap(gatedWithoutScope["channel"] as? [String: Any]); detail["gate"] = true; gatedWithoutScope["channel"] = detail
        try db.writeAndWait { session in
            let dto = try session.saveChannel(payload: self.payload([gatedWithoutScope]).channels[0], query: nil, cache: nil)
            XCTAssertEqual(dto.mlsGroupCid, "topic:project:gate-only")
            XCTAssertFalse(dto.isE2eeEnabled)
        }
    }

    func testMalformedMetadataCannotBeDeclaredACompleteInventory() throws {
        let dropped = try payload([row("team:project:valid"), ["channel": ["invalid": true]]])
        XCTAssertFalse(dropped.metadataComplete)
        let nested = try payload([row("team:project:valid", topics: [["channel": ["invalid": true]]])])
        XCTAssertFalse(nested.metadataComplete)
        XCTAssertFalse(try payload([row("topic:project:child", parent: "team:project:parent", scope: "team:project:unrelated")]).metadataComplete)
    }

    func testVersionEightStoreMigratesScopeMetadataWithoutChangingLegacyChannelOrInbox() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scope-migration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("chat.sqlite")
        let models = try XCTUnwrap(Bundle.ermisChat.url(forResource: "ErmisChatModel", withExtension: "momd"))
        let old = try XCTUnwrap(NSManagedObjectModel(contentsOf: models.appendingPathComponent("ErmisChatModel 8.mom")))
        XCTAssertNil(old.entitiesByName["ChannelDTO"]?.attributesByName["e2eeGroupId"])
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: old)
        let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: file, options: nil)
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        try context.performAndWait {
            let channel = NSEntityDescription.insertNewObject(forEntityName: "ChannelDTO", into: context)
            channel.setValue("topic:project:legacy", forKey: "cid"); channel.setValue("team:project:parent", forKey: "parentcid")
            channel.setValue("topic", forKey: "typeRawValue")
            channel.setValue(Date(timeIntervalSince1970: 100), forKey: "createdAt")
            channel.setValue(Date(timeIntervalSince1970: 100), forKey: "updatedAt")
            channel.setValue(true, forKey: "mlsEnabled")
            let inbox = NSEntityDescription.insertNewObject(forEntityName: "E2eeInboxEventDTO", into: context)
            inbox.setValue(self.user, forKey: "accountId"); inbox.setValue("team:project:parent", forKey: "scopeCid")
            inbox.setValue("00000000-0000-4000-8000-000000000001", forKey: "eventId")
            inbox.setValue(Date(timeIntervalSince1970: 100), forKey: "createdAt")
            inbox.setValue(Data(#"{"event_id":"00000000-0000-4000-8000-000000000001","created_at":"1970-01-01T00:01:40Z","type":"future_event","data":{}}"#.utf8), forKey: "rawEnvelope")
            try context.save(); context.reset()
        }
        try coordinator.remove(store)
        let db = try database(.onDisk(databaseFileURL: file))
        try db.writeAndWait { session in
            let channel = try XCTUnwrap(session.channel(cid: try ChannelId(cid: "topic:project:legacy")))
            XCTAssertNil(channel.e2eeGroupId); XCTAssertEqual(channel.mlsGroupCid, "team:project:parent")
            XCTAssertEqual(channel.createdAt.bridgeDate.timeIntervalSince1970, 100)
            XCTAssertTrue(channel.mlsEnabled)
            channel.e2eeGroupId = channel.cid
        }
        XCTAssertEqual(try E2eeDurableInboxStore(database: db).loadPendingEvents(accountId: user, scopeCid: "team:project:parent").map(\.eventId), ["00000000-0000-4000-8000-000000000001"])
        for store in db.persistentStoreCoordinator.persistentStores { try db.persistentStoreCoordinator.remove(store) }
        let reopened = try database(.onDisk(databaseFileURL: file))
        try reopened.writeAndWait { session in
            XCTAssertEqual(session.channel(cid: try ChannelId(cid: "topic:project:legacy"))?.mlsGroupCid, "topic:project:legacy")
        }
    }
}
