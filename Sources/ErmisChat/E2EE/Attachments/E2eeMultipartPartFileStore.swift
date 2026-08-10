//
// Copyright 2026 Ermis Inc.
//

import CryptoKit
import Foundation

struct E2eeMultipartMaterializationResult: Equatable, Sendable {
    let parts: [PendingE2eeMultipartPart]
    let materializedPartNumbers: [Int]
}

/// Produces a bounded window of byte-identical files from canonical ciphertext. It never loads a
/// whole part into memory and never creates more than `clampedConcurrency + 1` live part files.
struct E2eeMultipartPartFileStore {
    static let defaultConcurrency = 3
    static let minimumConcurrency = 1
    static let maximumConcurrency = 4
    static let copyBufferSize = 256 * 1024

    let stagingStore: E2eeAttachmentStagingStore
    let fileManager: FileManager

    init(
        stagingStore: E2eeAttachmentStagingStore,
        fileManager: FileManager = .default
    ) {
        self.stagingStore = stagingStore
        self.fileManager = fileManager
    }

    static func clampedConcurrency(_ value: Int) -> Int {
        min(maximumConcurrency, max(minimumConcurrency, value))
    }

    func materializeWindow(
        attemptId: String,
        assetId: String,
        canonicalCiphertextURL: URL,
        parts inputParts: [PendingE2eeMultipartPart],
        concurrency: Int = defaultConcurrency
    ) throws -> E2eeMultipartMaterializationResult {
        guard stagingStore.isCanonicalCiphertext(canonicalCiphertextURL),
              fileManager.fileExists(atPath: canonicalCiphertextURL.path) else {
            throw E2eeAttachmentStagingError.invalidCanonicalCiphertext
        }
        let canonicalSize = try fileSize(canonicalCiphertextURL)
        guard inputParts.reduce(UInt64(0), { partial, part in
            let (sum, overflow) = partial.addingReportingOverflow(part.size)
            return overflow ? UInt64.max : sum
        }) == canonicalSize else {
            throw E2eeAttachmentStagingError.invalidCanonicalCiphertext
        }

        var parts = inputParts
        let windowLimit = Self.clampedConcurrency(concurrency) + 1
        var livePartCount = 0
        for index in parts.indices where parts[index].eTag == nil {
            guard let localURL = parts[index].localFileURL else { continue }
            if isValidPartFile(localURL, expectedSize: parts[index].size) {
                livePartCount += 1
            } else {
                if stagingStore.isMultipartPart(localURL) {
                    try? fileManager.removeItem(at: localURL)
                }
                parts[index].localFileURL = nil
            }
        }

        var newlyCreatedURLs: [URL] = []
        var materializedNumbers: [Int] = []
        do {
            for index in parts.indices {
                guard livePartCount < windowLimit else { break }
                guard parts[index].eTag == nil,
                      parts[index].taskIdentifier == nil,
                      parts[index].taskToken == nil,
                      parts[index].localFileURL == nil else { continue }

                let destination = try stagingStore.multipartPartURL(
                    attemptId: attemptId,
                    assetId: assetId,
                    partNumber: parts[index].number
                )
                if isValidPartFile(destination, expectedSize: parts[index].size) {
                    // Recover a byte-identical orphan left after atomic promotion but before the
                    // pending record update became durable.
                    parts[index].localFileURL = destination
                } else {
                    if fileManager.fileExists(atPath: destination.path) {
                        try fileManager.removeItem(at: destination)
                    }
                    try materialize(
                        source: canonicalCiphertextURL,
                        offset: parts[index].offset,
                        size: parts[index].size,
                        destination: destination
                    )
                    newlyCreatedURLs.append(destination)
                    parts[index].localFileURL = destination
                }
                livePartCount += 1
                materializedNumbers.append(parts[index].number)
            }
        } catch {
            for url in newlyCreatedURLs {
                try? fileManager.removeItem(at: url)
            }
            throw E2eeAttachmentStagingStore.classifyDiskError(error, stage: .partCreation)
        }

        return E2eeMultipartMaterializationResult(
            parts: parts,
            materializedPartNumbers: materializedNumbers
        )
    }

    /// Must be called only after the ETag-bearing record update is durable. Missing files are
    /// treated as already cleaned so relaunch cleanup is idempotent.
    func removeUploadedPartFiles(
        _ inputParts: [PendingE2eeMultipartPart]
    ) throws -> [PendingE2eeMultipartPart] {
        var parts = inputParts
        for index in parts.indices where parts[index].eTag != nil {
            if let url = parts[index].localFileURL {
                guard stagingStore.isMultipartPart(url) else {
                    throw E2eeAttachmentStagingError.invalidPartFile
                }
                if fileManager.fileExists(atPath: url.path) {
                    try fileManager.removeItem(at: url)
                }
                parts[index].localFileURL = nil
            }
        }
        return parts
    }

    private func materialize(
        source: URL,
        offset: UInt64,
        size: UInt64,
        destination: URL
    ) throws {
        let partial = stagingStore.partialURL(for: destination)
        guard fileManager.createFile(atPath: partial.path, contents: nil) else {
            throw E2eeAttachmentStagingError.invalidPartialFile
        }

        do {
            let input = try FileHandle(forReadingFrom: source)
            let output = try FileHandle(forWritingTo: partial)
            defer {
                try? input.close()
                try? output.close()
            }
            try input.seek(toOffset: offset)
            var remaining = size
            var expectedHash = SHA256()
            while remaining > 0 {
                let readSize = Int(min(UInt64(Self.copyBufferSize), remaining))
                guard let data = try input.read(upToCount: readSize), !data.isEmpty else {
                    throw E2eeAttachmentStagingError.invalidCanonicalCiphertext
                }
                try output.write(contentsOf: data)
                expectedHash.update(data: data)
                remaining -= UInt64(data.count)
            }
            try output.synchronize()
            try output.close()

            guard try fileSize(partial) == size,
                  try sha256(of: partial) == Data(expectedHash.finalize()) else {
                throw E2eeAttachmentStagingError.invalidPartFile
            }
            try stagingStore.promotePartialFile(partial, to: destination)
        } catch {
            stagingStore.removePartialFile(partial)
            throw error
        }
    }

    private func fileSize(_ url: URL) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size >= 0 else {
            throw E2eeAttachmentStagingError.invalidPartFile
        }
        return UInt64(size)
    }

    private func isValidPartFile(_ url: URL, expectedSize: UInt64) -> Bool {
        guard stagingStore.isMultipartPart(url), fileManager.fileExists(atPath: url.path) else {
            return false
        }
        return (try? fileSize(url)) == expectedSize
    }

    private func sha256(of url: URL) throws -> Data {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hasher = SHA256()
        while let data = try input.read(upToCount: Self.copyBufferSize), !data.isEmpty {
            hasher.update(data: data)
        }
        return Data(hasher.finalize())
    }
}
