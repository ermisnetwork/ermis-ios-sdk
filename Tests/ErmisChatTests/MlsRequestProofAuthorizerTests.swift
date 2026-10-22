import XCTest
import CryptoKit
import open_mls_ios
@testable import ErmisChat

final class MlsRequestProofAuthorizerTests: XCTestCase {
    private final class FixtureProtocol: URLProtocol {
        static var handler: ((URLRequest) throws -> Data)?
        static var statusCode = 200
        override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "mls-proof.invalid" }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            do {
                let data = try Self.handler?(request) ?? Data()
                let response = try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: Self.statusCode, httpVersion: nil, headerFields: nil))
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
        override func stopLoading() {}
    }

    private final class ExpiringProofEncoder: DefaultRequestEncoder {
        var calls = 0
        override func encodeRequest<ResponsePayload: Decodable>(for endpoint: Endpoint<ResponsePayload>,
            completion: @escaping (Result<URLRequest, Error>) -> Void) {
            calls += 1
            if calls == 1 { completion(.failure(ClientError.ExpiredToken())) }
            else { completion(.success(URLRequest(url: baseURL))) }
        }
    }

    func testEncodingExpiryJoinsRefreshAndRetriesInsteadOfFailingCandidate() throws {
        struct Response: Decodable { let ok: Bool }
        let base = try XCTUnwrap(URL(string: "https://mls-proof.invalid"))
        let encoder = ExpiringProofEncoder(baseURL: base, authURL: base, stickerURL: base, apiKey: APIKey("fixture"))
        let decoder = DefaultRequestDecoder()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureProtocol.self]
        FixtureProtocol.statusCode = 200; FixtureProtocol.handler = { _ in Data(#"{"ok":true}"#.utf8) }
        defer { FixtureProtocol.handler = nil }
        let api = APIClient(sessionConfiguration: config, requestEncoder: encoder, requestDecoder: decoder,
            uploader: ErmisUploader(uploadClient: ErmisUploadClient(encoder: encoder, decoder: decoder, sessionConfiguration: config)),
            downloader: ErmisDownloader(client: ErmisDownloadClient(sessionConfiguration: config)))
        var refreshes = 0
        api.tokenRefresher = { done in refreshes += 1; done(nil) }
        let done = expectation(description: "encoding401 refresh and retry")
        api.request(endpoint: Endpoint<Response>(path: .mlsControl("v1/e2ee/channels/team/fixture/external_join/operations/fixture"), method: .get)) { result in
            XCTAssertEqual(try? result.get().ok, true)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(refreshes, 1); XCTAssertEqual(encoder.calls, 2)
        withExtendedLifetime(api) {}
    }

    func testRegistrationBare401PropagatesRefreshSignalAndDoesNotCache() throws {
        let provider = Provider(), identity = try Identity(provider: provider, userId: "proof-user")
        let project = "00000000-0000-4000-8000-000000000084", device = "proof-device"
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); FixtureProtocol.handler = nil; FixtureProtocol.statusCode = 200 }
        var calls = 0
        FixtureProtocol.statusCode = 401
        FixtureProtocol.handler = { _ in calls += 1; return Data() }
        let authorizer = MlsRequestProofAuthorizer(session: session) {
            MlsRequestProofOwner(userId: "proof-user", deviceId: device, publicKey: identity.signaturePublicKey(), assertCurrent: {},
                registrationSignature: { try identity.deviceRegistrationSignature(deviceId: $0, projectId: $1, issuedAt: $2) },
                sign: { try identity.lorRequestSignature(contextJson: $0) })
        }
        var request = URLRequest(url: try XCTUnwrap(URL(string: "https://mls-proof.invalid/v1/e2ee/channels/team/\(project):scope/external_join")))
        request.httpMethod = "POST"; request.httpBody = Data("exact candidate body".utf8)
        request.setValue(device, forHTTPHeaderField: "X-Device-ID")
        for status in [401, 403, 503] {
            FixtureProtocol.statusCode = status
            let done = expectation(description: "registration status \(status)")
            authorizer.authorize(request) { result in
                if case .failure(let error) = result { XCTAssertEqual(error is ClientError.ExpiredToken, status == 401) }
                else { XCTFail("Failed registration must not authorize a join") }
                done.fulfill()
            }
            wait(for: [done], timeout: 5)
        }
        XCTAssertEqual(calls, 3)
    }

    func testFinalTargetBodyDigestNativeSignatureAndCachedReceiptPreflight() throws {
        let provider = Provider(), identity = try Identity(provider: provider, userId: "proof-user")
        let project = "00000000-0000-4000-8000-000000000084"
        let device = "proof-device", registration = UUID().uuidString.lowercased()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); FixtureProtocol.handler = nil }
        var registrations = 0
        FixtureProtocol.handler = { request in
            registrations += 1
            XCTAssertEqual(request.url?.path, "/v1/e2ee/devices/register")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "fixture-auth")
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }; body.append(contentsOf: buffer.prefix(count))
                }
            }
            let proof = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(proof["device_id"] as? String, device)
            XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(proof["signature"] as? String))?.count, 64)
            return try JSONSerialization.data(withJSONObject: ["registration": ["active": true, "registration_id": registration, "generation": 0, "device_id": device]])
        }
        let authorizer = MlsRequestProofAuthorizer(session: session) {
            MlsRequestProofOwner(userId: "proof-user", deviceId: device, publicKey: identity.signaturePublicKey(), assertCurrent: {},
                registrationSignature: { try identity.deviceRegistrationSignature(deviceId: $0, projectId: $1, issuedAt: $2) },
                sign: { try identity.lorRequestSignature(contextJson: $0) })
        }
        for operation in [4, 5] {
            let suffix = operation == 4 ? "external_join" : "external_join/operations/\(UUID().uuidString.lowercased())"
            var request = URLRequest(url: try XCTUnwrap(URL(string: "https://mls-proof.invalid/v1/e2ee/channels/team/\(project):scope/\(suffix)?user_id=proof-user&opaque=a%2Bb")))
            request.httpMethod = operation == 4 ? "POST" : "GET"
            request.httpBody = operation == 4 ? Data(#"{"commit":"AQ==","group_info":"Ag==","epoch":1}"#.utf8) : nil
            request.setValue(device, forHTTPHeaderField: "X-Device-ID")
            request.setValue("fixture-auth", forHTTPHeaderField: "Authorization")
            let done = expectation(description: "signed operation \(operation)")
            let original = request
            authorizer.authorize(request) { result in
                defer { done.fulfill() }
                do {
                    let signed = try result.get()
                    var header = try XCTUnwrap(signed.value(forHTTPHeaderField: "X-Ermis-MLS-Proof"))
                    header = header.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                    header += String(repeating: "=", count: (4 - header.count % 4) % 4)
                    let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(Data(base64Encoded: header))) as? [String: Any])
                    let context = try XCTUnwrap(envelope["context"] as? [String: Any])
                    XCTAssertEqual(context["operation"] as? Int, operation)
                    XCTAssertEqual(context["registration_id"] as? String, registration)
                    let url = try XCTUnwrap(URLComponents(url: XCTUnwrap(original.url), resolvingAgainstBaseURL: false))
                    XCTAssertEqual(context["target"] as? String, url.percentEncodedPath + "?" + (url.percentEncodedQuery ?? ""))
                    XCTAssertEqual(context["body_sha256"] as? String, SHA256.hash(data: original.httpBody ?? Data()).map { String(format: "%02x", $0) }.joined())
                    XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(envelope["signature"] as? String))?.count, 64)
                    XCTAssertEqual(signed.httpBody, original.httpBody)
                } catch { XCTFail("Proof authorization failed: \(error)") }
            }
            wait(for: [done], timeout: 5)
        }
        XCTAssertEqual(registrations, 1)
    }
    func testOwnershipAndUploadUseProductionProofWithStableBatchId() throws {
        let provider = Provider(), identity = try Identity(provider: provider, userId: "proof-user")
        let project = "00000000-0000-4000-8000-000000000084", device = "proof-device", registration = UUID().uuidString.lowercased()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); FixtureProtocol.handler = nil }
        FixtureProtocol.statusCode = 200
        FixtureProtocol.handler = { _ in try JSONSerialization.data(withJSONObject: ["registration":["active":true,"device_id":device,"registration_id":registration,"generation":0]]) }
        let authorizer = MlsRequestProofAuthorizer(session: session) {
            MlsRequestProofOwner(userId: "proof-user", deviceId: device, publicKey: identity.signaturePublicKey(), assertCurrent: {},
                registrationSignature: { try identity.deviceRegistrationSignature(deviceId: $0, projectId: $1, issuedAt: $2) }, sign: { try identity.lorRequestSignature(contextJson: $0) })
        }
        // Parser-only fixture JWT, never accepted by a backend or installed into an app.
        let payload = try JSONSerialization.data(withJSONObject: ["user_id":"proof-user","client_id":UUID().uuidString,"project_id":project,"chain_id":1,"ermis":false]).base64EncodedString()
        let token = "e30." + payload + ".fixture"
        let batch = UUID().uuidString.lowercased()
        for operation in [1,2,6,6] {
            let route = operation == 1 ? "ownership/inventory" : operation == 2 ? "ownership/reconcile" : ""
            var request = URLRequest(url: try XCTUnwrap(URL(string: "https://mls-proof.invalid/v1/e2ee/key_packages" + (route.isEmpty ? "" : "/" + route))))
            request.httpMethod = operation == 1 ? "GET" : "POST"
            request.httpBody = operation == 1 ? nil : Data("exact-public-body".utf8)
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization"); request.setValue(device, forHTTPHeaderField: "X-Device-ID")
            if operation == 6 { request.setValue(batch, forHTTPHeaderField: "X-Ermis-MLS-Upload-Operation") }
            let done = expectation(description: "operation \(operation)")
            authorizer.authorize(request) { result in
                defer { done.fulfill() }
                do {
                    let signed = try result.get(), encoded = try XCTUnwrap(signed.value(forHTTPHeaderField: "X-Ermis-MLS-Proof"))
                    var base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                    base64 += String(repeating: "=", count: (4-base64.count%4)%4)
                    let envelope = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(Data(base64Encoded: base64))) as? [String:Any])
                    let context = try XCTUnwrap(envelope["context"] as? [String:Any])
                    XCTAssertEqual(context["operation"] as? Int, operation)
                    if operation == 6 { XCTAssertEqual(context["request_id"] as? String, batch) }
                    XCTAssertNil(signed.value(forHTTPHeaderField: "X-Ermis-MLS-Upload-Operation"))
                } catch { XCTFail("Proof failed: \(error)") }
            }
            wait(for:[done],timeout:5)
        }
    }

}
