import Foundation
import ErmisShared

/// Opt-in diagnostics for owner-operated device tests. Only fixed markers reach disk.
/// The host enables this on Debug Uhm Dev; it is not a crypto durability journal.
public final class MlsFieldLogDestination: BaseLogDestination {
    private let lock = NSLock()
    private var directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        .first?.appendingPathComponent("mls-field-capture", isDirectory: true)
    private var writer: MlsFieldLogWriter?
    private var failureReported = false
    private var pendingFailure = false

    public convenience init(directoryURL: URL) {
        self.init(identifier: "mls-field", level: .info, subsystems: .mls, showDate: false,
                  dateFormatter: DateFormatter(), formatters: [], showLevel: false,
                  showIdentifier: false, showThreadName: false, showFileName: false,
                  showLineNumber: false, showFunctionName: false)
        self.directoryURL = directoryURL
    }

    public override func process(logDetails: LogDetails) {
        guard let marker = MlsFieldMarkerProjector.project(logDetails.message) else { return }
        lock.lock()
        defer { lock.unlock() }
        do {
            if writer == nil {
                guard let directoryURL else { throw MlsFieldLogWriter.Failure.invalidDirectory }
                writer = try MlsFieldLogWriter(directoryURL: directoryURL)
                try writer?.append(marker: "mls_field_log_checkpoint result=started", date: logDetails.date)
            }
            if pendingFailure {
                try writer?.append(marker: "mls_field_log_checkpoint result=write_failed", date: logDetails.date)
                pendingFailure = false
            }
            try writer?.append(marker: marker, date: logDetails.date)
        } catch {
            pendingFailure = true
            // Do not recurse through Logger or expose paths/underlying errors.
            if !failureReported {
                failureReported = true
                debugPrint("mls_field_log_checkpoint result=write_failed")
            }
        }
    }
}

enum MlsFieldMarkerProjector {
    struct Contract: Decodable {
        struct Field: Decodable {
            let name: String
            let values: Set<String>
        }
        let version: Int
        let maximum_input_bytes: Int
        let maximum_marker_bytes: Int
        let plain_patterns: [String]
        let join_stages: Set<String>
        let join_sources: Set<String>
        let join_fields: [Field]
    }

    static let contract: Contract? = {
        guard let url = Bundle.module.url(forResource: "MlsFieldMarkerContract", withExtension: "json"),
              let bytes = try? Data(contentsOf: url),
              let contract = try? JSONDecoder().decode(Contract.self, from: bytes),
              contract.version == 1, contract.maximum_input_bytes == 4096,
              contract.maximum_marker_bytes == 512 else { return nil }
        return contract
    }()

    private static let patterns: [NSRegularExpression]? = {
        guard let contract else { return nil }
        do { return try contract.plain_patterns.map { try NSRegularExpression(pattern: $0) } }
        catch { return nil }
    }()

    static func project(_ message: String) -> String? {
        guard let contract, let patterns,
              message.utf8.prefix(contract.maximum_input_bytes + 1).count <= contract.maximum_input_bytes,
              !message.contains("\n"), !message.contains("\r") else { return nil }
        if let tag = message.range(of: "[E2EE_JOIN]") {
            return projectJoin(String(message[tag.upperBound...]), contract: contract)
        }
        for pattern in patterns {
            if let match = pattern.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
               let range = Range(match.range, in: message) {
                let marker = String(message[range])
                return marker.utf8.count <= contract.maximum_marker_bytes ? marker : nil
            }
        }
        return nil
    }

    private static func projectJoin(_ tail: String, contract: Contract) -> String? {
        var fields: [String: String] = [:]
        for token in tail.split(whereSeparator: { $0.isWhitespace }) {
            let pair = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            let key = String(pair[0])
            guard key.allSatisfy({ $0.isASCII && ($0.isLowercase || $0 == "_") }) else { continue }
            guard fields[key] == nil else { return nil }
            fields[key] = String(pair[1])
        }
        guard let stage = fields["stage"], contract.join_stages.contains(stage),
              let source = fields["source"], contract.join_sources.contains(source) else { return nil }
        var result = "join_checkpoint stage=\(stage) source=\(source)"
        for field in contract.join_fields {
            if let value = fields[field.name], field.values.contains(value) {
                result += " \(field.name)=\(value)"
            }
        }
        return result.utf8.count <= contract.maximum_marker_bytes ? result : nil
    }

    static func isCanonical(_ marker: String) -> Bool {
        if marker.hasPrefix("join_checkpoint "), let contract {
            return projectJoin(String(marker.dropFirst("join_checkpoint ".count)), contract: contract) == marker
        }
        return project(marker) == marker
    }
}

final class MlsFieldLogWriter {
    enum Failure: Error { case invalidDirectory, invalidMarker, invalidFile, invalidLimit }
    static let maximumFileBytes = 256 * 1024
    private let directoryURL: URL
    private let maximumBytes: Int
    // LogConfig invalidation can briefly retain old and new destination instances.
    // Serialize file operations across them as well as concurrent caller threads.
    private static let ioLock = NSLock()
    private let formatter = ISO8601DateFormatter()

    init(directoryURL: URL, maximumBytes: Int = maximumFileBytes) throws {
        guard directoryURL.isFileURL else { throw Failure.invalidDirectory }
        guard (512...Self.maximumFileBytes).contains(maximumBytes) else { throw Failure.invalidLimit }
        self.directoryURL = directoryURL
        self.maximumBytes = maximumBytes
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        var excludedDirectory = directoryURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excludedDirectory.setResourceValues(values)
    }

    func append(marker: String, date: Date) throws {
        guard MlsFieldMarkerProjector.isCanonical(marker) else { throw Failure.invalidMarker }
        Self.ioLock.lock()
        defer { Self.ioLock.unlock() }
        let bytes = Data("\(formatter.string(from: date)) \(marker)\n".utf8)
        guard bytes.count <= maximumBytes else { throw Failure.invalidLimit }
        let manager = FileManager.default
        let current = directoryURL.appendingPathComponent("current.log")
        let previous = directoryURL.appendingPathComponent("previous.log")
        if manager.fileExists(atPath: current.path) {
            let attributes = try manager.attributesOfItem(atPath: current.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber else { throw Failure.invalidFile }
            if size.intValue + bytes.count > maximumBytes {
                if manager.fileExists(atPath: previous.path) { try manager.removeItem(at: previous) }
                // An oversized/corrupt preexisting diagnostic file is discarded, never exported as proof.
                if size.intValue > maximumBytes { try manager.removeItem(at: current) }
                else { try manager.moveItem(at: current, to: previous) }
            }
        }
        if !manager.fileExists(atPath: current.path) {
            var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
            #if os(iOS)
            attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
            #endif
            guard manager.createFile(atPath: current.path, contents: nil, attributes: attributes) else {
                throw Failure.invalidFile
            }
        }
        let handle = try FileHandle(forWritingTo: current)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: bytes)
    }
}
