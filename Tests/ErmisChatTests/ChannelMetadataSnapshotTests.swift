import XCTest
import CoreData
@testable import ErmisChat

final class ChannelMetadataSnapshotTests: XCTestCase {
    func testPaginationIsEncodedInBackendFilterConditionsWithoutLosingMembershipFilters() throws {
        var query = ChannelListQuery(filter: .joinedChannels(memberId: "fixture", projectId: "fixture-project"), pageSize: 20)
        for offset in [0, 20, 40] {
            query.pagination = Pagination(pageSize: 20, offset: offset)
            let bytes = try JSONEncoder.ermis.encode(query)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            let filter = try XCTUnwrap(body["filter_conditions"] as? [String: Any])
            XCTAssertEqual(filter["limit"] as? Int, 20)
            XCTAssertEqual((filter["offset"] as? Int) ?? 0, offset)
            XCTAssertEqual(filter["project_id"] as? String, "fixture-project")
            XCTAssertEqual(filter["roles"] as? [String], ["owner", "moder", "member"])
            XCTAssertEqual(filter["type"] as? [String], ["messaging", "team"])
            XCTAssertNotNil(filter["members"])
            XCTAssertNil(body["bootstrap"])
        }
    }

    func testLegacyMetadataResponseDoesNotRequireAdditionalCapability() throws {
        let payload = try JSONDecoder.default.decode(ChannelListPayload.self, from: Data("{\"channels\":[]}".utf8))
        XCTAssertTrue(payload.channels.isEmpty)
    }
    func testSharedMetadataRequestUsesBaselineResponseAndRejectsRetiredSession() async throws {
        let database = DatabaseContainer(kind: .inMemory, shouldResetEphemeralValuesOnStart: false)
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !database.persistentStoreCoordinator.persistentStores.isEmpty }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 5), .completed)
        defer { for store in database.persistentStoreCoordinator.persistentStores { try? database.persistentStoreCoordinator.remove(store) } }
        let url = URL(string: "https://metadata-fixture.invalid")!, decoder = DefaultRequestDecoder(), config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        defer { FixtureProtocol.handler = nil }
        let encoder = FixtureEncoder(baseURL: url, authURL: url, stickerURL: url, apiKey: APIKey("fixture"))
        let api = APIClient(sessionConfiguration: config, requestEncoder: encoder, requestDecoder: decoder,
            uploader: ErmisUploader(uploadClient: ErmisUploadClient(encoder: encoder, decoder: decoder, sessionConfiguration: config)),
            downloader: ErmisDownloader(client: ErmisDownloadClient(sessionConfiguration: config)))
        let worker = ChannelListUpdater(database: database, apiClient: api, e2eRepository: nil)
        let query = ChannelListQuery(filter: .allChannels(memberId: "fixture", projectId: "fixture"))
        let gate = DispatchSemaphore(value: 0), requestLock = NSLock()
        var calls = 0
        FixtureProtocol.handler = { request in
            requestLock.lock(); calls += 1; requestLock.unlock()
            XCTAssertEqual(gate.wait(timeout: .now() + 3), .success)
            var bytes = request.httpBody ?? Data()
            if bytes.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count == 0 { break }; guard count > 0 else { throw E2eeArchiveError.invalidData }
                    bytes.append(contentsOf: buffer.prefix(count))
                    guard bytes.count <= 64 * 1024 else { throw E2eeArchiveError.invalidData }
                }
            }
            let body = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            XCTAssertEqual(body?["message_limit"] as? Int, 0)
            let filter = body?["filter_conditions"] as? [String: Any]
            XCTAssertEqual(filter?["limit"] as? Int, query.pagination.pageSize)
            XCTAssertEqual((filter?["offset"] as? Int) ?? 0, 0)
            return Data("{\"channels\":[]}".utf8)
        }
        let saved = expectation(description: "Shared whole metadata snapshot committed"); saved.expectedFulfillmentCount = 2
        for _ in 0..<2 {
            worker.update(channelListQuery: query, userId: "fixture") { result in
                if case .failure(let error) = result { XCTFail("\(error)") }; saved.fulfill()
            }
        }
        gate.signal()
        await fulfillment(of: [saved], timeout: 5)
        requestLock.lock(); let observedCalls = calls; requestLock.unlock()
        XCTAssertEqual(observedCalls, 1)
        FixtureProtocol.handler = { _ in api.flushRequestsQueue(); return Data("{\"channels\":[]}".utf8) }
        let rejected = expectation(description: "Retired response does not grant snapshot completeness")
        worker.update(channelListQuery: query, userId: "fixture") { result in
            if case .success = result { XCTFail("Retired session wrote metadata") }; rejected.fulfill()
        }
        await fulfillment(of: [rejected], timeout: 5)
    }
    func testWholeListLoadsAllBaselinePagesWithPreviewAndRetainsDefaultPagedQueries() async throws {
        let api = makeAPI()
        defer { FixtureProtocol.handler = nil }
        var query = ChannelListQuery(filter: .allChannels(memberId: "fixture", projectId: "fixture-project"),
            sort: [.init(key: .isPinned), .init(key: .default)], pageSize: 20, messagesLimit: 1)
        query.shouldLoadAllChannels = true
        let gate = DispatchSemaphore(value: 0), lock = NSLock()
        var offsets: [Int] = []
        FixtureProtocol.handler = { request in
            let body = try self.requestBody(request)
            let filter = try XCTUnwrap(body["filter_conditions"] as? [String: Any])
            let offset = filter["offset"] as? Int ?? 0
            XCTAssertEqual(filter["project_id"] as? String, "fixture-project")
            XCTAssertEqual(body["message_limit"] as? Int, 1)
            XCTAssertNil(body["shouldLoadAllChannels"])
            lock.lock(); offsets.append(offset); lock.unlock()
            if offset == 0 { XCTAssertEqual(gate.wait(timeout: .now() + 3), .success) }
            return try self.page(offset: offset, total: 45)
        }
        let done = expectation(description: "Both callers receive the complete shared list")
        done.expectedFulfillmentCount = 2
        for _ in 0..<2 {
            api.requestChannelMetadata(query: query) { result in
                do {
                    let channels = try result.get().channels
                    XCTAssertEqual(channels.count, 45)
                    XCTAssertEqual(Set(channels.map { $0.channel.cid }).count, 45)
                    XCTAssertEqual(channels.last?.channel.cid.rawValue, "team:fixture-project:44")
                } catch { XCTFail("\(error)") }
                done.fulfill()
            }
        }
        gate.signal()
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(offsets, [0, 20, 40])
        let config = ErmisClientConfig(apiKeyString: "fixture", endpointEnviroment: .init(baseURL: URL(string: "https://metadata-fixture.invalid")!), isErmis: false)
        XCTAssertEqual(ChannelDTO.channelListFetchRequest(query: query, clientConfig: config).fetchLimit, 0)
        query.shouldLoadAllChannels = false
        XCTAssertEqual(ChannelDTO.channelListFetchRequest(query: query, clientConfig: config).fetchLimit, 20)
        FixtureProtocol.handler = { request in
            XCTAssertEqual((try self.requestBody(request)["filter_conditions"] as? [String: Any])?["offset"] as? Int ?? 0, 0)
            return try self.page(offset: 0, total: 45)
        }
        let paged = expectation(description: "Ordinary paged query still returns one page")
        api.requestChannelMetadata(query: query) { result in
            XCTAssertEqual(try? result.get().channels.count, 20); paged.fulfill()
        }
        await fulfillment(of: [paged], timeout: 5)
    }

    func testWholeListRejectsRepeatedFullPageInsteadOfPublishingIncompleteSuccess() async throws {
        let api = makeAPI()
        defer { FixtureProtocol.handler = nil }
        var query = ChannelListQuery(filter: .allChannels(memberId: "fixture", projectId: "fixture-project"), pageSize: 20, messagesLimit: 1)
        query.shouldLoadAllChannels = true
        var calls = 0
        FixtureProtocol.handler = { _ in calls += 1; return try self.page(offset: 0, total: 45) }
        let failed = expectation(description: "Repeated page fails without retry loop")
        api.requestChannelMetadata(query: query) { result in
            if case .success = result { XCTFail("Repeated page published incomplete list") }
            failed.fulfill()
        }
        await fulfillment(of: [failed], timeout: 5)
        XCTAssertEqual(calls, 2)
    }

    func testRecoveryLoadsEveryPageWhileNormalQueueIsSuspended() async throws {
        let api = makeAPI()
        api.enterRecoveryMode()
        defer { api.exitRecoveryMode(); FixtureProtocol.handler = nil }
        var query = ChannelListQuery(filter: .allChannels(memberId: "fixture", projectId: "fixture-project"), messagesLimit: 1)
        query.shouldLoadAllChannels = true
        var offsets: [Int] = []
        FixtureProtocol.handler = { request in
            let filter = try XCTUnwrap(self.requestBody(request)["filter_conditions"] as? [String: Any])
            let offset = filter["offset"] as? Int ?? 0
            offsets.append(offset)
            return try self.page(offset: offset, total: 45)
        }
        let done = expectation(description: "Recovery does not depend on suspended regular queue")
        api.requestChannelMetadata(query: query, isRecovery: true) { result in
            XCTAssertEqual(try? result.get().channels.count, 45); done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(offsets, [0, 20, 40])
    }


    func testMetadataWriterPreservesAllSavedIdentitiesAcrossWholeListBatches() async throws {
        let database = DatabaseContainer(kind: .inMemory, shouldResetEphemeralValuesOnStart: false)
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !database.persistentStoreCoordinator.persistentStores.isEmpty
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 5), .completed)
        let api = makeAPI()
        defer { FixtureProtocol.handler = nil }
        let worker = ChannelListUpdater(database: database, apiClient: api, e2eRepository: nil)
        var query = ChannelListQuery(filter: .allChannels(memberId: "fixture", projectId: "fixture-project"), messagesLimit: 1)
        query.shouldLoadAllChannels = true
        FixtureProtocol.handler = { request in
            let filter = try XCTUnwrap(self.requestBody(request)["filter_conditions"] as? [String: Any])
            return try self.page(offset: filter["offset"] as? Int ?? 0, total: 94)
        }
        let finished = expectation(description: "All paged metadata saved before completeness")
        worker.update(channelListQuery: query, userId: "fixture") { result in
            do {
                let ids = try result.get().map(\.cid)
                XCTAssertEqual(ids.count, 94)
                XCTAssertEqual(Set(ids).count, 94)
                XCTAssertEqual(ids.first?.rawValue, "team:fixture-project:0")
                XCTAssertEqual(ids.last?.rawValue, "team:fixture-project:93")
            } catch { XCTFail("Metadata write failed") }
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 5)
    }

    func testSynthetic94RootMappingCostSeparatesPersistenceFromUnusedWriterModels() throws {
        let database = DatabaseContainer(kind: .inMemory, shouldResetEphemeralValuesOnStart: false)
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !database.persistentStoreCoordinator.persistentStores.isEmpty
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 5), .completed)
        let rows: [[String: Any]] = (0..<94).map { n in
            let members: [[String: Any]] = (0..<8).map { m in
                ["user_id": "fixture-member-\(m)", "user": ["id": "fixture-member-\(m)", "name": "Fixture"], "channel_role": "member"]
            }
            let channel: [String: Any] = ["cid": "team:fixture-project:bench-\(n)", "type": "team",
                "created_at": "2026-11-19T00:00:00Z", "updated_at": "2026-11-19T00:00:00Z",
                "member_count": 8, "members": members, "mls_enabled": false]
            return ["channel": channel, "messages": [], "read": []]
        }
        let payload = try JSONDecoder.default.decode(ChannelListPayload.self,
            from: JSONSerialization.data(withJSONObject: ["channels": rows]))
        let query = ChannelListQuery(filter: .allChannels(memberId: "fixture", projectId: "fixture-project"))
        let saved = expectation(description: "Synthetic mapping cost measured on actual Core Data writer")
        database.write { session in
            let start = ProcessInfo.processInfo.systemUptime
            let dtos = session.saveChannelList(payload: payload, query: query)
            let persisted = ProcessInfo.processInfo.systemUptime
            let models = dtos.compactMap { try? $0.asModel() }
            let mapped = ProcessInfo.processInfo.systemUptime
            let ids = dtos.compactMap { try? ChannelId(cid: $0.cid) }
            let identified = ProcessInfo.processInfo.systemUptime
            XCTAssertEqual(models.map(\.cid), ids)
            XCTAssertEqual(ids.count, 94)
            print("channel_list_fixture roots=94 members_per_root=8 save_ms=\(Int((persisted-start)*1000)) eager_model_ms=\(Int((mapped-persisted)*1000)) identity_ms=\(Int((identified-mapped)*1000))")
        } completion: { error in XCTAssertNil(error); saved.fulfill() }
        wait(for: [saved], timeout: 5)
    }


    private final class PausedSecondBatchDatabase: DatabaseContainer {
        private let lock = NSLock()
        private var writes = 0
        private var held: (() -> Void)?
        var isPaused: Bool { lock.lock(); defer { lock.unlock() }; return held != nil }
        override func write(_ actions: @escaping (DatabaseSession) throws -> Void,
                            completion: @escaping (Error?) -> Void, file: StaticString = #fileID, line: UInt = #line) {
            lock.lock(); writes += 1
            if writes == 2 {
                held = { [weak self] in self?.resumeWrite(actions, completion: completion, file: file, line: line) }
                lock.unlock()
            } else {
                lock.unlock(); super.write(actions, completion: completion, file: file, line: line)
            }
        }
        private func resumeWrite(_ actions: @escaping (DatabaseSession) throws -> Void,
                                 completion: @escaping (Error?) -> Void, file: StaticString, line: UInt) {
            super.write(actions, completion: completion, file: file, line: line)
        }
        func arm() { lock.lock(); writes = 0; lock.unlock() }
        func releaseBatch() { lock.lock(); let work = held; held = nil; lock.unlock(); work?() }
    }

    func testWholeListFirstBatchIsReadableBeforeCompletionAndPreservesLiveRows() async throws {
        try await checkWholeListBatches(retireBeforeSecondBatch: false)
    }
    func testRetiredWholeListBatchCannotWriteTailOrClaimCompleteness() async throws {
        try await checkWholeListBatches(retireBeforeSecondBatch: true)
    }
    private func checkWholeListBatches(retireBeforeSecondBatch: Bool) async throws {
        let database = PausedSecondBatchDatabase(kind: .inMemory, shouldResetEphemeralValuesOnStart: false)
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !database.persistentStoreCoordinator.persistentStores.isEmpty
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 5), .completed)
        let api = makeAPI()
        defer { FixtureProtocol.handler = nil; database.releaseBatch() }
        var query = ChannelListQuery(filter: .allChannels(memberId: "fixture", projectId: "fixture-project"), messagesLimit: 1)
        query.shouldLoadAllChannels = true
        database.arm()
        FixtureProtocol.handler = { request in
            let filter = try XCTUnwrap(self.requestBody(request)["filter_conditions"] as? [String: Any])
            return try self.page(offset: filter["offset"] as? Int ?? 0, total: 45)
        }
        let completed = expectation(description: "Only the final batch can complete the list")
        var completionCalled = false
        let worker = ChannelListUpdater(database: database, apiClient: api, e2eRepository: nil)
        worker.update(channelListQuery: query, userId: "fixture") { result in
            completionCalled = true
            if retireBeforeSecondBatch {
                if case .success = result { XCTFail("Retired snapshot claimed completeness") }
            } else { XCTAssertEqual(try? result.get().count, 45) }
            completed.fulfill()
        }
        let paused = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in database.isPaused }, object: nil)
        await fulfillment(of: [paused], timeout: 5)
        XCTAssertFalse(completionCalled)
        func queryIds() -> Set<String> {
            var ids = Set<String>()
            database.viewContext.performAndWait {
                database.viewContext.refreshAllObjects()
                ids = Set(database.viewContext.channelListQuery(filterHash: query.filter.filterHash)?.channels.map(\.cid) ?? [])
            }
            return ids
        }
        let prefix = queryIds()
        XCTAssertEqual(prefix.count, 20, "20 real metadata rows are readable before the remaining batches finish")
        if retireBeforeSecondBatch {
            api.flushRequestsQueue()
        } else {
            let live = try JSONDecoder.default.decode(ChannelListPayload.self, from: page(offset: 99, total: 100))
            let saved = expectation(description: "Live event links while metadata tail is paused")
            database.write { session in session.saveChannelList(payload: live, query: query) }
                completion: { error in XCTAssertNil(error); saved.fulfill() }
            await fulfillment(of: [saved], timeout: 2)
        }
        database.releaseBatch()
        await fulfillment(of: [completed], timeout: 5)
        let finalIds = queryIds()
        if retireBeforeSecondBatch {
            XCTAssertEqual(finalIds, prefix)
        } else {
            XCTAssertEqual(finalIds.count, 46)
            XCTAssertFalse(finalIds.contains("team:fixture-project:400"))
            XCTAssertTrue(finalIds.contains("team:fixture-project:99"), "Live row survives final snapshot pruning")
        }
    }


    func testWholeListWarmRefreshKeepsOriginalSingleAtomicWrite() async throws {
        let database = PausedSecondBatchDatabase(kind: .inMemory, shouldResetEphemeralValuesOnStart: false)
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !database.persistentStoreCoordinator.persistentStores.isEmpty
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 5), .completed)
        let api = makeAPI()
        defer { FixtureProtocol.handler = nil; database.releaseBatch() }
        var query = ChannelListQuery(filter: .allChannels(memberId: "fixture", projectId: "fixture-project"), messagesLimit: 1)
        query.shouldLoadAllChannels = true
        let old = try JSONDecoder.default.decode(ChannelListPayload.self, from: page(offset: 400, total: 401))
        let seeded = expectation(description: "Warm query exists")
        database.write { session in session.saveChannelList(payload: old, query: query) }
            completion: { error in XCTAssertNil(error); seeded.fulfill() }
        await fulfillment(of: [seeded], timeout: 2)
        database.arm()
        FixtureProtocol.handler = { request in
            let filter = try XCTUnwrap(self.requestBody(request)["filter_conditions"] as? [String: Any])
            return try self.page(offset: filter["offset"] as? Int ?? 0, total: 45)
        }
        let done = expectation(description: "Warm atomic snapshot is complete")
        let worker = ChannelListUpdater(database: database, apiClient: api, e2eRepository: nil)
        worker.update(channelListQuery: query, userId: "fixture") { result in
            XCTAssertEqual(try? result.get().count, 45); done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5)
        XCTAssertFalse(database.isPaused, "Warm path must not submit a second batch write")
        database.viewContext.performAndWait {
            database.viewContext.refreshAllObjects()
            let ids = Set(database.viewContext.channelListQuery(filterHash: query.filter.filterHash)?.channels.map(\.cid) ?? [])
            XCTAssertEqual(ids.count, 45)
            XCTAssertFalse(ids.contains("team:fixture-project:400"))
        }
    }

    private func requestBody(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count == 0 { break }
                guard count > 0 else { throw E2eeArchiveError.invalidData }
                data.append(contentsOf: buffer.prefix(count))
                guard data.count < 65536 else { throw E2eeArchiveError.invalidData }
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func page(offset: Int, total: Int) throws -> Data {
        let channels: [[String: Any]] = (offset..<min(offset + 20, total)).map { index in
            ["channel": ["cid": "team:fixture-project:\(index)", "type": "team", "save_message": true,
                "last_message_at": "2026-08-07T02:00:00.000Z", "created_at": "2026-08-07T01:00:00.000Z",
                "updated_at": "2026-08-07T02:00:00.000Z", "member_count": 2, "mls_enabled": false],
             "messages": [], "read": []]
        }
        return try JSONSerialization.data(withJSONObject: ["channels": channels])
    }

    private func makeAPI() -> APIClient {
        let url = URL(string: "https://metadata-fixture.invalid")!, decoder = DefaultRequestDecoder(), config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        let encoder = FixtureEncoder(baseURL: url, authURL: url, stickerURL: url, apiKey: APIKey("fixture"))
        return APIClient(sessionConfiguration: config, requestEncoder: encoder, requestDecoder: decoder,
            uploader: ErmisUploader(uploadClient: ErmisUploadClient(encoder: encoder, decoder: decoder, sessionConfiguration: config)),
            downloader: ErmisDownloader(client: ErmisDownloadClient(sessionConfiguration: config)))
    }

    private final class FixtureProtocol: URLProtocol {
        static var handler: ((URLRequest) throws -> Data)?
        override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "metadata-fixture.invalid" }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            do {
                let bytes = try Self.handler?(request) ?? Data()
                let response = try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil))
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: bytes); client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
        override func stopLoading() {}
    }
    private final class FixtureEncoder: DefaultRequestEncoder {
        override func encodeRequest<ResponsePayload: Decodable>(for endpoint: Endpoint<ResponsePayload>, completion: @escaping (Result<URLRequest, Error>) -> Void) {
            do {
                var request = URLRequest(url: baseURL.appendingPathComponent(endpoint.path.value)); request.httpMethod = endpoint.method.rawValue
                if let body = endpoint.body { request.httpBody = try JSONEncoder.ermis.encode(AnyEncodable(body)) }
                completion(.success(request))
            } catch { completion(.failure(error)) }
        }
    }
}
