//
// Copyright 2026 Ermis Inc.
//

import Foundation

enum BackgroundTransferFixedError: String, Codable, Sendable {
    case none
    case canceled
    case timedOut
    case networkLost
    case cannotConnect
    case notConnected
    case httpClient
    case httpServer
    case unknown
}

enum BackgroundTransferEventKind: String, Codable, Sendable {
    case progress
    case completion
}

/// Deliberately contains no account/user/CID/message/attachment IDs, URL, filename, or request.
struct BackgroundTransferEvent: Codable, Equatable, Sendable {
    let eventId: String
    let taskToken: String
    let taskIdentifier: Int
    let kind: BackgroundTransferEventKind
    let completedBytes: Int64
    let totalBytes: Int64
    let httpStatus: Int?
    let eTag: String?
    let error: BackgroundTransferFixedError

    init(
        eventId: String = UUID().uuidString,
        taskToken: String,
        taskIdentifier: Int,
        kind: BackgroundTransferEventKind = .completion,
        completedBytes: Int64,
        totalBytes: Int64,
        httpStatus: Int?,
        eTag: String?,
        error: BackgroundTransferFixedError
    ) {
        self.eventId = eventId
        self.taskToken = taskToken
        self.taskIdentifier = taskIdentifier
        self.kind = kind
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.httpStatus = httpStatus
        self.eTag = eTag
        self.error = error
    }
}

enum BackgroundTransferEventJournalError: Error, Equatable {
    case invalidOpaqueToken
    case invalidEvent
    case corruptJournal
}

/// Append-only opaque callback journal. Its serial queue is intended to be the URLSession delegate
/// target. `append` returns only after the record is synchronized to disk.
final class BackgroundTransferEventJournal {
    private let url: URL
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "network.ermis.e2ee.background-transfer-journal")

    init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    func append(_ event: BackgroundTransferEvent) throws {
        try queue.sync {
            try validate(event)
            try prepareLocked()
            let data = try JSONEncoder.default.encode(event)
            var record = Data()
            appendUInt32(UInt32(data.count), to: &record)
            record.append(data)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: record)
            try handle.synchronize()
        }
    }

    func readAll() throws -> [BackgroundTransferEvent] {
        try queue.sync { try readAllLocked().events }
    }

    /// Rewrites only events the durable transfer store has not applied. The replacement is atomic;
    /// callers must persist ETags/results before returning an event ID as applied.
    func compact(removingEventIds applied: Set<String>) throws {
        try queue.sync {
            let parsed = try readAllLocked()
            let remaining = parsed.events.filter { !applied.contains($0.eventId) }
            var output = Data()
            for event in remaining {
                let encoded = try JSONEncoder.default.encode(event)
                appendUInt32(UInt32(encoded.count), to: &output)
                output.append(encoded)
            }
            // Retain an incomplete trailing append; it must not be silently treated as handled.
            output.append(parsed.trailingBytes)
            let partial = url.deletingLastPathComponent().appendingPathComponent(
                ".\(url.lastPathComponent).\(UUID().uuidString).partial"
            )
            try output.write(to: partial, options: [.withoutOverwriting])
            try setNoProtectionLocked(partial)
            _ = try fileManager.replaceItemAt(url, withItemAt: partial)
            try setNoProtectionLocked(url)
        }
    }

    private func readAllLocked() throws -> (events: [BackgroundTransferEvent], trailingBytes: Data) {
        try prepareLocked()
        let data = try Data(contentsOf: url)
        var offset = 0
        var events: [BackgroundTransferEvent] = []
        var eventIds = Set<String>()
        while data.count - offset >= 4 {
            let length = Int(readUInt32(data, offset: offset))
            guard length > 0 else { throw BackgroundTransferEventJournalError.corruptJournal }
            let payloadStart = offset + 4
            guard data.count - payloadStart >= length else { break }
            let payload = data[payloadStart..<(payloadStart + length)]
            let event = try JSONDecoder.default.decode(BackgroundTransferEvent.self, from: payload)
            try validate(event)
            if eventIds.insert(event.eventId).inserted {
                events.append(event)
            }
            offset = payloadStart + length
        }
        return (events, Data(data[offset...]))
    }

    private func validate(_ event: BackgroundTransferEvent) throws {
        guard UUID(uuidString: event.eventId) != nil,
              UUID(uuidString: event.taskToken) != nil else {
            throw BackgroundTransferEventJournalError.invalidOpaqueToken
        }
        guard event.taskIdentifier >= 0,
              event.completedBytes >= 0,
              event.totalBytes >= 0,
              event.completedBytes <= event.totalBytes || event.totalBytes == 0 else {
            throw BackgroundTransferEventJournalError.invalidEvent
        }
    }

    private func prepareLocked() throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try setNoProtectionLocked(directory)
        if !fileManager.fileExists(atPath: url.path) {
            guard fileManager.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        try setNoProtectionLocked(url)
    }

    private func setNoProtectionLocked(_ file: URL) throws {
#if os(iOS)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.none],
            ofItemAtPath: file.path
        )
#endif
    }

    private func appendUInt32(_ value: UInt32, to output: inout Data) {
        output.append(UInt8((value >> 24) & 0xff))
        output.append(UInt8((value >> 16) & 0xff))
        output.append(UInt8((value >> 8) & 0xff))
        output.append(UInt8(value & 0xff))
    }

    private func readUInt32(_ data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24 |
            UInt32(data[offset + 1]) << 16 |
            UInt32(data[offset + 2]) << 8 |
            UInt32(data[offset + 3])
    }
}
