//
// Copyright 2026 Ermis Inc.
//

import XCTest

@testable import ErmisChat

final class ForwardAttachmentSourceMaterializerTests: XCTestCase {
    override func tearDown() {
        ForwardAttachmentURLProtocol.handler = nil
        super.tearDown()
    }

    func testRemoteVideoIsStreamedIntoLeaseOwnedLocalFile() async throws {
        let bytes = Data("video-original".utf8)
        ForwardAttachmentURLProtocol.handler = { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url ?? URL(fileURLWithPath: "/"),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Length": "\(bytes.count)"]
            ))
            return (response, bytes)
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forward-materializer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let materializer = makeMaterializer(rootURL: root, maximumBytes: 1_024)

        let lease = try await materializer.materialize(
            remoteURL: try XCTUnwrap(URL(string: "https://cdn.example.test/movie.mp4")),
            preferredFileExtension: "mp4"
        )

        XCTAssertTrue(lease.localURL.isFileURL)
        XCTAssertEqual(lease.localURL.pathExtension, "mp4")
        XCTAssertEqual(try Data(contentsOf: lease.localURL), bytes)
        var metadata = AnyAttachmentLocalMetadata()
        metadata.mimeType = "video/mp4"
        let uploadPayload = try AnyAttachmentPayload(
            localFileURL: lease.localURL,
            attachmentType: .video,
            localMetadata: metadata
        )
        XCTAssertEqual(uploadPayload.localFileURL, lease.localURL)
        let videoPayload = try XCTUnwrap(uploadPayload.payload as? VideoAttachmentPayload)
        XCTAssertEqual(videoPayload.file.size, Int64(bytes.count))
        let localURL = lease.localURL
        lease.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: localURL.path))
    }

    func testRemoteDownloadRejectsNonSuccessStatus() async throws {
        ForwardAttachmentURLProtocol.handler = { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url ?? URL(fileURLWithPath: "/"),
                statusCode: 404,
                httpVersion: nil,
                headerFields: nil
            ))
            return (response, Data())
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forward-materializer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            _ = try await makeMaterializer(rootURL: root, maximumBytes: 1_024).materialize(
                remoteURL: try XCTUnwrap(URL(string: "https://cdn.example.test/missing.mov")),
                preferredFileExtension: "mov"
            )
            XCTFail("Expected the remote source to reject HTTP 404")
        } catch {
            XCTAssertEqual(
                error as? ForwardAttachmentSourceMaterializationError,
                .invalidHTTPStatus(404)
            )
        }
    }

    func testRemoteDownloadRejectsActualBytesAboveLimitAndCleansOutput() async throws {
        let bytes = Data(repeating: 0xAB, count: 17)
        ForwardAttachmentURLProtocol.handler = { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url ?? URL(fileURLWithPath: "/"),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            ))
            return (response, bytes)
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forward-materializer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            _ = try await makeMaterializer(rootURL: root, maximumBytes: 16).materialize(
                remoteURL: try XCTUnwrap(URL(string: "https://cdn.example.test/large.mov")),
                preferredFileExtension: "mov"
            )
            XCTFail("Expected the oversized remote source to be rejected")
        } catch {
            XCTAssertEqual(
                error as? ForwardAttachmentSourceMaterializationError,
                .attachmentTooLarge
            )
        }
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        XCTAssertTrue(remaining.isEmpty)
    }

    private func makeMaterializer(
        rootURL: URL,
        maximumBytes: Int64
    ) -> ForwardAttachmentRemoteSourceMaterializer {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ForwardAttachmentURLProtocol.self]
        return ForwardAttachmentRemoteSourceMaterializer(
            sessionConfiguration: configuration,
            rootURL: rootURL,
            maximumBytes: maximumBytes
        )
    }
}

private final class ForwardAttachmentURLProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else {
                throw URLError(.badServerResponse)
            }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
