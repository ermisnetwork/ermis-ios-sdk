//
// Copyright 2026 Ermis Inc.
//

import CryptoKit
import Foundation

enum E2eeAttachmentOriginalDownloadError: Error {
    case invalidOpaqueURL
    case missingMessage
    case missingManifest
    case missingOriginal
    case invalidHTTPResponse
    case invalidHTTPStatus(Int)
    case insufficientStorage
    case cipherSizeMismatch
    case cipherHashMismatch
    case plaintextSizeMismatch
    case plaintextHashMismatch
    case invalidKeyMaterial
}

/// Resolves an authenticated E2EE attachment manifest into a verified local plaintext file.
///
/// This is the full-download fallback required before range streaming is enabled. The original
/// remains ciphertext on the network and on the download staging path. Only after its declared
/// size and global SHA-256 match do we frame-decrypt it into the process-lifetime playback folder.
actor E2eeAttachmentOriginalDownloadCoordinator {
    private struct OpaqueAssetReference: Equatable {
        let attachmentId: String
        let assetId: String
    }

    private let apiClient: APIClient
    private let database: DatabaseContainer
    private let fileManager: FileManager
    private let playbackDirectory: URL
    private var completedURLs: [String: URL] = [:]
    private var inFlight: [String: Task<URL, Error>] = [:]

    init(
        apiClient: APIClient,
        database: DatabaseContainer,
        fileManager: FileManager = .default
    ) {
        self.apiClient = apiClient
        self.database = database
        self.fileManager = fileManager
        playbackDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("ErmisE2eeAttachmentPlayback", isDirectory: true)

        // A fresh client means no prior player session can still own these plaintext files.
        // Cleanup is deliberately best-effort; a later atomic replacement remains safe.
        try? fileManager.removeItem(at: playbackDirectory)
        try? Self.prepareDirectory(playbackDirectory, fileManager: fileManager)
    }

    func localOriginalURL(for attachment: AnyMessageAttachment) async throws -> URL {
        guard let remoteURL = attachment.remoteURL else {
            throw E2eeAttachmentOriginalDownloadError.invalidOpaqueURL
        }
        guard remoteURL.scheme == Self.opaqueScheme else { return remoteURL }

        let reference = try Self.parseReference(remoteURL)
        let cacheKey = reference.assetId.lowercased()
        if let completedURL = completedURLs[cacheKey],
           fileManager.fileExists(atPath: completedURL.path) {
            return completedURL
        }
        if let task = inFlight[cacheKey] {
            return try await task.value
        }

        let apiClient = apiClient
        let database = database
        let fileManager = fileManager
        let playbackDirectory = playbackDirectory
        let attachmentId = attachment.id
        let task = Task<URL, Error>(priority: .utility) {
            try await Self.downloadOriginal(
                attachmentId: attachmentId,
                reference: reference,
                apiClient: apiClient,
                database: database,
                fileManager: fileManager,
                playbackDirectory: playbackDirectory
            )
        }
        inFlight[cacheKey] = task

        do {
            let url = try await task.value
            inFlight[cacheKey] = nil
            completedURLs[cacheKey] = url
            return url
        } catch {
            inFlight[cacheKey] = nil
            throw error
        }
    }

    private static func downloadOriginal(
        attachmentId: AttachmentId,
        reference: OpaqueAssetReference,
        apiClient: APIClient,
        database: DatabaseContainer,
        fileManager: FileManager,
        playbackDirectory: URL
    ) async throws -> URL {
        let startedAt = Date()
        let manifest = try await loadManifest(
            messageId: attachmentId.messageId,
            attachmentIndex: attachmentId.index,
            reference: reference,
            database: database
        )
        try manifest.validate()
        guard let original = manifest.assets.first(where: {
            $0.kind == .original && $0.assetId.caseInsensitiveCompare(reference.assetId) == .orderedSame
        }) else {
            throw E2eeAttachmentOriginalDownloadError.missingOriginal
        }
        try preflightStorage(for: original, directory: playbackDirectory)

        log.info(
            "[E2EE_ATTACHMENT_DOWNLOAD] operation=original state=grant_requesting cipher_bytes=\(original.cipherSize)",
            subsystems: .mls
        )
        let grant = try await apiClient.e2eeAttachmentDownloadGrant(
            cid: attachmentId.cid,
            attachmentId: manifest.attachmentId,
            assetId: original.assetId
        )

        var request = URLRequest(url: grant.downloadURL)
        request.httpMethod = "GET"
        let (temporaryDownloadURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw E2eeAttachmentOriginalDownloadError.invalidHTTPResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw E2eeAttachmentOriginalDownloadError.invalidHTTPStatus(http.statusCode)
        }

        try prepareDirectory(playbackDirectory, fileManager: fileManager)
        let opaqueName = SHA256.hash(data: Data(original.assetId.utf8))
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
        let cipherURL = playbackDirectory.appendingPathComponent(opaqueName + ".cipher.partial")
        let plaintextURL = playbackDirectory.appendingPathComponent(
            opaqueName + "." + preferredExtension(for: original)
        )
        try? fileManager.removeItem(at: cipherURL)
        try? fileManager.removeItem(at: plaintextURL)
        do {
            try fileManager.moveItem(at: temporaryDownloadURL, to: cipherURL)
            try applyFileProtection(to: cipherURL, fileManager: fileManager)

            let attributes = try fileManager.attributesOfItem(atPath: cipherURL.path)
            guard let size = attributes[.size] as? NSNumber,
                  size.uint64Value == original.cipherSize else {
                throw E2eeAttachmentOriginalDownloadError.cipherSizeMismatch
            }
            guard try sha256Hex(of: cipherURL).caseInsensitiveCompare(original.cipherSha256) == .orderedSame else {
                throw E2eeAttachmentOriginalDownloadError.cipherHashMismatch
            }
            guard let contentKey = Data(base64Encoded: original.contentKey),
                  let noncePrefix = Data(base64Encoded: original.noncePrefix) else {
                throw E2eeAttachmentOriginalDownloadError.invalidKeyMaterial
            }

            let result = try E2eeAttachmentFrameCryptoV1.decryptFile(
                at: cipherURL,
                to: plaintextURL,
                contentKey: contentKey,
                noncePrefix: noncePrefix,
                frameSize: Int(original.frameSize)
            )
            guard result.ciphertextSize == original.cipherSize,
                  result.ciphertextSha256.caseInsensitiveCompare(original.cipherSha256) == .orderedSame else {
                throw E2eeAttachmentOriginalDownloadError.cipherHashMismatch
            }
            if let expectedSize = original.plaintextSize,
               result.plaintextSize != expectedSize {
                throw E2eeAttachmentOriginalDownloadError.plaintextSizeMismatch
            }
            if let expectedHash = original.plaintextSha256,
               result.plaintextSha256.caseInsensitiveCompare(expectedHash) != .orderedSame {
                throw E2eeAttachmentOriginalDownloadError.plaintextHashMismatch
            }
            try applyFileProtection(to: plaintextURL, fileManager: fileManager)
            try? fileManager.removeItem(at: cipherURL)
            log.info(
                "[E2EE_ATTACHMENT_DOWNLOAD] operation=original state=succeeded plaintext_bytes=\(result.plaintextSize) elapsed_ms=\(Int(Date().timeIntervalSince(startedAt) * 1000))",
                subsystems: .mls
            )
            return plaintextURL
        } catch {
            try? fileManager.removeItem(at: cipherURL)
            try? fileManager.removeItem(at: plaintextURL)
            log.error(
                "[E2EE_ATTACHMENT_DOWNLOAD] operation=original state=failed category=\(errorCategory(error))",
                subsystems: .mls
            )
            throw error
        }
    }

    private static func loadManifest(
        messageId: MessageId,
        attachmentIndex: Int,
        reference: OpaqueAssetReference,
        database: DatabaseContainer
    ) async throws -> E2eeAttachmentManifestV1 {
        try await withCheckedThrowingContinuation { continuation in
            let context = database.backgroundReadOnlyContext
            context.perform {
                guard let message = context.message(id: messageId),
                      let decrypted = message.decryptedMessage else {
                    continuation.resume(throwing: E2eeAttachmentOriginalDownloadError.missingMessage)
                    return
                }
                do {
                    let payload = try decrypted.asPayload()
                    let indexed = payload.e2eeAttachments.indices.contains(attachmentIndex)
                        ? payload.e2eeAttachments[attachmentIndex]
                        : nil
                    let manifest = indexed?.attachmentId.caseInsensitiveCompare(reference.attachmentId) == .orderedSame
                        ? indexed
                        : payload.e2eeAttachments.first {
                            $0.attachmentId.caseInsensitiveCompare(reference.attachmentId) == .orderedSame
                        }
                    guard let manifest else {
                        throw E2eeAttachmentOriginalDownloadError.missingManifest
                    }
                    continuation.resume(returning: manifest)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static let opaqueScheme = "ermis-e2ee-attachment"

    private static func parseReference(_ url: URL) throws -> OpaqueAssetReference {
        guard url.scheme == opaqueScheme,
              url.host == "asset" else {
            throw E2eeAttachmentOriginalDownloadError.invalidOpaqueURL
        }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count == 2,
              UUID(uuidString: components[0]) != nil,
              UUID(uuidString: components[1]) != nil else {
            throw E2eeAttachmentOriginalDownloadError.invalidOpaqueURL
        }
        return OpaqueAssetReference(attachmentId: components[0], assetId: components[1])
    }

    private static func preferredExtension(for asset: E2eeAttachmentManifestAssetV1) -> String {
        if let name = asset.display?["name"]?.stringValue {
            let value = URL(fileURLWithPath: name).pathExtension.lowercased()
            if !value.isEmpty, value.count <= 8 { return value }
        }
        switch asset.display?["mime_type"]?.stringValue?.lowercased() {
        case "video/quicktime": return "mov"
        case "video/x-m4v": return "m4v"
        case "image/jpeg": return "jpg"
        case "image/png": return "png"
        case "image/heic", "image/heif": return "heic"
        default: return "mp4"
        }
    }

    private static func preflightStorage(
        for asset: E2eeAttachmentManifestAssetV1,
        directory: URL
    ) throws {
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage else { return }
        let plaintext = asset.plaintextSize ?? asset.cipherSize
        let required = asset.cipherSize.addingReportingOverflow(plaintext)
        guard !required.overflow else { throw E2eeAttachmentOriginalDownloadError.insufficientStorage }
        let reserve = required.partialValue.addingReportingOverflow(100 * 1024 * 1024)
        guard !reserve.overflow, UInt64(max(0, available)) >= reserve.partialValue else {
            throw E2eeAttachmentOriginalDownloadError.insufficientStorage
        }
    }

    private static func prepareDirectory(_ url: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    private static func applyFileProtection(to url: URL, fileManager: FileManager) throws {
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    private static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize()).map { String(format: "%02x", $0) }.joined()
    }

    private static func errorCategory(_ error: Error) -> String {
        switch error {
        case E2eeAttachmentOriginalDownloadError.cipherHashMismatch,
             E2eeAttachmentOriginalDownloadError.plaintextHashMismatch:
            return "integrity"
        case E2eeAttachmentOriginalDownloadError.cipherSizeMismatch,
             E2eeAttachmentOriginalDownloadError.plaintextSizeMismatch:
            return "size"
        case E2eeAttachmentOriginalDownloadError.insufficientStorage:
            return "storage"
        case is CancellationError:
            return "canceled"
        default:
            return "download_or_decrypt"
        }
    }
}
