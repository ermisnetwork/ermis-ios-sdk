//
// Copyright 2026 Ermis Inc.
//

import XCTest

@testable import ErmisChat

final class StandardPresignedAttachmentUploadClientTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDown() {
        StandardPresignedUploadURLProtocol.removeHandler()
        temporaryURLs.forEach { try? FileManager.default.removeItem(at: $0) }
        temporaryURLs.removeAll()
        super.tearDown()
    }

    func testHappyPathPresignsUploadsWithoutControlCredentialsAndConfirms() async throws {
        let recorder = PresignedRequestRecorder()
        StandardPresignedUploadURLProtocol.installHandler { request in
            if request.url?.host == "storage.example.test" { recorder.record(request) }
            switch request.url?.host {
            case "api.example.test":
                if request.url?.path.hasSuffix("/file/presign") == true {
                    return .json(
                        statusCode: 201,
                        object: [
                            "attachment_id": "11111111-1111-1111-1111-111111111111",
                            "upload_url": "https://storage.example.test/object-1",
                            "expires_in_secs": 300
                        ]
                    )
                }
                return .json(
                    statusCode: 202,
                    object: ["file": "https://cdn.example.test/video.mp4"]
                )
            case "storage.example.test":
                return .empty(statusCode: 204)
            default:
                return .failure(URLError(.badURL))
            }
        }
        let sourceURL = try makeSourceFile(named: "clip.mp4")
        let client = makeClient(recorder: recorder)
        var progressValues: [Double] = []

        let result = await upload(
            makeAttachment(sourceURL: sourceURL),
            using: client,
            progress: { progressValues.append($0) }
        )
        let uploaded = try result.get()

        XCTAssertEqual(uploaded.fileURL.absoluteString, "https://cdn.example.test/video.mp4")
        XCTAssertEqual(progressValues.last, 1)
        let requests = recorder.snapshot()
        XCTAssertEqual(requests.count, 3)
        let presign = try XCTUnwrap(requests.first { $0.url?.path.hasSuffix("/file/presign") == true })
        let storage = try XCTUnwrap(requests.first { $0.url?.host == "storage.example.test" })
        let confirm = try XCTUnwrap(requests.first { $0.url?.path.hasSuffix("/file/confirm") == true })

        XCTAssertEqual(presign.httpMethod, "POST")
        XCTAssertEqual(presign.value(forHTTPHeaderField: "Authorization"), "Bearer control-token")
        XCTAssertEqual(
            jsonBody(presign)["file_name"] as? String,
            sourceURL.lastPathComponent
        )
        XCTAssertEqual(jsonBody(presign)["content_type"] as? String, "video/mp4")
        XCTAssertEqual(storage.httpMethod, "PUT")
        XCTAssertEqual(storage.value(forHTTPHeaderField: "Content-Type"), "video/mp4")
        XCTAssertNil(storage.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(storage.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(storage.value(forHTTPHeaderField: "Content-Encoding"))
        XCTAssertNil(storage.value(forHTTPHeaderField: "X-Ermis-E2EE-Byte-Wire-Format"))
        XCTAssertNil(URLComponents(url: try XCTUnwrap(storage.url), resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "api_key" })
        XCTAssertEqual(
            jsonBody(confirm)["attachment_id"] as? String,
            "11111111-1111-1111-1111-111111111111"
        )
    }

    func testStorage403RenewsPresignExactlyOnceThenConfirmsFreshAttachment() async throws {
        let recorder = PresignedRequestRecorder()
        let state = PresignedScenarioState()
        StandardPresignedUploadURLProtocol.installHandler { request in
            if request.url?.host == "storage.example.test" { recorder.record(request) }
            if request.url?.path.hasSuffix("/file/presign") == true {
                let attempt = state.nextPresignAttempt()
                return .json(
                    statusCode: 200,
                    object: [
                        "attachment_id": attempt == 1
                            ? "11111111-1111-1111-1111-111111111111"
                            : "22222222-2222-2222-2222-222222222222",
                        "upload_url": "https://storage.example.test/object-\(attempt)",
                        "expires_in_secs": 300
                    ]
                )
            }
            if request.url?.host == "storage.example.test" {
                return .empty(statusCode: request.url?.path == "/object-1" ? 403 : 200)
            }
            return .json(
                statusCode: 200,
                object: ["file": "https://cdn.example.test/renewed.mp4"]
            )
        }

        let result = await upload(
            makeAttachment(sourceURL: try makeSourceFile(named: "renew.mov")),
            using: makeClient(recorder: recorder)
        )

        XCTAssertEqual(try result.get().fileURL.absoluteString, "https://cdn.example.test/renewed.mp4")
        let requests = recorder.snapshot()
        XCTAssertEqual(requests.filter { $0.url?.path.hasSuffix("/file/presign") == true }.count, 2)
        XCTAssertEqual(requests.filter { $0.url?.host == "storage.example.test" }.count, 2)
        let confirm = try XCTUnwrap(requests.first { $0.url?.path.hasSuffix("/file/confirm") == true })
        XCTAssertEqual(
            jsonBody(confirm)["attachment_id"] as? String,
            "22222222-2222-2222-2222-222222222222"
        )
    }

    func testSecondStorage403FailsWithoutThirdPresignOrLegacyPermission() async throws {
        let recorder = PresignedRequestRecorder()
        let state = PresignedScenarioState()
        StandardPresignedUploadURLProtocol.installHandler { request in
            if request.url?.host == "storage.example.test" { recorder.record(request) }
            if request.url?.path.hasSuffix("/file/presign") == true {
                let attempt = state.nextPresignAttempt()
                return .json(
                    statusCode: 200,
                    object: [
                        "attachment_id": attempt == 1
                            ? "11111111-1111-1111-1111-111111111111"
                            : "22222222-2222-2222-2222-222222222222",
                        "upload_url": "https://storage.example.test/object-\(attempt)",
                        "expires_in_secs": 300
                    ]
                )
            }
            return .empty(statusCode: 403)
        }

        let result = await upload(
            makeAttachment(sourceURL: try makeSourceFile(named: "denied.mp4")),
            using: makeClient(recorder: recorder)
        )

        guard case .failure(let failure) = result else {
            return XCTFail("Expected the second storage rejection to fail")
        }
        XCTAssertEqual(failure.stage, .storage)
        XCTAssertFalse(failure.permitsLegacyFallback)
        XCTAssertEqual(
            failure.underlyingError as? StandardPresignedUploadContractError,
            .storageRejected(403)
        )
        let requests = recorder.snapshot()
        XCTAssertEqual(requests.filter { $0.url?.path.hasSuffix("/file/presign") == true }.count, 2)
        XCTAssertEqual(requests.filter { $0.url?.host == "storage.example.test" }.count, 2)
        XCTAssertFalse(requests.contains { $0.url?.path.hasSuffix("/file/confirm") == true })
    }

    func testAmbiguousStorageFailureConfirmsSameAttachmentWithoutReupload() async throws {
        let recorder = PresignedRequestRecorder()
        StandardPresignedUploadURLProtocol.installHandler { request in
            if request.url?.host == "storage.example.test" { recorder.record(request) }
            if request.url?.path.hasSuffix("/file/presign") == true {
                return .json(
                    statusCode: 200,
                    object: [
                        "attachment_id": "11111111-1111-1111-1111-111111111111",
                        "upload_url": "https://storage.example.test/ambiguous",
                        "expires_in_secs": 300
                    ]
                )
            }
            if request.url?.host == "storage.example.test" {
                return .failure(URLError(.networkConnectionLost))
            }
            return .json(
                statusCode: 200,
                object: ["file": "https://cdn.example.test/reconciled.mp4"]
            )
        }

        let result = await upload(
            makeAttachment(sourceURL: try makeSourceFile(named: "ambiguous.mp4")),
            using: makeClient(recorder: recorder)
        )

        XCTAssertEqual(try result.get().fileURL.absoluteString, "https://cdn.example.test/reconciled.mp4")
        let requests = recorder.snapshot()
        XCTAssertEqual(requests.filter { $0.url?.path.hasSuffix("/file/presign") == true }.count, 1)
        XCTAssertEqual(requests.filter { $0.url?.host == "storage.example.test" }.count, 1)
        XCTAssertEqual(requests.filter { $0.url?.path.hasSuffix("/file/confirm") == true }.count, 1)
    }

    func testInvalidPresignContractCanFallBackBeforeStorageStarts() async throws {
        let recorder = PresignedRequestRecorder()
        StandardPresignedUploadURLProtocol.installHandler { request in
            if request.url?.host == "storage.example.test" { recorder.record(request) }
            return .json(
                statusCode: 200,
                object: [
                    "attachment_id": "11111111-1111-1111-1111-111111111111",
                    "upload_url": "http://storage.example.test/insecure",
                    "expires_in_secs": 300
                ]
            )
        }

        let result = await upload(
            makeAttachment(sourceURL: try makeSourceFile(named: "insecure.mp4")),
            using: makeClient(recorder: recorder)
        )

        guard case .failure(let failure) = result else {
            return XCTFail("Expected insecure storage URL to be rejected")
        }
        XCTAssertEqual(failure.stage, .presign)
        XCTAssertTrue(failure.permitsLegacyFallback)
        XCTAssertEqual(
            failure.underlyingError as? StandardPresignedUploadContractError,
            .invalidUploadURL
        )
        XCTAssertEqual(recorder.snapshot().count, 1)
    }

    func testDefaultUploaderFallsBackToLegacyOnlyForPresignFailure() async throws {
        let recorder = PresignedRequestRecorder()
        StandardPresignedUploadURLProtocol.installHandler { request in
            if request.url?.path.hasSuffix("/file/presign") == true {
                return .json(
                    statusCode: 200,
                    object: [
                        "attachment_id": "11111111-1111-1111-1111-111111111111",
                        "upload_url": "http://storage.example.test/insecure",
                        "expires_in_secs": 300
                    ]
                )
            }
            return .json(
                statusCode: 200,
                object: ["file": "https://cdn.example.test/legacy.mp4"]
            )
        }
        let client = makeDefaultUploadClient(
            recorder: recorder,
            allowsLegacyFallback: true
        )

        let result = await upload(
            makeAttachment(sourceURL: try makeSourceFile(named: "legacy.mp4")),
            using: client
        )

        XCTAssertEqual(try result.get().fileURL.absoluteString, "https://cdn.example.test/legacy.mp4")
        let paths = recorder.snapshot().compactMap(\.url?.path)
        XCTAssertEqual(paths.filter { $0.hasSuffix("/file/presign") }.count, 1)
        XCTAssertEqual(paths.filter { $0.hasSuffix("/file") }.count, 1)
    }

    func testDefaultUploaderDoesNotUseLegacyWhenFallbackIsDisabled() async throws {
        let recorder = PresignedRequestRecorder()
        StandardPresignedUploadURLProtocol.installHandler { request in
            if request.url?.path.hasSuffix("/file/presign") == true {
                return .json(
                    statusCode: 200,
                    object: [
                        "attachment_id": "11111111-1111-1111-1111-111111111111",
                        "upload_url": "http://storage.example.test/insecure",
                        "expires_in_secs": 300
                    ]
                )
            }
            return .json(
                statusCode: 200,
                object: ["file": "https://cdn.example.test/legacy.mp4"]
            )
        }
        let client = makeDefaultUploadClient(
            recorder: recorder,
            allowsLegacyFallback: false
        )

        let result = await upload(
            makeAttachment(sourceURL: try makeSourceFile(named: "no-fallback.mp4")),
            using: client
        )

        guard case .failure(let error) = result,
              let failure = error as? StandardPresignedUploadFailure else {
            return XCTFail("Expected the presign contract failure")
        }
        XCTAssertEqual(failure.stage, .presign)
        XCTAssertEqual(
            recorder.snapshot().filter { $0.url?.path.hasSuffix("/file") == true }.count,
            0
        )
    }

    func testPresignedRolloutDefaultsOffAndPreservesCustomUploaderPrecedence() throws {
        let baseURL = URL(string: "https://api.example.test") ?? URL(fileURLWithPath: "/")
        let endpointEnvironment = EndpointEnviroment(baseURL: baseURL)
        var customUploaderConfig = ErmisClientConfig(
            apiKeyString: "test-api-key",
            endpointEnviroment: endpointEnvironment
        )
        XCTAssertFalse(customUploaderConfig.isStandardPresignedUploadEnabled)
        XCTAssertTrue(customUploaderConfig.allowsLegacyStandardUploadFallback)
        customUploaderConfig.isStandardPresignedUploadEnabled = true
        let customUploader = StandardCustomUploaderSpy()
        customUploaderConfig.customUploader = customUploader
        let customUploaderFactory = ErmisClientFactory(
            config: customUploaderConfig,
            environment: ErmisClient.Environment()
        )
        let customUploaderAPIClient = customUploaderFactory.makeApiClient(
            encoder: customUploaderFactory.makeApiClientRequestEncoder(),
            urlSessionConfiguration: URLSessionConfiguration.ephemeral
        )
        XCTAssertTrue(customUploaderAPIClient.uploader as AnyObject === customUploader)

        var customClientConfig = ErmisClientConfig(
            apiKeyString: "test-api-key",
            endpointEnviroment: endpointEnvironment
        )
        customClientConfig.isStandardPresignedUploadEnabled = true
        let customUploadClient = StandardCustomUploadClientSpy()
        customClientConfig.customUploadClient = customUploadClient
        let customClientFactory = ErmisClientFactory(
            config: customClientConfig,
            environment: ErmisClient.Environment()
        )
        let customClientAPIClient = customClientFactory.makeApiClient(
            encoder: customClientFactory.makeApiClientRequestEncoder(),
            urlSessionConfiguration: URLSessionConfiguration.ephemeral
        )
        let wrappedUploader = try XCTUnwrap(customClientAPIClient.uploader as? ErmisUploader)
        XCTAssertTrue(wrappedUploader.uploadClient as AnyObject === customUploadClient)
    }

    func testVideoProgressReservesCompletionForConfirmedThumbnail() {
        XCTAssertEqual(StandardVideoUploadProgress.original(-1), 0)
        XCTAssertEqual(StandardVideoUploadProgress.original(0.5), 0.45, accuracy: 0.000_001)
        XCTAssertEqual(StandardVideoUploadProgress.original(1), 0.9, accuracy: 0.000_001)
        XCTAssertEqual(StandardVideoUploadProgress.thumbnail(0), 0.9, accuracy: 0.000_001)
        XCTAssertEqual(StandardVideoUploadProgress.thumbnail(0.5), 0.95, accuracy: 0.000_001)
        XCTAssertEqual(StandardVideoUploadProgress.thumbnail(1), 1, accuracy: 0.000_001)
        XCTAssertEqual(StandardVideoUploadProgress.thumbnail(2), 1, accuracy: 0.000_001)
    }

    private func makeClient(
        recorder: PresignedRequestRecorder
    ) -> StandardPresignedAttachmentUploadClient {
        let configuration = makeSessionConfiguration()
        let baseURL = URL(string: "https://api.example.test") ?? URL(fileURLWithPath: "/")
        return StandardPresignedAttachmentUploadClient(
            encoder: makeEncoder(baseURL: baseURL, recorder: recorder),
            decoder: DefaultRequestDecoder(),
            sessionConfiguration: configuration
        )
    }

    private func makeDefaultUploadClient(
        recorder: PresignedRequestRecorder,
        allowsLegacyFallback: Bool
    ) -> ErmisUploadClient {
        let baseURL = URL(string: "https://api.example.test") ?? URL(fileURLWithPath: "/")
        return ErmisUploadClient(
            encoder: makeEncoder(baseURL: baseURL, recorder: recorder),
            decoder: DefaultRequestDecoder(),
            sessionConfiguration: makeSessionConfiguration(),
            isStandardPresignedUploadEnabled: true,
            allowsLegacyStandardUploadFallback: allowsLegacyFallback
        )
    }

    private func makeEncoder(
        baseURL: URL,
        recorder: PresignedRequestRecorder
    ) -> StandardPresignedTestRequestEncoder {
        StandardPresignedTestRequestEncoder(
            baseURL: baseURL,
            authURL: baseURL,
            stickerURL: baseURL,
            apiKey: APIKey("test-api-key"),
            recorder: recorder
        )
    }

    private func makeSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StandardPresignedUploadURLProtocol.self]
        configuration.httpAdditionalHeaders = [
            "Authorization": "Bearer leaked-session-token",
            "Cookie": "control-session=cookie",
            "X-Ermis-E2EE-Byte-Wire-Format": "base64"
        ]
        return configuration
    }

    private func makeSourceFile(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("standard-presigned-\(UUID().uuidString)-\(name)")
        try Data("video-bytes".utf8).write(to: url, options: .atomic)
        temporaryURLs.append(url)
        return url
    }

    private func makeAttachment(sourceURL: URL) -> AnyMessageAttachment {
        let cid = ChannelId(type: .messaging, projectId: "project", id: "channel")
        let file = (try? AttachmentFile(url: sourceURL, fileSize: nil))
            ?? AttachmentFile(
                type: AttachmentFileType(mimeType: "video/mp4"),
                size: 0,
                mimeType: "video/mp4"
            )
        return AnyMessageAttachment(
            id: AttachmentId(cid: cid, messageId: "message", index: 0),
            type: .video,
            payload: Data(),
            thumbnailData: nil,
            uploadingState: AttachmentUploadingState(
                localFileURL: sourceURL,
                state: .pendingUpload,
                file: file
            )
        )
    }

    private func upload(
        _ attachment: AnyMessageAttachment,
        using client: StandardPresignedAttachmentUploadClient,
        progress: ((Double) -> Void)? = nil
    ) async -> Result<UploadedFile, StandardPresignedUploadFailure> {
        await withCheckedContinuation { continuation in
            client.upload(attachment, progress: progress) { result in
                continuation.resume(returning: result)
            }
        }
    }

    private func upload(
        _ attachment: AnyMessageAttachment,
        using client: ErmisUploadClient
    ) async -> Result<UploadedFile, Error> {
        await withCheckedContinuation { continuation in
            client.uploadAttachment(attachment, progress: nil) {
                (result: Result<UploadedFile, Error>) in
                continuation.resume(returning: result)
            }
        }
    }

    private func jsonBody(_ request: URLRequest) -> [String: Any] {
        guard let body = request.httpBody,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return [:]
        }
        return object
    }
}

private final class StandardPresignedTestRequestEncoder: RequestEncoder {
    let baseURL: URL
    let authURL: URL
    let stickerURL: URL
    let apiKey: APIKey
    private let recorder: PresignedRequestRecorder?
    weak var connectionProviderDelegate: ConnectionProviderDelegate?
    var deviceIdStore: MlsDeviceIdStore?

    required init(baseURL: URL, authURL: URL, stickerURL: URL, apiKey: APIKey) {
        self.baseURL = baseURL
        self.authURL = authURL
        self.stickerURL = stickerURL
        self.apiKey = apiKey
        recorder = nil
    }

    init(
        baseURL: URL,
        authURL: URL,
        stickerURL: URL,
        apiKey: APIKey,
        recorder: PresignedRequestRecorder
    ) {
        self.baseURL = baseURL
        self.authURL = authURL
        self.stickerURL = stickerURL
        self.apiKey = apiKey
        self.recorder = recorder
    }

    func encodeRequest<ResponsePayload: Decodable>(
        for endpoint: Endpoint<ResponsePayload>,
        completion: @escaping (Result<URLRequest, Error>) -> Void
    ) {
        let path: String
        switch endpoint.path {
        case .presignStandardAttachment(let cid):
            path = "channels/\(cid.apiPath)/file/presign"
        case .confirmStandardAttachment(let cid):
            path = "channels/\(cid.apiPath)/file/confirm"
        case .uploadAttachment(let cid, _):
            path = "channels/\(cid.apiPath)/file"
        default:
            completion(.failure(URLError(.unsupportedURL)))
            return
        }
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
            completion(.failure(URLError(.badURL)))
            return
        }
        components.queryItems = [URLQueryItem(name: "api_key", value: apiKey.apiKeyString)]
        guard let url = components.url else {
            completion(.failure(URLError(.badURL)))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer control-token", forHTTPHeaderField: "Authorization")
        request.setValue("control-cookie", forHTTPHeaderField: "Cookie")
        request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        request.setValue("base64", forHTTPHeaderField: "X-Ermis-E2EE-Byte-Wire-Format")
        do {
            if let body = endpoint.body {
                request.httpBody = try JSONEncoder.ermis.encode(AnyEncodable(body))
            }
            recorder?.record(request)
            completion(.success(request))
        } catch {
            completion(.failure(error))
        }
    }
}

private enum StandardPresignedURLProtocolResult {
    case response(statusCode: Int, headers: [String: String], data: Data)
    case failure(Error)

    static func json(statusCode: Int, object: [String: Any]) -> Self {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return .response(
            statusCode: statusCode,
            headers: ["Content-Type": "application/json"],
            data: data
        )
    }

    static func empty(statusCode: Int) -> Self {
        .response(statusCode: statusCode, headers: [:], data: Data())
    }
}

private final class StandardPresignedUploadURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> StandardPresignedURLProtocolResult

    private static let lock = NSLock()
    private static var handler: Handler?

    static func installHandler(_ handler: @escaping Handler) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    static func removeHandler() {
        lock.lock()
        handler = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handler
        Self.lock.unlock()
        guard let handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        switch handler(request) {
        case .response(let statusCode, let headers, let data):
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class PresignedRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        var capturedRequest = request
        if capturedRequest.httpBody == nil,
           let stream = capturedRequest.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(buffer, count: count)
            }
            capturedRequest.httpBody = body
            capturedRequest.httpBodyStream = nil
        }
        lock.lock()
        requests.append(capturedRequest)
        lock.unlock()
    }

    func snapshot() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

private final class PresignedScenarioState: @unchecked Sendable {
    private let lock = NSLock()
    private var presignAttempts = 0

    func nextPresignAttempt() -> Int {
        lock.lock()
        defer { lock.unlock() }
        presignAttempts += 1
        return presignAttempts
    }
}

private final class StandardCustomUploaderSpy: Uploader {
    func upload(
        _ attachment: AnyMessageAttachment,
        progress: ((Double) -> Void)?,
        completion: @escaping (Result<UploadedAttachment, Error>) -> Void
    ) {
        completion(.failure(URLError(.unsupportedURL)))
    }

    func uploadUserAvatar(
        _ data: Data,
        progress: ((Double) -> Void)?,
        completion: @escaping (Result<AvatarUploadPayload, Error>) -> Void
    ) {
        completion(.failure(URLError(.unsupportedURL)))
    }
}

private final class StandardCustomUploadClientSpy: UploadClient {
    func uploadAttachment(
        _ attachment: AnyMessageAttachment,
        progress: ((Double) -> Void)?,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        completion(.failure(URLError(.unsupportedURL)))
    }

    func uploadUserAvatar(
        _ data: Data,
        progress: ((Double) -> Void)?,
        completion: @escaping (Result<AvatarUploadPayload, Error>) -> Void
    ) {
        completion(.failure(URLError(.unsupportedURL)))
    }
}
