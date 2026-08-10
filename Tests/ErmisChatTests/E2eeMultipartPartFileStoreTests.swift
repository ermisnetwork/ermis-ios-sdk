//
// Copyright 2026 Ermis Inc.
//

import Foundation
@testable import ErmisChat
import XCTest

final class E2eeMultipartPartFileStoreTests: XCTestCase {
    private var directory: URL!
    private var stagingStore: E2eeAttachmentStagingStore!
    private var partStore: E2eeMultipartPartFileStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("E2eeMultipartPartFileStoreTests-\(UUID().uuidString)")
        stagingStore = E2eeAttachmentStagingStore(
            rootURL: directory,
            capacityProvider: MultipartFixedCapacityProvider(capacity: UInt64.max)
        )
        partStore = E2eeMultipartPartFileStore(stagingStore: stagingStore)
        try stagingStore.prepareEncryptedDirectories()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        partStore = nil
        stagingStore = nil
        directory = nil
    }

    func testServerPartPlanUsesExactGapFreeCanonicalOffsets() throws {
        let response = try makeMultipartResponse(cipherSize: 25, partSize: 10)

        let parts = try response.makePendingMultipartParts()

        XCTAssertEqual(parts.map(\.number), [1, 2, 3])
        XCTAssertEqual(parts.map(\.offset), [0, 10, 20])
        XCTAssertEqual(parts.map(\.size), [10, 10, 5])
        XCTAssertEqual(parts.compactMap(\.putURL), response.multipart?.parts.map(\.putURL))
    }

    func testMaterializedPartsReconstructCanonicalCiphertextByteForByte() throws {
        let canonical = try writeCanonicalCiphertext(byteCount: 35)
        let response = try makeMultipartResponse(cipherSize: 35, partSize: 10)
        let plannedParts = try response.makePendingMultipartParts()

        let result = try partStore.materializeWindow(
            attemptId: UUID().uuidString,
            assetId: response.assetId,
            canonicalCiphertextURL: canonical,
            parts: plannedParts,
            concurrency: 3
        )

        XCTAssertEqual(result.materializedPartNumbers, [1, 2, 3, 4])
        let reconstructed = try result.parts.reduce(into: Data()) { output, part in
            output.append(try Data(contentsOf: XCTUnwrap(part.localFileURL)))
        }
        XCTAssertEqual(reconstructed, try Data(contentsOf: canonical))
        XCTAssertTrue(try multipartPartialFiles().isEmpty)
    }

    func testPartWindowIsBoundedToClampedConcurrencyPlusOne() throws {
        let canonical = try writeCanonicalCiphertext(byteCount: 100)
        let response = try makeMultipartResponse(cipherSize: 100, partSize: 10)
        let plannedParts = try response.makePendingMultipartParts()

        let minimum = try partStore.materializeWindow(
            attemptId: UUID().uuidString,
            assetId: response.assetId,
            canonicalCiphertextURL: canonical,
            parts: plannedParts,
            concurrency: 0
        )
        XCTAssertEqual(minimum.parts.compactMap(\.localFileURL).count, 2)

        let otherAttempt = UUID().uuidString
        let maximum = try partStore.materializeWindow(
            attemptId: otherAttempt,
            assetId: response.assetId,
            canonicalCiphertextURL: canonical,
            parts: plannedParts,
            concurrency: 99
        )
        XCTAssertEqual(maximum.parts.compactMap(\.localFileURL).count, 5)
        XCTAssertEqual(E2eeMultipartPartFileStore.clampedConcurrency(0), 1)
        XCTAssertEqual(E2eeMultipartPartFileStore.clampedConcurrency(99), 4)
    }

    func testUploadedPartFileIsDeletedOnlyAfterETagIsPresent() throws {
        let canonical = try writeCanonicalCiphertext(byteCount: 20)
        let response = try makeMultipartResponse(cipherSize: 20, partSize: 10)
        let materialized = try partStore.materializeWindow(
            attemptId: UUID().uuidString,
            assetId: response.assetId,
            canonicalCiphertextURL: canonical,
            parts: try response.makePendingMultipartParts(),
            concurrency: 1
        )
        let firstURL = try XCTUnwrap(materialized.parts[0].localFileURL)
        let secondURL = try XCTUnwrap(materialized.parts[1].localFileURL)
        var durableParts = materialized.parts
        durableParts[0].eTag = "etag-1"

        let cleaned = try partStore.removeUploadedPartFiles(durableParts)

        XCTAssertNil(cleaned[0].localFileURL)
        XCTAssertNotNil(cleaned[1].localFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
    }

    private func writeCanonicalCiphertext(byteCount: Int) throws -> URL {
        let url = stagingStore.canonicalCiphertextDirectory
            .appendingPathComponent("\(UUID().uuidString).cipher")
        let bytes = Data((0..<byteCount).map { UInt8($0 % 251) })
        try bytes.write(to: url)
        return url
    }

    private func makeMultipartResponse(
        cipherSize: UInt64,
        partSize: UInt64
    ) throws -> InitE2eeAttachmentAssetResponse {
        let count = Int((cipherSize + partSize - 1) / partSize)
        return InitE2eeAttachmentAssetResponse(
            assetId: UUID().uuidString,
            kind: .original,
            uploadMode: .multipart,
            putURL: nil,
            multipart: InitE2eeAttachmentMultipartResponse(
                multipartUploadId: "opaque-upload",
                partSize: partSize,
                partCount: count,
                maxPartRetries: 3,
                retryMaxElapsedSeconds: 300,
                parts: try (1...count).map { number in
                    InitE2eeAttachmentMultipartPartResponse(
                        partNumber: number,
                        putURL: try XCTUnwrap(URL(string: "https://upload.example.test/part-\(number)"))
                    )
                }
            ),
            objectKey: "opaque-object-key",
            cipherSizeEstimate: cipherSize
        )
    }

    private func multipartPartialFiles() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: stagingStore.multipartDirectory.path) else {
            return []
        }
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: stagingStore.multipartDirectory,
                includingPropertiesForKeys: nil
            )
        )
        return enumerator.compactMap { $0 as? URL }.filter {
            $0.lastPathComponent.hasSuffix(".partial")
        }
    }
}

private struct MultipartFixedCapacityProvider: E2eeAttachmentCapacityProviding {
    let capacity: UInt64

    func availableCapacity(at url: URL) throws -> UInt64 {
        capacity
    }
}
