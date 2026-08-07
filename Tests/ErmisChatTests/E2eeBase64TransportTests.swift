import XCTest

@testable import ErmisChat

final class E2eeBase64TransportTests: XCTestCase {
    override func setUp() {
        super.setUp()
        E2eeLegacyByteTelemetry.resetForTesting()
    }

    func testCanonicalBase64GoldenVectors() throws {
        let vectors: [([UInt8], String)] = [
            ([], ""),
            ([0], "AA=="),
            ([0, 1], "AAE="),
            ([0, 1, 2, 253, 254, 255], "AAEC/f7/"),
        ]

        for (bytes, encoded) in vectors {
            XCTAssertEqual(E2eeBytesCodec.encode(bytes), encoded)
            XCTAssertEqual(try E2eeBytesCodec.decodeCanonicalBase64(encoded), bytes)
        }
    }

    func testBase64DecoderRejectsNonCanonicalRepresentations() {
        for invalid in ["AA", "AA=", "AA-_", " A A==", "AA===", "A===", "!!!!"] {
            XCTAssertThrowsError(try E2eeBytesCodec.decodeCanonicalBase64(invalid), invalid)
        }
    }

    func testLegacyDecoderRejectsInvalidByteValues() {
        for invalid in [-1.0, 256.0, 1.5, .infinity, .nan] {
            XCTAssertThrowsError(try E2eeBytesCodec.decodeLegacy([invalid]))
        }
    }

    func testUploadKeyPackagesAlwaysEncodesBase64Strings() throws {
        let body = UploadKeyPackagesRequestBody(keyPackages: [[0, 1], [255]])
        let object = try jsonObject(JSONEncoder.ermis.encode(body))

        XCTAssertEqual(object["key_packages"] as? [String], ["AAE=", "/w=="])
    }

    func testRepresentativeMlsRequestBodiesAlwaysEncodeBase64Strings() throws {
        let externalJoin = ExternalJoinRequestBody(commit: Data([0, 1, 2]), epoch: 7)
        let joinObject = try jsonObject(JSONEncoder.ermis.encode(externalJoin))
        XCTAssertEqual(joinObject["commit"] as? String, "AAEC")

        let enable = EnableEncryptionRequestBody(
            commit: Data([0]),
            welcome: Data([1]),
            ratchetTree: Data([2]),
            epoch: 8,
            groupInfo: Data([3])
        )
        let enableObject = try jsonObject(JSONEncoder.ermis.encode(enable))
        XCTAssertEqual(enableObject["commit"] as? String, "AA==")
        XCTAssertEqual(enableObject["welcome"] as? String, "AQ==")
        XCTAssertEqual(enableObject["ratchet_tree"] as? String, "Ag==")
        XCTAssertEqual(enableObject["group_info"] as? String, "Aw==")
    }

    func testMessageRequestAlwaysEncodesCiphertextAsBase64() throws {
        let body = MessageRequestBody(
            id: "message-1",
            user: UserRequestBody(id: "user-1", name: nil, imageURL: nil),
            text: "",
            encryptedData: [0, 1, 2]
        )
        let object = try jsonObject(JSONEncoder.ermis.encode(body))

        XCTAssertEqual(object["mls_ciphertext"] as? String, "AAEC")
        XCTAssertFalse(object["mls_ciphertext"] is [NSNumber])
    }

    func testDurableE2eeNetworkIntentReusesCiphertextAndRedactsPlaintextFields() throws {
        var body = MessageRequestBody(
            id: "message-1",
            user: UserRequestBody(id: "user-1", name: nil, imageURL: nil),
            text: "plaintext",
            attachments: [MessageAttachmentPayload(type: .unknown, payload: [:])],
            stickerUrl: URL(string: "https://example.invalid/sticker")
        )
        let ciphertext: [UInt8] = [0, 1, 2, 3]

        XCTAssertFalse(body.hasDurableE2eeNetworkIntent)
        body.bindE2eeNetworkIntent(ciphertext: ciphertext, epoch: 7)

        XCTAssertTrue(body.hasDurableE2eeNetworkIntent)
        XCTAssertEqual(body.encryptedData, ciphertext)
        XCTAssertEqual(body.mlsEpoch, 7)
        XCTAssertEqual(body.text, "")
        XCTAssertTrue(body.attachments.isEmpty)
        XCTAssertNil(body.stickerUrl)

        let object = try jsonObject(JSONEncoder.ermis.encode(body))
        XCTAssertEqual(object["mls_ciphertext"] as? String, "AAECAw==")
        XCTAssertEqual(object["mls_epoch"] as? Int, 7)
        XCTAssertNil(object["attachments"])
        XCTAssertNil(object["sticker_url"])
    }

    func testEncryptedStickerPayloadEncodesCanonicalSnakeCaseKey() throws {
        let stickerUrl = try XCTUnwrap(
            URL(string: "https://example.invalid/stickers/canonical.webp"))
        let payload = E2ePayload(text: "", attachments: [], stickerUrl: stickerUrl)

        let object = try jsonObject(JSONEncoder().encode(payload))

        XCTAssertEqual(object["sticker_url"] as? String, stickerUrl.absoluteString)
        XCTAssertNil(object["stickerUrl"])
    }

    func testEncryptedStickerPayloadDecodesCanonicalSnakeCaseKey() throws {
        let payload = try JSONDecoder().decode(
            E2ePayload.self,
            from: Data(
                #"{"text":"","attachments":[],"sticker_url":"https://example.invalid/stickers/web.webp"}"#
                    .utf8)
        )

        XCTAssertEqual(
            payload.stickerUrl?.absoluteString, "https://example.invalid/stickers/web.webp")
    }

    func testEncryptedStickerPayloadDecodesLegacyIosCamelCaseKey() throws {
        let payload = try JSONDecoder().decode(
            E2ePayload.self,
            from: Data(
                #"{"text":"","attachments":[],"stickerUrl":"https://example.invalid/stickers/legacy-ios.webp"}"#
                    .utf8)
        )

        XCTAssertEqual(
            payload.stickerUrl?.absoluteString, "https://example.invalid/stickers/legacy-ios.webp")
    }

    func testEncryptedStickerPayloadPrefersCanonicalKeyWhenBothArePresent() throws {
        let payload = try JSONDecoder().decode(
            E2ePayload.self,
            from: Data(
                #"{"text":"","attachments":[],"sticker_url":"https://example.invalid/stickers/canonical.webp","stickerUrl":"https://example.invalid/stickers/legacy.webp"}"#
                    .utf8)
        )

        XCTAssertEqual(
            payload.stickerUrl?.absoluteString, "https://example.invalid/stickers/canonical.webp")
    }

    func testInboundKeyPackageAcceptsBase64AndLegacyArray() throws {
        let base64 = try JSONDecoder().decode(
            KeyPackageEntry.self,
            from: Data(#"{"key_package":"AAEC","device_id":"device-1"}"#.utf8)
        )
        let legacy = try JSONDecoder().decode(
            KeyPackageEntry.self,
            from: Data(#"{"key_package":[0,1,2],"device_id":"device-1"}"#.utf8)
        )

        XCTAssertEqual(base64.keyPackage, [0, 1, 2])
        XCTAssertEqual(legacy.keyPackage, base64.keyPackage)
    }

    func testLegacyUsageTelemetryCountsOnlyLegacyRepresentations() throws {
        _ = try JSONDecoder().decode(
            KeyPackageEntry.self,
            from: Data(#"{"key_package":"AAEC","device_id":"device-1"}"#.utf8)
        )
        XCTAssertEqual(
            E2eeLegacyByteTelemetry.count(field: "key_package", source: .wireDecode),
            0
        )

        _ = try JSONDecoder().decode(
            KeyPackageEntry.self,
            from: Data(#"{"key_package":[0,1,2],"device_id":"device-1"}"#.utf8)
        )
        XCTAssertEqual(
            E2eeLegacyByteTelemetry.count(field: "key_package", source: .wireDecode),
            1
        )

        let queuedBody = Data(#"{"message":{"mls_ciphertext":[0,1,2]}}"#.utf8)
        _ = try E2eeLegacyRequestBodyNormalizer.normalizeIfNeeded(
            queuedBody,
            path: .sendE2eMessage(try ChannelId(cid: "team:project:channel-1"))
        )
        XCTAssertEqual(
            E2eeLegacyByteTelemetry.count(
                field: "mls_ciphertext",
                source: .offlineRequestReplay
            ),
            1
        )
    }

    func testInboundApplicationEventAcceptsBase64AndLegacyArray() throws {
        let base64 = try applicationEnvelope(ciphertextJSON: #""AAEC""#)
        let legacy = try applicationEnvelope(ciphertextJSON: "[0,1,2]")

        guard case .application(let base64Data) = base64.event,
            case .application(let legacyData) = legacy.event
        else {
            return XCTFail("Expected application events")
        }
        XCTAssertEqual(base64Data.mlsCiphertext, [0, 1, 2])
        XCTAssertEqual(legacyData.mlsCiphertext, base64Data.mlsCiphertext)
        XCTAssertEqual(base64.rawEnvelope, legacy.rawEnvelope)
    }

    func testNormalHttpRequestsAdvertiseBase64WireFormat() throws {
        let encoder = DefaultRequestEncoder(
            baseURL: URL(string: "https://bellboy.example")!,
            authURL: URL(string: "https://auth.example")!,
            stickerURL: URL(string: "https://stickers.example")!,
            apiKey: APIKey("test-key")
        )
        let endpoint = Endpoint<EmptyResponse>(
            path: .sync,
            method: .get,
            needToken: false
        )

        let request = try encoder.encodeRequest(for: endpoint)

        XCTAssertEqual(
            request.value(forHTTPHeaderField: E2eeByteWireFormat.headerName),
            E2eeByteWireFormat.headerValue
        )
    }

    func testWebSocketConnectAdvertisesBase64WireFormat() throws {
        let endpoint: Endpoint<EmptyResponse> = .webSocketConnect(
            userInfo: UserInfo(id: "user-1"),
            token: nil,
            deviceId: "device-1",
            apiKey: "test-key"
        )
        let data = try JSONEncoder.ermis.encode(AnyEncodable(endpoint.query!))
        let object = try jsonObject(data)

        XCTAssertEqual(
            object[E2eeByteWireFormat.webSocketQueryName] as? String,
            E2eeByteWireFormat.headerValue
        )
    }

    func testOldQueuedMessageBodyIsNormalizedBeforeNetworkReplay() throws {
        let legacy = Data(#"{"message":{"id":"message-1","mls_ciphertext":[0,1,2]}}"#.utf8)

        let normalized = try E2eeLegacyRequestBodyNormalizer.normalizeIfNeeded(
            legacy,
            path: .editMessage("message-1", try ChannelId(cid: "team:project:channel-1"))
        )
        let object = try jsonObject(normalized)
        let message = try XCTUnwrap(object["message"] as? [String: Any])

        XCTAssertEqual(message["mls_ciphertext"] as? String, "AAEC")
    }

    func testRequestNormalizerDoesNotTouchNonMessageEndpoints() throws {
        let legacy = Data(#"{"commit":[0,1,2]}"#.utf8)

        let untouched = try E2eeLegacyRequestBodyNormalizer.normalizeIfNeeded(
            legacy,
            path: .sync
        )

        XCTAssertEqual(untouched, legacy)
    }

    func testRequestNormalizerDoesNotRewriteAttachmentCustomFields() throws {
        let legacy = Data(
            #"{"message":{"mls_ciphertext":[0],"attachments":[{"commit":[1,2]}]}}"#.utf8)

        let normalized = try E2eeLegacyRequestBodyNormalizer.normalizeIfNeeded(
            legacy,
            path: .sendE2eMessage(try ChannelId(cid: "team:project:channel-1"))
        )
        let object = try jsonObject(normalized)
        let message = try XCTUnwrap(object["message"] as? [String: Any])
        let attachments = try XCTUnwrap(message["attachments"] as? [[String: Any]])

        XCTAssertEqual(message["mls_ciphertext"] as? String, "AA==")
        XCTAssertEqual(attachments.first?["commit"] as? [Int], [1, 2])
    }

    private func applicationEnvelope(ciphertextJSON: String) throws -> E2eSyncEventEnvelope {
        let json = """
            {
              "event_id": "11111111-1111-4111-8111-111111111111",
              "created_at": "2026-08-06T10:00:00.123456Z",
              "type": "application",
              "data": {
                "id": "message-1",
                "cid": "team:channel-1",
                "type": "regular",
                "mls_ciphertext": \(ciphertextJSON),
                "content_type": "text/plain",
                "created_at": "2026-08-06T10:00:00.123456Z"
              }
            }
            """
        return try JSONDecoder.default.decode(E2eSyncEventEnvelope.self, from: Data(json.utf8))
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
