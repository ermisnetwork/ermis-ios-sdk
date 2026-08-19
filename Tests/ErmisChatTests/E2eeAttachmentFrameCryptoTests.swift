//
// Copyright 2026 Ermis Inc.
//

import CryptoKit
@testable import ErmisChat
import XCTest

final class E2eeAttachmentFrameCryptoTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("E2eeAttachmentFrameCryptoTests-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
    }

    func testEncryptedSizeContractIncludesAuthenticatedEmptyFrame() throws {
        XCTAssertEqual(
            try E2eeAttachmentFrameCryptoV1.estimatedCiphertextSize(plaintextSize: 0),
            24
        )
        XCTAssertEqual(
            try E2eeAttachmentFrameCryptoV1.estimatedCiphertextSize(plaintextSize: 1),
            25
        )
        XCTAssertEqual(
            try E2eeAttachmentFrameCryptoV1.estimatedCiphertextSize(
                plaintextSize: UInt64(E2eeAttachmentFrameCryptoV1.defaultFrameSize)
            ),
            UInt64(E2eeAttachmentFrameCryptoV1.defaultFrameSize + 24)
        )
        XCTAssertEqual(
            try E2eeAttachmentFrameCryptoV1.maximumPlaintextSize(),
            2_147_287_040
        )
        XCTAssertLessThanOrEqual(
            try E2eeAttachmentFrameCryptoV1.estimatedCiphertextSize(plaintextSize: 2_147_287_040),
            E2eeAttachmentFrameCryptoV1.originalCiphertextLimit
        )
        XCTAssertGreaterThan(
            try E2eeAttachmentFrameCryptoV1.estimatedCiphertextSize(plaintextSize: 2_147_287_041),
            E2eeAttachmentFrameCryptoV1.originalCiphertextLimit
        )
    }

    func testNonceMatchesWebBigEndianLayout() throws {
        let prefix = try XCTUnwrap(Data(base64Encoded: "8PHy8/T19vc="))
        XCTAssertEqual(
            try E2eeAttachmentFrameCryptoV1.nonceData(prefix: prefix, frameIndex: 0x0102_0304),
            try data(hex: "f0f1f2f3f4f5f6f701020304")
        )
    }

    func testEmptyFileMatchesWebCryptoVector() throws {
        try assertVector(
            name: "empty",
            plaintext: Data(),
            frameSize: 16,
            expectedCiphertextHex: "0000000000000010715896cfbf80df8c10223beeb74b78b9",
            expectedCiphertextSha256: "dd60f2d52e14bace6b197f7fc6c36ba7c931b6f8dd1b6e2307be70d588dd30a7"
        )
    }

    func testOneFrameMatchesWebCryptoVector() throws {
        try assertVector(
            name: "one",
            plaintext: Data("Ermis attachment vector".utf8),
            frameSize: 64,
            expectedCiphertextHex: "00000017000000270956d05660846cb675ffe6d22bc6327461a5651acfbb456abbe6b05e589b4b1979cc31d42e7cee",
            expectedCiphertextSha256: "8a312f9261b1be676de49c03651cbd94dbc15a746f3d786b1bca4e22847e94e7"
        )
    }

    func testMultipleFramesMatchWebCryptoVector() throws {
        try assertVector(
            name: "multi",
            plaintext: Data((0..<40).map(UInt8.init)),
            frameSize: 16,
            expectedCiphertextHex: "00000010000000204c25bf3c17a10bc509978fb14aae520f15a5ba7bfbfd5d0fc5c2e1db774656f1000000100000002080bbc1464d7b8f6d743ade2dc137cbd512ac9330ea985ad18b108d3bf52454f10000000800000018520fbceab3856f82c16c32c002c7e2c628bc0dc8cbd03bbd",
            expectedCiphertextSha256: "5c335282d419748c051ae7cafd905f95423eeb7406b4782c81e63f016ee5f3ff"
        )
    }

    func testTruncatedFrameFailsAndRemovesPartialPlaintext() throws {
        let input = directory.appendingPathComponent("truncated.cipher")
        let output = directory.appendingPathComponent("truncated.plain")
        try data(hex: "000000100000002000010203").write(to: input)

        XCTAssertThrowsError(
            try E2eeAttachmentFrameCryptoV1.decryptFile(
                at: input,
                to: output,
                contentKey: fixedKey,
                noncePrefix: fixedNoncePrefix,
                frameSize: 16
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testTamperedTagFailsAndRemovesPartialPlaintext() throws {
        let plain = directory.appendingPathComponent("tamper.plain")
        let cipher = directory.appendingPathComponent("tamper.cipher")
        let output = directory.appendingPathComponent("tamper.output")
        try Data("tamper".utf8).write(to: plain)
        _ = try E2eeAttachmentFrameCryptoV1.encryptFile(
            at: plain,
            to: cipher,
            contentKey: fixedKey,
            noncePrefix: fixedNoncePrefix,
            frameSize: 16
        )
        var bytes = try Data(contentsOf: cipher)
        bytes[bytes.index(before: bytes.endIndex)] ^= 0xff
        try bytes.write(to: cipher)

        XCTAssertThrowsError(
            try E2eeAttachmentFrameCryptoV1.decryptFile(
                at: cipher,
                to: output,
                contentKey: fixedKey,
                noncePrefix: fixedNoncePrefix,
                frameSize: 16
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testMultipartSplitAndReassemblyPreserveCanonicalBytesAndHash() throws {
        let plain = directory.appendingPathComponent("multipart.plain")
        let cipher = directory.appendingPathComponent("multipart.cipher")
        try Data((0..<200).map { UInt8($0 % 251) }).write(to: plain)
        let encrypted = try E2eeAttachmentFrameCryptoV1.encryptFile(
            at: plain,
            to: cipher,
            contentKey: fixedKey,
            noncePrefix: fixedNoncePrefix,
            frameSize: 16
        )
        let canonical = try Data(contentsOf: cipher)
        let partSize = 50
        let parts = stride(from: 0, to: canonical.count, by: partSize).map { offset in
            canonical[offset..<min(offset + partSize, canonical.count)]
        }
        let reassembled = parts.reduce(into: Data()) { $0.append(contentsOf: $1) }

        XCTAssertEqual(reassembled, canonical)
        XCTAssertEqual(sha256Hex(reassembled), encrypted.ciphertextSha256)
    }

    func testManifestRoundTripAndCanonicalEnvelopeVerification() throws {
        let first = "00000000-0000-0000-0000-0000000000ff"
        let second = "00000000-0000-0000-0000-000000000001"
        let asset = E2eeAttachmentManifestAssetV1(
            assetId: "11111111-1111-4111-8111-111111111111",
            kind: .original,
            cipherSize: 24,
            cipherSha256: String(repeating: "a", count: 64),
            frameSize: UInt32(E2eeAttachmentFrameCryptoV1.defaultFrameSize),
            contentKey: fixedKey.base64EncodedString(),
            noncePrefix: fixedNoncePrefix.base64EncodedString(),
            plaintextSize: 0,
            plaintextSha256: sha256Hex(Data()),
            display: ["name": "empty.txt", "mime_type": "text/plain", "size": 0]
        )
        let manifests = [
            E2eeAttachmentManifestV1(attachmentId: first, assets: [asset]),
            E2eeAttachmentManifestV1(
                attachmentId: second,
                assets: [
                    E2eeAttachmentManifestAssetV1(
                        assetId: "22222222-2222-4222-8222-222222222222",
                        kind: .original,
                        cipherSize: 24,
                        cipherSha256: String(repeating: "b", count: 64),
                        frameSize: UInt32(E2eeAttachmentFrameCryptoV1.defaultFrameSize),
                        contentKey: fixedKey.base64EncodedString(),
                        noncePrefix: fixedNoncePrefix.base64EncodedString(),
                        plaintextSize: 0,
                        plaintextSha256: sha256Hex(Data())
                    )
                ]
            )
        ]

        let encoded = try JSONEncoder.default.encode(manifests)
        let decoded = try JSONDecoder.default.decode([E2eeAttachmentManifestV1].self, from: encoded)
        XCTAssertEqual(decoded, manifests)
        XCTAssertNoThrow(try decoded.verifyCanonicalAttachmentIds([second, first]))
        XCTAssertThrowsError(try decoded.verifyCanonicalAttachmentIds([first]))
    }

    func testE2ePayloadDecodesWebAttachmentManifestWithoutLegacyFallback() throws {
        let json = #"""
        {
          "text":"caption",
          "attachments":[{
            "version":1,
            "attachment_id":"00000000-0000-4000-8000-000000000001",
            "assets":[{
              "asset_id":"00000000-0000-4000-8000-000000000002",
              "kind":"original",
              "cipher_size":24,
              "cipher_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
              "frame_size":262144,
              "content_key":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=",
              "nonce_prefix":"8PHy8/T19vc=",
              "plaintext_size":0,
              "plaintext_sha256":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
              "display":{"name":"empty.txt","mime_type":"text/plain","size":0}
            }]
          }]
        }
        """#

        let payload = try JSONDecoder.default.decode(E2ePayload.self, from: Data(json.utf8))

        XCTAssertEqual(payload.text, "caption")
        XCTAssertTrue(payload.attachments.isEmpty)
        XCTAssertEqual(payload.e2eeAttachments.count, 1)
        XCTAssertEqual(
            payload.e2eeAttachments.first?.attachmentId,
            "00000000-0000-4000-8000-000000000001"
        )
        XCTAssertNoThrow(
            try payload.e2eeAttachments.verifyCanonicalAttachmentIds([
                "00000000-0000-4000-8000-000000000001"
            ])
        )
    }

    func testMalformedManifestDoesNotFallBackToLegacyUnknownAttachment() throws {
        let json = #"""
        {
          "text":"",
          "attachments":[{
            "version":1,
            "attachment_id":"00000000-0000-4000-8000-000000000001"
          }]
        }
        """#

        XCTAssertThrowsError(
            try JSONDecoder.default.decode(E2ePayload.self, from: Data(json.utf8))
        )
    }

    func testLegacyAttachmentPayloadRoundTripRemainsCompatible() throws {
        let legacy = MessageAttachmentPayload(
            type: .image,
            payload: ["image_url": "https://example.invalid/image.jpg"]
        )
        let payload = E2ePayload(text: "legacy", attachments: [legacy], stickerUrl: nil)

        let decoded = try JSONDecoder.default.decode(
            E2ePayload.self,
            from: JSONEncoder.default.encode(payload)
        )

        XCTAssertEqual(decoded.attachments, [legacy])
        XCTAssertTrue(decoded.e2eeAttachments.isEmpty)
    }

    func testMixedAttachmentLanesAreRejectedOnEncode() throws {
        let legacy = MessageAttachmentPayload(type: .unknown, payload: [:])
        let payload = E2ePayload(
            text: "mixed",
            attachments: [legacy],
            e2eeAttachments: [makeEmptyManifest()],
            stickerUrl: nil
        )

        XCTAssertThrowsError(try JSONEncoder.default.encode(payload)) { error in
            XCTAssertEqual(error as? E2ePayloadCodingError, .mixedAttachmentLanes)
        }
    }

    func testAttachmentCacheReadsLegacyRowsAndVersionedManifestEnvelope() throws {
        let legacy = MessageAttachmentPayload(type: .file, payload: ["name": "legacy.txt"])
        let legacyData = try JSONEncoder.default.encode([legacy])
        XCTAssertEqual(
            try E2eCachedAttachments.decodeCompatible(from: legacyData),
            E2eCachedAttachments(legacy: [legacy])
        )

        let envelope = E2eCachedAttachments(e2ee: [makeEmptyManifest()])
        let envelopeData = try JSONEncoder.default.encode(envelope)
        XCTAssertEqual(
            try E2eCachedAttachments.decodeCompatible(from: envelopeData),
            envelope
        )
    }

    private var fixedKey: Data {
        Data((0..<32).map(UInt8.init))
    }

    private var fixedNoncePrefix: Data {
        Data([0xf0, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7])
    }

    private func makeEmptyManifest() -> E2eeAttachmentManifestV1 {
        E2eeAttachmentManifestV1(
            attachmentId: "00000000-0000-4000-8000-000000000001",
            assets: [
                E2eeAttachmentManifestAssetV1(
                    assetId: "00000000-0000-4000-8000-000000000002",
                    kind: .original,
                    cipherSize: 24,
                    cipherSha256: String(repeating: "a", count: 64),
                    frameSize: UInt32(E2eeAttachmentFrameCryptoV1.defaultFrameSize),
                    contentKey: fixedKey.base64EncodedString(),
                    noncePrefix: fixedNoncePrefix.base64EncodedString(),
                    plaintextSize: 0,
                    plaintextSha256: sha256Hex(Data())
                )
            ]
        )
    }

    private func assertVector(
        name: String,
        plaintext: Data,
        frameSize: Int,
        expectedCiphertextHex: String,
        expectedCiphertextSha256: String
    ) throws {
        let plainURL = directory.appendingPathComponent("\(name).plain")
        let cipherURL = directory.appendingPathComponent("\(name).cipher")
        let decryptedURL = directory.appendingPathComponent("\(name).decrypted")
        try plaintext.write(to: plainURL)

        let encrypted = try E2eeAttachmentFrameCryptoV1.encryptFile(
            at: plainURL,
            to: cipherURL,
            contentKey: fixedKey,
            noncePrefix: fixedNoncePrefix,
            frameSize: frameSize
        )
        XCTAssertEqual(try Data(contentsOf: cipherURL), try data(hex: expectedCiphertextHex))
        XCTAssertEqual(encrypted.ciphertextSha256, expectedCiphertextSha256)
        XCTAssertEqual(encrypted.ciphertextSize, UInt64(expectedCiphertextHex.count / 2))

        let decrypted = try E2eeAttachmentFrameCryptoV1.decryptFile(
            at: cipherURL,
            to: decryptedURL,
            contentKey: fixedKey,
            noncePrefix: fixedNoncePrefix,
            frameSize: frameSize
        )
        XCTAssertEqual(try Data(contentsOf: decryptedURL), plaintext)
        XCTAssertEqual(decrypted, encrypted)
    }

    private func data(hex: String) throws -> Data {
        guard hex.count.isMultiple(of: 2) else {
            throw CocoaError(.coderInvalidValue)
        }
        var output = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                throw CocoaError(.coderInvalidValue)
            }
            output.append(byte)
            index = next
        }
        return output
    }

    private func sha256Hex(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
    }
}
