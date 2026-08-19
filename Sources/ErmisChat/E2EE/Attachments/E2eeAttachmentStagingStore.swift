//
// Copyright 2026 Ermis Inc.
//

import Foundation

enum E2eeAttachmentDiskStage: String, Codable, Sendable {
    case sourceCopy
    case preview
    case encryption
    case partCreation
    case download
    case export
}

enum E2eeAttachmentStagingError: Error, Equatable {
    case sizeOverflow
    case capacityUnavailable
    case insufficientCapacity(required: UInt64, available: UInt64)
    case noSpace(E2eeAttachmentDiskStage)
    case invalidPartialFile
    case destinationAlreadyExists
    case invalidStagingIdentifier
    case invalidCanonicalCiphertext
    case invalidPartFile
}

protocol E2eeAttachmentCapacityProviding {
    func availableCapacity(at url: URL) throws -> UInt64
}

struct E2eeAttachmentVolumeCapacityProvider: E2eeAttachmentCapacityProviding {
    func availableCapacity(at url: URL) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let capacity = values.volumeAvailableCapacityForImportantUsage, capacity >= 0 else {
            throw E2eeAttachmentStagingError.capacityUnavailable
        }
        return UInt64(capacity)
    }
}

/// Owns non-evictable ciphertext and multipart working files. All durable encrypted directories
/// are excluded from backup and use protection that remains accessible after the first unlock.
struct E2eeAttachmentStagingStore {
    static let reserveBytes: UInt64 = 100 * 1024 * 1024

    let rootURL: URL
    let fileManager: FileManager
    let capacityProvider: E2eeAttachmentCapacityProviding

    init(
        rootURL: URL,
        fileManager: FileManager = .default,
        capacityProvider: E2eeAttachmentCapacityProviding = E2eeAttachmentVolumeCapacityProvider()
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        self.capacityProvider = capacityProvider
    }

    var canonicalCiphertextDirectory: URL {
        rootURL.appendingPathComponent("ciphertext", isDirectory: true)
    }

    var sourceDirectory: URL {
        rootURL.appendingPathComponent("sources", isDirectory: true)
    }

    var multipartDirectory: URL {
        rootURL.appendingPathComponent("multipart", isDirectory: true)
    }

    var downloadDirectory: URL {
        rootURL.appendingPathComponent("downloads", isDirectory: true)
    }

    func prepareEncryptedDirectories() throws {
        try prepare(rootURL)
        try prepare(sourceDirectory)
        try prepare(canonicalCiphertextDirectory)
        try prepare(multipartDirectory)
        try prepare(downloadDirectory)
    }

    func sourceURL(attemptId: String, attachmentIndex: Int, fileExtension: String?) throws -> URL {
        guard UUID(uuidString: attemptId) != nil, attachmentIndex >= 0 else {
            throw E2eeAttachmentStagingError.invalidStagingIdentifier
        }
        try prepareEncryptedDirectories()
        let safeExtension = fileExtension?
            .filter { $0.isLetter || $0.isNumber }
            .prefix(10)
        let suffix = safeExtension.flatMap { $0.isEmpty ? nil : ".\($0)" } ?? ""
        return sourceDirectory.appendingPathComponent("\(attemptId)-\(attachmentIndex)\(suffix)")
    }

    func canonicalCiphertextURL(attemptId: String, assetIndex: Int) throws -> URL {
        guard UUID(uuidString: attemptId) != nil, assetIndex >= 0 else {
            throw E2eeAttachmentStagingError.invalidStagingIdentifier
        }
        try prepareEncryptedDirectories()
        return canonicalCiphertextDirectory.appendingPathComponent("\(attemptId)-\(assetIndex).cipher")
    }

    /// Copies a plaintext source without loading the whole file into memory. The destination is
    /// never visible until the copy has completed and file protection has been applied.
    func stageSourceFile(from source: URL, to destination: URL) throws {
        let partial = partialURL(for: destination)
        do {
            try fileManager.copyItem(at: source, to: partial)
            try promotePartialFile(partial, to: destination)
        } catch {
            removePartialFile(partial)
            throw Self.classifyDiskError(error, stage: .sourceCopy)
        }
    }

    /// Preview bytes are already bounded, but still use the same durable partial-file boundary as
    /// original sources. Foundation traps when `.atomic` and `.withoutOverwriting` are combined,
    /// so the sibling partial file provides atomic promotion explicitly.
    func stagePreviewData(_ data: Data, to destination: URL) throws {
        let partial = partialURL(for: destination)
        do {
            try data.write(to: partial, options: [.withoutOverwriting])
            try promotePartialFile(partial, to: destination)
        } catch {
            removePartialFile(partial)
            throw Self.classifyDiskError(error, stage: .preview)
        }
    }

    func removeSource(_ url: URL) throws {
        guard Self.isDescendant(url, of: sourceDirectory) else {
            throw E2eeAttachmentStagingError.invalidStagingIdentifier
        }
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    func secureStagedFile(_ url: URL) throws {
        guard Self.isDescendant(url, of: rootURL) else {
            throw E2eeAttachmentStagingError.invalidStagingIdentifier
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
        try protect(url)
    }

    func multipartAssetDirectory(attemptId: String, assetId: String) throws -> URL {
        guard UUID(uuidString: attemptId) != nil, UUID(uuidString: assetId) != nil else {
            throw E2eeAttachmentStagingError.invalidStagingIdentifier
        }
        try prepareEncryptedDirectories()
        let attemptDirectory = multipartDirectory.appendingPathComponent(attemptId, isDirectory: true)
        let assetDirectory = attemptDirectory.appendingPathComponent(assetId, isDirectory: true)
        try prepare(attemptDirectory)
        try prepare(assetDirectory)
        return assetDirectory
    }

    func multipartPartURL(attemptId: String, assetId: String, partNumber: Int) throws -> URL {
        guard partNumber > 0 else {
            throw E2eeAttachmentStagingError.invalidStagingIdentifier
        }
        return try multipartAssetDirectory(attemptId: attemptId, assetId: assetId)
            .appendingPathComponent(String(format: "part-%03d.cipher", partNumber))
    }

    func isCanonicalCiphertext(_ url: URL) -> Bool {
        Self.isDescendant(url, of: canonicalCiphertextDirectory)
    }

    func isMultipartPart(_ url: URL) -> Bool {
        Self.isDescendant(url, of: multipartDirectory)
    }

    func removeMultipartAssetDirectory(attemptId: String, assetId: String) throws {
        guard UUID(uuidString: attemptId) != nil, UUID(uuidString: assetId) != nil else {
            throw E2eeAttachmentStagingError.invalidStagingIdentifier
        }
        // Cleanup must not call `multipartAssetDirectory`, because that helper prepares the
        // directory hierarchy and would recreate an already-clean staging directory.
        let assetDirectory = multipartDirectory
            .appendingPathComponent(attemptId, isDirectory: true)
            .appendingPathComponent(assetId, isDirectory: true)
        guard fileManager.fileExists(atPath: assetDirectory.path) else { return }
        try fileManager.removeItem(at: assetDirectory)
    }

    func removeCanonicalCiphertext(_ url: URL) throws {
        guard isCanonicalCiphertext(url) else {
            throw E2eeAttachmentStagingError.invalidCanonicalCiphertext
        }
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    func preflight(
        originalCipherSize: UInt64,
        previewCipherSize: UInt64,
        partCount: Int,
        concurrency: Int,
        partSize: UInt64
    ) throws {
        try prepareEncryptedDirectories()
        let required = try Self.requiredCapacity(
            originalCipherSize: originalCipherSize,
            previewCipherSize: previewCipherSize,
            partCount: partCount,
            concurrency: concurrency,
            partSize: partSize
        )
        let available = try capacityProvider.availableCapacity(at: rootURL)
        guard available >= required else {
            throw E2eeAttachmentStagingError.insufficientCapacity(
                required: required,
                available: available
            )
        }
    }

    static func requiredCapacity(
        originalCipherSize: UInt64,
        previewCipherSize: UInt64,
        partCount: Int,
        concurrency: Int,
        partSize: UInt64
    ) throws -> UInt64 {
        guard partCount >= 0, concurrency >= 0 else {
            throw E2eeAttachmentStagingError.sizeOverflow
        }
        let (windowSize, windowOverflow) = concurrency.addingReportingOverflow(1)
        guard !windowOverflow else { throw E2eeAttachmentStagingError.sizeOverflow }
        let boundedPartCount = min(partCount, windowSize)
        guard let partWindow = UInt64(exactly: boundedPartCount) else {
            throw E2eeAttachmentStagingError.sizeOverflow
        }
        let (workingSet, multiplyOverflow) = partWindow.multipliedReportingOverflow(by: partSize)
        guard !multiplyOverflow else { throw E2eeAttachmentStagingError.sizeOverflow }

        var required = originalCipherSize
        for value in [previewCipherSize, workingSet, reserveBytes] {
            let (sum, overflow) = required.addingReportingOverflow(value)
            guard !overflow else { throw E2eeAttachmentStagingError.sizeOverflow }
            required = sum
        }
        return required
    }

    /// Returns a sibling temporary URL. Writers must close and hash this file before calling
    /// `promotePartialFile`; a failed writer can delete it without touching a valid destination.
    func partialURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).partial"
        )
    }

    func promotePartialFile(_ partial: URL, to destination: URL) throws {
        guard partial.lastPathComponent.hasSuffix(".partial") else {
            throw E2eeAttachmentStagingError.invalidPartialFile
        }
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw E2eeAttachmentStagingError.destinationAlreadyExists
        }
        try fileManager.moveItem(at: partial, to: destination)
        try protect(destination)
    }

    func removePartialFile(_ partial: URL) {
        guard partial.lastPathComponent.hasSuffix(".partial") else { return }
        try? fileManager.removeItem(at: partial)
    }

    static func classifyDiskError(
        _ error: Error,
        stage: E2eeAttachmentDiskStage
    ) -> Error {
        var visited = Set<ObjectIdentifier>()
        if containsNoSpaceError(error as NSError, visited: &visited) {
            return E2eeAttachmentStagingError.noSpace(stage)
        }
        return error
    }

    private static func containsNoSpaceError(
        _ error: NSError,
        visited: inout Set<ObjectIdentifier>
    ) -> Bool {
        guard visited.insert(ObjectIdentifier(error)).inserted else { return false }
        if (error.domain == NSCocoaErrorDomain
            && error.code == CocoaError.fileWriteOutOfSpace.rawValue)
            || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOSPC)) {
            return true
        }
        guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError else {
            return false
        }
        return containsNoSpaceError(underlying, visited: &visited)
    }

    private func prepare(_ directory: URL) throws {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try mutableDirectory.setResourceValues(values)
        try protect(directory)
    }

    private func protect(_ url: URL) throws {
#if os(iOS)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
#endif
    }

    private static func isDescendant(_ file: URL, of directory: URL) -> Bool {
        let filePath = file.standardizedFileURL.resolvingSymlinksInPath().path
        let directoryPath = directory.standardizedFileURL.resolvingSymlinksInPath().path
        return filePath.hasPrefix(directoryPath + "/")
    }
}
