import XCTest
@testable import ErmisChat
import open_mls_ios

final class MlsKeyPackageWorkTests: XCTestCase {
    private final class ExpiredMlsEncoder: DefaultRequestEncoder {
        var calls = 0
        var alwaysExpired = false
        override func encodeRequest<ResponsePayload: Decodable>(for endpoint: Endpoint<ResponsePayload>, completion: @escaping (Result<URLRequest, Error>) -> Void) {
            calls += 1
            if calls == 1 || alwaysExpired { completion(.failure(ClientError.ExpiredToken())) }
            else { completion(.success(URLRequest(url: baseURL))) }
        }
    }
    func testScopedEncoding401RefreshRetriesOnceWithinOriginalDeadline() throws {
        let base = try XCTUnwrap(URL(string: "https://key-package.invalid"))
        let encoder = ExpiredMlsEncoder(baseURL: base, authURL: base, stickerURL: base, apiKey: APIKey("fixture"))
        let decoder = DefaultRequestDecoder(), config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        let api = APIClient(sessionConfiguration: config, requestEncoder: encoder, requestDecoder: decoder,
            uploader: ErmisUploader(uploadClient: ErmisUploadClient(encoder: encoder, decoder: decoder, sessionConfiguration: config)),
            downloader: ErmisDownloader(client: ErmisDownloadClient(sessionConfiguration: config)))
        defer { api.session.invalidateAndCancel(); FixtureProtocol.handler = nil }
        var refreshes = 0
        api.tokenRefresher = { done in refreshes += 1; done(nil) }
        FixtureProtocol.handler = { _ in (200, Data(#"{"version":1,"entries":[],"next_cursor":null}"#.utf8)) }
        let completed = expectation(description: "one scoped encoding refresh")
        api.request(endpoint: Endpoint<MlsOwnershipInventory>.keyPackageOwnership(nil).scopedMls(deadline: Date().addingTimeInterval(2)) {}) { result in
            XCTAssertEqual(try? result.get().version, 1); completed.fulfill()
        }
        wait(for: [completed], timeout: 3)
        XCTAssertEqual(refreshes, 1); XCTAssertEqual(encoder.calls, 2)
        withExtendedLifetime(api) {}
    }
    func testScopedRefreshHangExpiresAndLateRefreshCannotRestartEncoding() throws {
        try scopedRefreshTerminal(alwaysExpired: false, holdRefresh: true)
    }
    func testScopedRepeated401StopsAfterOneRefresh() throws {
        try scopedRefreshTerminal(alwaysExpired: true, holdRefresh: false)
    }
    private func scopedRefreshTerminal(alwaysExpired: Bool, holdRefresh: Bool) throws {
        let base = try XCTUnwrap(URL(string: "https://key-package.invalid"))
        let encoder = ExpiredMlsEncoder(baseURL: base, authURL: base, stickerURL: base, apiKey: APIKey("fixture"))
        encoder.alwaysExpired = alwaysExpired
        let decoder = DefaultRequestDecoder(), config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        let api = APIClient(sessionConfiguration: config, requestEncoder: encoder, requestDecoder: decoder,
            uploader: ErmisUploader(uploadClient: ErmisUploadClient(encoder: encoder, decoder: decoder, sessionConfiguration: config)),
            downloader: ErmisDownloader(client: ErmisDownloadClient(sessionConfiguration: config)))
        defer { api.session.invalidateAndCancel(); FixtureProtocol.handler = nil }
        var refreshes = 0, completions = 0, held: ((Error?) -> Void)?
        api.tokenRefresher = { done in refreshes += 1; if holdRefresh { held = done } else { done(nil) } }
        FixtureProtocol.handler = { _ in XCTFail("Terminal scoped auth must not reach HTTP"); return (500, Data()) }
        let completed = expectation(description: "finite scoped refresh")
        api.request(endpoint: Endpoint<MlsOwnershipInventory>.keyPackageOwnership(nil).scopedMls(deadline: Date().addingTimeInterval(0.15)) {}) { result in
            completions += 1
            if case .success = result { XCTFail("Auth must remain failed") }
            completed.fulfill()
        }
        wait(for: [completed], timeout: 0.75)
        held?(nil)
        let drained = expectation(description: "late refresh drained")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { drained.fulfill() }
        wait(for: [drained], timeout: 1)
        XCTAssertEqual(completions, 1); XCTAssertEqual(encoder.calls, holdRefresh ? 1 : 2)
        // The failed retry can observe401 once, but must not launch another refresh.
        XCTAssertEqual(refreshes, 1)
        withExtendedLifetime(api) {}
    }

    private final class HeldMlsEncoder: DefaultRequestEncoder {
        var entered: (() -> Void)?
        var release: (() -> Void)?
        override func encodeRequest<ResponsePayload: Decodable>(for endpoint: Endpoint<ResponsePayload>, completion: @escaping (Result<URLRequest, Error>) -> Void) {
            release = { completion(.success(URLRequest(url: self.baseURL))) }
            entered?()
        }
    }
    func testScopedDeadlineCompletesWhileEncodingIsHeldAndLateEncodingCannotSend() throws {
        let base = try XCTUnwrap(URL(string: "https://key-package.invalid"))
        let encoder = HeldMlsEncoder(baseURL: base, authURL: base, stickerURL: base, apiKey: APIKey("fixture"))
        let decoder = DefaultRequestDecoder(), config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        let api = APIClient(sessionConfiguration: config, requestEncoder: encoder, requestDecoder: decoder,
            uploader: ErmisUploader(uploadClient: ErmisUploadClient(encoder: encoder, decoder: decoder, sessionConfiguration: config)),
            downloader: ErmisDownloader(client: ErmisDownloadClient(sessionConfiguration: config)))
        defer { api.session.invalidateAndCancel(); FixtureProtocol.handler = nil; encoder.release = nil }
        var requests = 0, completions = 0
        FixtureProtocol.handler = { _ in requests += 1; return (200, Data(#"{"version":1,"entries":[],"next_cursor":null}"#.utf8)) }
        let entered = expectation(description: "encoding held"), expired = expectation(description: "whole-operation deadline")
        encoder.entered = { entered.fulfill() }
        api.request(endpoint: Endpoint<MlsOwnershipInventory>.keyPackageOwnership(nil).scopedMls(deadline: Date().addingTimeInterval(0.15)) {}) { result in
            completions += 1
            if case .success = result { XCTFail("Held encoding must expire") }
            expired.fulfill()
        }
        wait(for: [entered], timeout: 1)
        wait(for: [expired], timeout: 0.75)
        encoder.release?()
        let drained = expectation(description: "late encoding drained")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { drained.fulfill() }
        wait(for: [drained], timeout: 1)
        XCTAssertEqual(completions, 1); XCTAssertEqual(requests, 0)
        withExtendedLifetime(api) {}
    }
    func testScopedDeadlineIncludesSuspendedAuthQueueAndCannotEncodeAfterResume() throws {
        let base = try XCTUnwrap(URL(string: "https://key-package.invalid"))
        let encoder = HeldMlsEncoder(baseURL: base, authURL: base, stickerURL: base, apiKey: APIKey("fixture"))
        let decoder = DefaultRequestDecoder(), config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        let api = APIClient(sessionConfiguration: config, requestEncoder: encoder, requestDecoder: decoder,
            uploader: ErmisUploader(uploadClient: ErmisUploadClient(encoder: encoder, decoder: decoder, sessionConfiguration: config)),
            downloader: ErmisDownloader(client: ErmisDownloadClient(sessionConfiguration: config)))
        defer { api.exitTokenFetchMode(); api.session.invalidateAndCancel(); encoder.release = nil }
        var encodings = 0, completions = 0
        encoder.entered = { encodings += 1 }
        api.enterTokenFetchMode()
        let expired = expectation(description: "deadline includes queued auth wait")
        api.request(endpoint: Endpoint<MlsOwnershipInventory>.keyPackageOwnership(nil).scopedMls(deadline: Date().addingTimeInterval(0.15)) {}) { result in
            completions += 1
            if case .success = result { XCTFail("Queued request must expire") }
            expired.fulfill()
        }
        wait(for: [expired], timeout: 0.75)
        XCTAssertEqual(encodings, 0)
        api.exitTokenFetchMode()
        let resumed = expectation(description: "expired queue drained")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { resumed.fulfill() }
        wait(for: [resumed], timeout: 1)
        XCTAssertEqual(encodings, 0); XCTAssertEqual(completions, 1)
        withExtendedLifetime(api) {}
    }

    private final class SecureStore: MlsDeviceIdSecureStoring {
        var values: [String:String] = [:]
        func load(userId: String) throws -> String? { values[userId] }
        func save(deviceId: String, userId: String) throws { values[userId] = deviceId }
        func remove(userId: String) throws { values.removeValue(forKey: userId) }
    }
    private final class FixtureProtocol: URLProtocol {
        static var handler: ((URLRequest) throws -> (Int, Data))?
        override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "key-package.invalid" }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            do {
                let (status, bytes) = try Self.handler?(request) ?? (500, Data())
                let response = try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: status, httpVersion: nil, headerFields: nil))
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: bytes); client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
        override func stopLoading() {}
    }
    private final class FixtureEncoder: DefaultRequestEncoder {
        override func encodeRequest<ResponsePayload: Decodable>(for endpoint: Endpoint<ResponsePayload>, completion: @escaping (Result<URLRequest, Error>) -> Void) {
            do {
                var request = URLRequest(url: baseURL.appendingPathComponent(endpoint.path.value))
                request.httpMethod = endpoint.method.rawValue
                for (key,value) in endpoint.headers { request.setValue(value, forHTTPHeaderField: key) }
                if let body = endpoint.body { request.httpBody = try JSONEncoder.ermis.encode(AnyEncodable(body)) }
                completion(.success(request))
            } catch { completion(.failure(error)) }
        }
    }
    private func fixtureAPI() throws -> APIClient {
        let base = try XCTUnwrap(URL(string:"https://key-package.invalid"))
        let encoder = FixtureEncoder(baseURL:base,authURL:base,stickerURL:base,apiKey:APIKey("fixture")), decoder = DefaultRequestDecoder()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureProtocol.self]
        return APIClient(sessionConfiguration:config,requestEncoder:encoder,requestDecoder:decoder,
            uploader:ErmisUploader(uploadClient:ErmisUploadClient(encoder:encoder,decoder:decoder,sessionConfiguration:config)),
            downloader:ErmisDownloader(client:ErmisDownloadClient(sessionConfiguration:config)))
    }
    private func fixture(_ body: (MlsClient, MlsKeyPackageWorkStore) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lor-kp-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "lor-kp-work-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let deviceStore = MlsDeviceIdStore(defaults: defaults, legacyDefaults: defaults, secureStore: SecureStore())
        let client = MlsClient(storageFolderURL: root, deviceIdStore: deviceStore, userDefaults: defaults)
        try client.setup(with: "local-key-package-work")
        XCTAssertNotNil(client.currentDeviceId)
        let provider = try XCTUnwrap(client.provider), identity = try XCTUnwrap(client.identity)
        XCTAssertEqual(try provider.loadIdentity(), try identity.toBytes())
        try body(client, client.keyPackageWorkStore(origin: "https://fixture.invalid"))
    }
    func testExactPublicBatchAndPrivateRefsSurviveRestart() throws {
        try fixture { client, store in
            let batch = try client.generateKeyPackageBatch(count: 3)
            let original = try store.read()
            var pending = original
            pending.upload = .init(id: UUID().uuidString, status: "ready", createdAt: Date().timeIntervalSince1970,
                                   bytes: batch.map { $0.0 }, refs: batch.map { $0.1 }, attempts: 2, retryAt: Date().timeIntervalSince1970 + 60)
            _ = try store.write(expected: original, next: pending)
            let reopened = MlsKeyPackageWorkStore(root: store.url.deletingLastPathComponent(), scope: store.scope)
            XCTAssertEqual(try reopened.read(), pending)
            XCTAssertEqual(try client.probeKeyPackageOwnership(batch.map { $0.1 }), [true, true, true])
            let provider = try XCTUnwrap(client.provider); let identityBytes = try XCTUnwrap(provider.loadIdentity())
            let identity = try Identity.fromBytes(provider: provider, data: identityBytes)
            for item in batch { XCTAssertTrue(try identity.ownsKeyPackageRef(provider: provider, reference: item.1)) }
        }
    }
    func testFullRecordCASPreservesWinnerAndPendingBatch() throws {
        try fixture { _, store in
            let original = try store.read()
            var first = original; first.leaseId = UUID().uuidString; first.leaseUntil = Date().timeIntervalSince1970 + 30
            let winner = try store.write(expected: original, next: first)
            var stale = original; stale.attempts = 99
            XCTAssertThrowsError(try store.write(expected: original, next: stale))
            XCTAssertEqual(try store.read(), winner)
        }
    }
    func testOpaqueCorruptAndOversizeRowsAreRetained() throws {
        try fixture { _, store in
            try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            for raw in [Data("{\"version\":99}".utf8), Data("broken".utf8), Data(repeating: 0, count: 4 * 1024 * 1024 + 1)] {
                try raw.write(to: store.url)
                XCTAssertThrowsError(try store.read())
                XCTAssertEqual(try Data(contentsOf: store.url), raw)
            }
        }
    }
    func testAbsentForeignAndUncertainProbeStayDistinct() throws {
        try fixture { client, _ in
            let foreignProvider = Provider(); let foreign = try Identity(provider: foreignProvider, userId: "foreign")
            let kp = try foreign.keyPackage(provider: foreignProvider)
            XCTAssertEqual(try client.probeKeyPackageOwnership([kp.hashRef(provider: foreignProvider)]), [false])
            XCTAssertThrowsError(try client.probeKeyPackageOwnership([Data([1, 2])]))
            client.provider = nil
            XCTAssertThrowsError(try client.probeKeyPackageOwnership([Data(repeating: 0, count: 32)]))
        }
    }
    func testFullRetryQueueCannotBeSilentlyTruncated() throws {
        try fixture { _, store in
            let original = try store.read(); var full = original
            full.retries = (1...16).map { .init(cursor: .init(id: String(format: "00000000-0000-4000-8000-%012d", $0), created_at: "2026-10-18T00:00:00.000Z"), attempts: $0, retryAt: Date().timeIntervalSince1970 + 60) }
            _ = try store.write(expected: original, next: full)
            var over = full; over.retries.append(.init(cursor: nil, attempts: 1, retryAt: 1))
            XCTAssertThrowsError(try store.write(expected: full, next: over))
            XCTAssertEqual(try store.read(), full)
        }
    }
    func testScopedEndpointDoesNotSerializeRuntimeAuthority() throws {
        let deadline = Date().addingTimeInterval(30)
        let endpoint = Endpoint<MlsOwnershipInventory>.keyPackageOwnership(nil).scopedMls(deadline: deadline) { throw ClientError.Unexpected("stale") }
        let bytes = try JSONEncoder().encode(endpoint)
        let decoded = try JSONDecoder().decode(Endpoint<MlsOwnershipInventory>.self, from: bytes)
        XCTAssertNil(decoded.localMlsGuard); XCTAssertNil(decoded.localMlsDeadline)
    }
    func testLostAckReopenRetriesExactBatchBeforeChangedCount() throws {
        try fixture { client, store in
            let api = try fixtureAPI(); defer { api.session.invalidateAndCancel(); FixtureProtocol.handler = nil }
            var uploads: [Data] = [], ids: [String] = [], lost = true, countCalls = 0, generated = 0
            FixtureProtocol.handler = { request in
                let route = request.url?.path ?? ""
                if route.hasSuffix("ownership/inventory") { return (200,Data(#"{"version":1,"entries":[],"next_cursor":null}"#.utf8)) }
                if route.hasSuffix("/count") {
                    countCalls += 1
                    return (200,Data((lost ? #"{"remaining":98,"target":100,"low_watermark":99,"requested_delta":2,"refill_generation":1}"# : #"{"remaining":100,"target":100,"low_watermark":99,"requested_delta":0,"refill_generation":null}"#).utf8))
                }
                uploads.append(request.httpBody ?? Data()); let id = try XCTUnwrap(request.value(forHTTPHeaderField:"X-Ermis-MLS-Upload-Operation")); ids.append(id)
                if lost { lost = false; throw URLError(.networkConnectionLost) }
                return (200,try JSONSerialization.data(withJSONObject:["stored":0,"total_remaining":100,"target":100,"low_watermark":99,"requested_delta":0,"refill_generation":NSNull(),"batch_id":id,"validation_version":1]))
            }
            var clock = Date()
            let firstDone = expectation(description:"lost ACK retained")
            let first = try MlsKeyPackagePipeline(api:api,store:store,assertOwner:{},probe:{try client.probeKeyPackageOwnership($0)},
                providerId:{try client.keyPackageUploadProviderId()},generate:{id,pid,count in generated += 1;return try client.prepareKeyPackageUpload(id:id,scope:store.scope,nativeProviderId:pid,count:count)},now:{clock},completion:{_ in firstDone.fulfill()})
            first.start(reason:"manual");wait(for:[firstDone],timeout:5)
            let retained = try XCTUnwrap(store.read().upload); XCTAssertEqual(retained.status,"ready"); XCTAssertEqual(retained.attempts,1)
            let root = store.url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let reopened = MlsClient(storageFolderURL:root,deviceIdStore:client.deviceIdStore,userDefaults:client.userDefaults)
            try reopened.setup(with:"local-key-package-work")
            clock = clock.addingTimeInterval(31)
            let nextDone = expectation(description:"same batch after reopen")
            let next = try MlsKeyPackagePipeline(api:api,store:store,assertOwner:{},probe:{try reopened.probeKeyPackageOwnership($0)},
                providerId:{try reopened.keyPackageUploadProviderId()},generate:{id,pid,count in generated += 1;return try reopened.prepareKeyPackageUpload(id:id,scope:store.scope,nativeProviderId:pid,count:count)},now:{clock},completion:{_ in nextDone.fulfill()})
            next.start(reason:"manual");wait(for:[nextDone],timeout:5)
            XCTAssertEqual(uploads.count,2);XCTAssertEqual(uploads.first,uploads.last);XCTAssertEqual(ids,[retained.id,retained.id]);XCTAssertEqual(generated,1)
            XCTAssertNil(try store.read().upload);XCTAssertEqual(try reopened.probeKeyPackageOwnership(retained.refs),[true,true]);XCTAssertEqual(countCalls,2)
            withExtendedLifetime([first,next,api]) {}
        }
    }
    func testCanonicalBatchRejectionIsRetainedSeparatelyFromUnknownTransport() throws {
        try fixture { client, store in
            let api = try fixtureAPI(); defer { api.session.invalidateAndCancel();FixtureProtocol.handler = nil }
            FixtureProtocol.handler = { request in
                let route=request.url?.path ?? ""
                if route.hasSuffix("ownership/inventory") {return(200,Data(#"{"version":1,"entries":[],"next_cursor":null}"#.utf8))}
                if route.hasSuffix("/count") {return(200,Data(#"{"remaining":99,"target":100,"low_watermark":99,"requested_delta":1,"refill_generation":1}"#.utf8))}
                let id=try XCTUnwrap(request.value(forHTTPHeaderField:"X-Ermis-MLS-Upload-Operation"))
                return(400,try JSONSerialization.data(withJSONObject:["reason":"key_package_validation_failed","batch_id":id,"errors":[["index":0,"code":"expired"]]]))
            }
            let done=expectation(description:"typed retained rejection")
            let work=try MlsKeyPackagePipeline(api:api,store:store,assertOwner:{},probe:{try client.probeKeyPackageOwnership($0)},providerId:{try client.keyPackageUploadProviderId()},generate:{id,pid,count in try client.prepareKeyPackageUpload(id:id,scope:store.scope,nativeProviderId:pid,count:count)},completion:{_ in done.fulfill()})
            work.start(reason:"manual");wait(for:[done],timeout:5)
            let job=try XCTUnwrap(store.read().upload);XCTAssertEqual(job.status,"retained_server_rejected");XCTAssertEqual(job.bytes.count,1);XCTAssertEqual(try client.probeKeyPackageOwnership(job.refs),[true])
            withExtendedLifetime(work) {}
        }
    }

    func testNativeOwnershipBacklogContinuesAfterThreePageBound() throws {
        try fixture { client, store in
            let api = try fixtureAPI(); defer { api.session.invalidateAndCancel(); FixtureProtocol.handler = nil }
            var nextId = 1, inventories = 0, retirements = 0, clock = Date()
            FixtureProtocol.handler = { request in
                let path = request.url?.path ?? ""
                if path.hasSuffix("ownership/inventory") {
                    inventories += 1
                    let end = min(401, nextId + 99)
                    let entries = (nextId...end).map { n -> [String:Any] in
                        ["id":String(format:"00000000-0000-4000-8000-%012d",n),"created_at":"2026-10-18T00:00:00.000Z",
                         "key_package_ref":Data((0..<32).map { UInt8(truncatingIfNeeded:n >> (($0 % 4) * 8)) }).base64EncodedString()]
                    }
                    nextId = end + 1
                    let cursor: Any = end < 401 ? ["id":entries.last?["id"] ?? "", "created_at":"2026-10-18T00:00:00.000Z"] : NSNull()
                    return (200,try JSONSerialization.data(withJSONObject:["version":1,"entries":entries,"next_cursor":cursor]))
                }
                if path.hasSuffix("ownership/reconcile") {
                    retirements += 1
                    var bytes=request.httpBody ?? Data()
                    if bytes.isEmpty, let stream=request.httpBodyStream {
                        stream.open();defer{stream.close()};var buffer=[UInt8](repeating:0,count:4096)
                        while true {let n=stream.read(&buffer,maxLength:buffer.count);if n<=0{break};bytes.append(contentsOf:buffer.prefix(n));guard bytes.count<=1_048_576 else{throw ClientError.Unexpected("fixture_body_too_large")}}
                    }
                    let body = try XCTUnwrap(try JSONSerialization.jsonObject(with:bytes) as? [String:Any])
                    let missing = try XCTUnwrap(body["missing"] as? [[String:Any]])
                    return (200,try JSONSerialization.data(withJSONObject:["retired":missing.count]))
                }
                return (200,Data(#"{"remaining":100,"target":100,"low_watermark":50,"requested_delta":0,"refill_generation":null}"#.utf8))
            }
            func run() throws {
                let done=expectation(description:"bounded native inventory")
                let pipeline=try MlsKeyPackagePipeline(api:api,store:store,assertOwner:{},probe:{try client.probeKeyPackageOwnership($0)},
                    providerId:{try client.keyPackageUploadProviderId()},generate:{_,_,_ in XCTFail("healthy count must not generate");return []},now:{clock},completion:{_ in done.fulfill()})
                pipeline.start(reason:"manual");wait(for:[done],timeout:5);withExtendedLifetime(pipeline) {}
            }
            try run();XCTAssertEqual(inventories,3);XCTAssertEqual(retirements,3)
            XCTAssertEqual(try store.read().cursor?.id,"00000000-0000-4000-8000-000000000300")
            clock=clock.addingTimeInterval(31);try run();XCTAssertEqual(inventories,5);XCTAssertEqual(retirements,5);XCTAssertNil(try store.read().cursor)
        }
    }
    func testUncertainPrivateProbeNeverRetiresOrRefills() throws {
        try fixture { client, store in
            let api=try fixtureAPI();defer{api.session.invalidateAndCancel();FixtureProtocol.handler=nil}
            var retirements=0,counts=0
            FixtureProtocol.handler={request in
                if request.url?.path.hasSuffix("ownership/inventory")==true {
                    return(200,try JSONSerialization.data(withJSONObject:["version":1,"entries":[["id":"00000000-0000-4000-8000-000000000001","created_at":"2026-10-18T00:00:00Z","key_package_ref":Data(repeating:1,count:32).base64EncodedString()]],"next_cursor":NSNull()]))
                }
                if request.httpMethod=="POST"{retirements += 1}else{counts += 1};return(500,Data())
            }
            let done=expectation(description:"uncertain private retained")
            let pipeline=try MlsKeyPackagePipeline(api:api,store:store,assertOwner:{},probe:{_ in throw ClientError.MlsNoProviderError()},providerId:{try client.keyPackageUploadProviderId()},generate:{_,_,_ in XCTFail("uncertainty cannot authorize generation");return []},completion:{_ in done.fulfill()})
            pipeline.start(reason:"manual");wait(for:[done],timeout:5)
            XCTAssertEqual(retirements,0);XCTAssertEqual(counts,0);XCTAssertEqual(try store.read().attempts,1);XCTAssertGreaterThan(try store.read().retryAt,Date().timeIntervalSince1970)
            withExtendedLifetime(pipeline){}
        }
    }

    func testChangedValidPublicBytesCannotUseDifferentOwnedReference() throws {
        try fixture { client, store in
            let api=try fixtureAPI();defer{api.session.invalidateAndCancel();FixtureProtocol.handler=nil}
            let batch=try client.generateKeyPackageBatch(count:2),original=try store.read()
            var work=original;var job=MlsKeyPackageUploadJob(id:UUID().uuidString,status:"ready",createdAt:Date().timeIntervalSince1970)
            job.bytes=[batch[1].0];job.refs=[batch[0].1];work.upload=job;_ = try store.write(expected:original,next:work)
            var posts=0,counts=0
            FixtureProtocol.handler={request in
                if request.url?.path.hasSuffix("ownership/inventory")==true{return(200,Data(#"{"version":1,"entries":[],"next_cursor":null}"#.utf8))}
                if request.httpMethod=="POST"{posts += 1}else{counts += 1};return(500,Data())
            }
            let done=expectation(description:"valid but changed bytes retained")
            let pipeline=try MlsKeyPackagePipeline(api:api,store:store,assertOwner:{},probe:{try client.probeKeyPackageOwnership($0)},providerId:{try client.keyPackageUploadProviderId()},generate:{_,_,_ in XCTFail("no replacement generation");return []},completion:{_ in done.fulfill()})
            pipeline.start(reason:"manual");wait(for:[done],timeout:5)
            let retained=try XCTUnwrap(store.read().upload);XCTAssertEqual(retained.status,"retained_invalid_or_expired");XCTAssertEqual(retained.bytes,job.bytes);XCTAssertEqual(retained.refs,job.refs)
            XCTAssertEqual(posts,0);XCTAssertEqual(counts,0);XCTAssertEqual(try client.probeKeyPackageOwnership(batch.map{$0.1}),[true,true]);withExtendedLifetime(pipeline){}
        }
    }

    func testPreparingReconstructsExactNativeBatchBeforeAndAfterGeneration() throws {
        for generated in [false, true] {
            try fixture { client, store in
                let api = try fixtureAPI(); defer { api.session.invalidateAndCancel(); FixtureProtocol.handler = nil }
                var job = MlsKeyPackageUploadJob(id: UUID().uuidString, status: "preparing", createdAt: Date().timeIntervalSince1970)
                job.generationVersion = 1; job.batchSize = 2; job.nativeProviderId = try client.keyPackageUploadProviderId()
                var state = try store.read(); state.upload = job
                _ = try store.write(expected: store.read(), next: state)
                let providerId = try XCTUnwrap(job.nativeProviderId)
                let before = generated ? try client.prepareKeyPackageUpload(id: job.id, scope: store.scope, nativeProviderId: providerId, count: 2) : nil
                let root = store.url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                let reopened = MlsClient(storageFolderURL: root, deviceIdStore: client.deviceIdStore, userDefaults: client.userDefaults)
                try reopened.setup(with: "local-key-package-work")
                var posts = 0
                FixtureProtocol.handler = { request in
                    let route = request.url?.path ?? ""
                    if route.hasSuffix("ownership/inventory") { return (200, Data(#"{"version":1,"entries":[],"next_cursor":null}"#.utf8)) }
                    if route.hasSuffix("/count") { return (200, Data(#"{"remaining":100,"target":100,"low_watermark":50,"requested_delta":0,"refill_generation":null}"#.utf8)) }
                    posts += 1
                    XCTAssertEqual(request.value(forHTTPHeaderField: "X-Ermis-MLS-Upload-Operation"), job.id)
                    return (200, try JSONSerialization.data(withJSONObject: ["stored":2,"total_remaining":100,"target":100,"low_watermark":50,"requested_delta":0,"refill_generation":NSNull(),"batch_id":job.id,"validation_version":1]))
                }
                let done = expectation(description: "native preparing reconciled")
                let pipeline = try MlsKeyPackagePipeline(api: api, store: store, assertOwner: {}, probe: { try reopened.probeKeyPackageOwnership($0) },
                    providerId: { try reopened.keyPackageUploadProviderId() },
                    generate: { id, pid, count in try reopened.prepareKeyPackageUpload(id: id, scope: store.scope, nativeProviderId: pid, count: count) }, completion: { _ in done.fulfill() })
                pipeline.start(reason: "manual"); wait(for: [done], timeout: 5)
                XCTAssertEqual(posts, 1); XCTAssertNil(try store.read().upload)
                let exact = try reopened.prepareKeyPackageUpload(id: job.id, scope: store.scope, nativeProviderId: providerId, count: 2)
                if let before { XCTAssertEqual(exact.map { $0.0 }, before.map { $0.0 }) }
                XCTAssertEqual(try reopened.probeKeyPackageOwnership(exact.map { $0.1 }), [true,true])
                withExtendedLifetime(pipeline) {}
            }
        }
    }
    func testLegacyPreparingRecoversOnlyExactNativeJournalWithoutGeneration() throws {
        for status in ["preparing", "retained_legacy_preparing_unbound"] {
            try fixture { client, store in
                let id = UUID().uuidString
                let exact = try client.prepareKeyPackageUpload(id: id, scope: store.scope, nativeProviderId: client.keyPackageUploadProviderId(), count: 2)
                var pending = try store.read()
                pending.upload = .init(id: id, status: status, createdAt: Date().timeIntervalSince1970)
                _ = try store.write(expected: store.read(), next: pending)
                let api = try fixtureAPI(); defer { api.session.invalidateAndCancel(); FixtureProtocol.handler = nil }
                var posts = 0
                FixtureProtocol.handler = { request in
                    if request.url?.path.hasSuffix("ownership/inventory") == true { return (200, Data(#"{"version":1,"entries":[],"next_cursor":null}"#.utf8)) }
                    if request.url?.path.hasSuffix("/count") == true { return (200, Data(#"{"remaining":100,"target":100,"low_watermark":99,"requested_delta":0,"refill_generation":null}"#.utf8)) }
                    posts += 1
                    XCTAssertEqual(try store.read().upload?.status, "ready")
                    XCTAssertEqual(try store.read().upload?.bytes, exact.map { $0.0 })
                    XCTAssertEqual(request.value(forHTTPHeaderField: "X-Ermis-MLS-Upload-Operation")?.lowercased(), id.lowercased())
                    return (200, try JSONSerialization.data(withJSONObject: ["stored": 0, "total_remaining":100,"target":100,"low_watermark":99,"requested_delta":0,"refill_generation":NSNull(),"batch_id":id,"validation_version":1]))
                }
                let done = expectation(description: "exact legacy recovery")
                let pipeline = try MlsKeyPackagePipeline(api: api, store: store, assertOwner: {}, probe: { try client.probeKeyPackageOwnership($0) }, providerId: { try client.keyPackageUploadProviderId() }, generate: { _,_,_ in XCTFail("legacy lookup must never generate"); return [] }, recover: { try client.recoverKeyPackageUpload(id: $0, scope: store.scope) }, completion: { _ in done.fulfill() })
                pipeline.start(reason: "manual"); wait(for: [done], timeout: 5)
                XCTAssertEqual(posts, 1); XCTAssertNil(try store.read().upload)
                XCTAssertEqual(try client.probeKeyPackageOwnership(exact.map { $0.1 }), [true, true])
                withExtendedLifetime(pipeline) {}
            }
        }
    }

    func testLegacyPreparingAndReplacementProviderAreRetainedWithoutUploadOrRefill() throws {
        for legacy in [false, true] {
            try fixture { client, store in
                let api = try fixtureAPI(); defer { api.session.invalidateAndCancel(); FixtureProtocol.handler = nil }
                var job = MlsKeyPackageUploadJob(id: UUID().uuidString, status: "preparing", createdAt: Date().timeIntervalSince1970)
                if !legacy { job.generationVersion = 1; job.batchSize = 2; job.nativeProviderId = String(repeating: "0", count: 64) }
                let original = try store.read(); var next = original; next.upload = job
                _ = try store.write(expected: original, next: next)
                FixtureProtocol.handler = { request in
                    guard request.url?.path.hasSuffix("ownership/inventory") == true else { XCTFail("unbound preparing must not POST/count"); return (500, Data()) }
                    return (200, Data(#"{"version":1,"entries":[],"next_cursor":null}"#.utf8))
                }
                let done = expectation(description: "typed retained preparing")
                let pipeline = try MlsKeyPackagePipeline(api: api, store: store, assertOwner: {}, probe: { try client.probeKeyPackageOwnership($0) }, providerId: { try client.keyPackageUploadProviderId() }, generate: { _,_,_ in XCTFail("no generation"); return [] }, recover: { try client.recoverKeyPackageUpload(id: $0, scope: store.scope) }, completion: { _ in done.fulfill() })
                pipeline.start(reason: "manual"); wait(for: [done], timeout: 5)
                let retained = try XCTUnwrap(store.read().upload)
                XCTAssertEqual(retained.id, job.id); XCTAssertEqual(retained.status, legacy ? "retained_legacy_preparing_unbound" : "retained_provider_replaced")
                withExtendedLifetime(pipeline) {}
            }
        }
    }

}
