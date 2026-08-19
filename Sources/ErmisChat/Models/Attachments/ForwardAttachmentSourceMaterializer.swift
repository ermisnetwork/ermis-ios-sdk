//
// Copyright 2026 Ermis Inc.
//

import Foundation
import UniformTypeIdentifiers

enum ForwardAttachmentSourceMaterializationError: Error, Equatable {
    case invalidRemoteURL
    case invalidHTTPResponse
    case invalidHTTPStatus(Int)
    case attachmentTooLarge
    case downloadedFileUnavailable
}

/// Materializes a standard/legacy remote attachment as a lease-owned local file before a fresh
/// destination upload. `URLSession.download` writes response bytes directly to disk, avoiding the
/// full-file `Data` allocation used by the legacy export downloader.
final class ForwardAttachmentRemoteSourceMaterializer {
    private let sessionConfiguration: URLSessionConfiguration
    private let fileManager: FileManager
    private let rootURL: URL
    private let maximumBytes: Int64

    init(
        sessionConfiguration: URLSessionConfiguration = .ephemeral,
        fileManager: FileManager = .default,
        rootURL: URL? = nil,
        maximumBytes: Int64
    ) {
        self.sessionConfiguration = sessionConfiguration
        self.fileManager = fileManager
        // Share the plaintext playback root so eager client startup cleanup also removes a
        // source left behind if the app is terminated before its forwarding lease is released.
        self.rootURL = rootURL ?? E2eeAttachmentOriginalDownloadCoordinator
            .defaultPlaybackDirectory(fileManager: fileManager)
            .appendingPathComponent("ForwardSources", isDirectory: true)
        self.maximumBytes = maximumBytes
    }

    func materialize(
        remoteURL: URL,
        preferredFileExtension: String?
    ) async throws -> E2eeAttachmentOriginalLease {
        guard let scheme = remoteURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw ForwardAttachmentSourceMaterializationError.invalidRemoteURL
        }

        let session = URLSession(configuration: sessionConfiguration)
        defer { session.finishTasksAndInvalidate() }
        let (temporaryURL, response) = try await session.download(for: URLRequest(url: remoteURL))
        guard let http = response as? HTTPURLResponse else {
            throw ForwardAttachmentSourceMaterializationError.invalidHTTPResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ForwardAttachmentSourceMaterializationError.invalidHTTPStatus(http.statusCode)
        }
        if response.expectedContentLength > maximumBytes {
            throw ForwardAttachmentSourceMaterializationError.attachmentTooLarge
        }
        try Task.checkCancellation()

        try prepareRootDirectory()
        let fileExtension = Self.sanitizedFileExtension(preferredFileExtension)
        let suffix = fileExtension.map { ".\($0)" } ?? ""
        let ownedURL = rootURL.appendingPathComponent(
            "\(UUID().uuidString)\(suffix)",
            isDirectory: false
        )

        do {
            try fileManager.moveItem(at: temporaryURL, to: ownedURL)
            let attributes = try fileManager.attributesOfItem(atPath: ownedURL.path)
            guard let number = attributes[.size] as? NSNumber else {
                throw ForwardAttachmentSourceMaterializationError.downloadedFileUnavailable
            }
            guard number.int64Value <= maximumBytes else {
                throw ForwardAttachmentSourceMaterializationError.attachmentTooLarge
            }
            try protectFile(at: ownedURL)
        } catch {
            try? fileManager.removeItem(at: ownedURL)
            throw error
        }

        let remover = ForwardAttachmentFileRemover(fileManager: fileManager)
        return E2eeAttachmentOriginalLease(localURL: ownedURL) {
            remover.removeItem(at: ownedURL)
        }
    }

    static func preferredFileExtension(for attachment: AnyMessageAttachment) -> String? {
        let candidates = [
            attachment.remoteURL?.pathExtension,
            attachment.title.map { URL(fileURLWithPath: $0).pathExtension },
            attachment.mimetype.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension }
        ]
        return candidates.compactMap { sanitizedFileExtension($0) }.first
    }

    private func prepareRootDirectory() throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = rootURL
        try mutableURL.setResourceValues(values)
#if os(iOS)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: rootURL.path
        )
#endif
    }

    private func protectFile(at url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
#if os(iOS)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
#endif
    }

    private static func sanitizedFileExtension(_ value: String?) -> String? {
        guard let value else { return nil }
        let sanitized = value.lowercased().filter { $0.isLetter || $0.isNumber }
        guard !sanitized.isEmpty else { return nil }
        return String(sanitized.prefix(10))
    }
}

/// `FileManager` is thread-safe for independent file operations but does not declare Sendable.
/// Keep that Foundation compatibility detail behind one narrowly scoped unchecked wrapper.
private final class ForwardAttachmentFileRemover: @unchecked Sendable {
    private let fileManager: FileManager

    init(fileManager: FileManager) {
        self.fileManager = fileManager
    }

    func removeItem(at url: URL) {
        try? fileManager.removeItem(at: url)
    }
}
