import Foundation
import CryptoKit

/// Closed metadata for field diagnosis. Never logs URLs, headers or error text.
enum MlsTransportTrace {
    /// Diagnostics only. Source location is hashed; no user/account/provider data.
    final class DatabaseWrite {
        enum Stage: String { case queued, admitted, modified, saved, failed }
        private let operation = UUID().uuidString.lowercased()
        private let source: String
        private let line: UInt
        private let lane: String
        private let start = DispatchTime.now().uptimeNanoseconds

        init(file: StaticString, line: UInt, synchronous: Bool) {
            source = SHA256.hash(data: Data(String(describing: file).utf8))
                .map { String(format: "%02x", $0) }.joined()
            self.line = min(line, 999999)
            lane = synchronous ? "sync" : "async"
            record(.queued)
        }

        func record(_ stage: Stage) {
            let elapsed = min((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000, 999999999)
            log.info("mls_database stage=\(stage.rawValue) operation_id=\(operation) source_sha256=\(source) line=\(line) lane=\(lane) elapsed_ms=\(elapsed)", subsystems: .mls)
        }
    }
    enum Stage: String {
        case connecting, waiting, connected, disconnecting, disconnected, initialized
        case engineStart = "engine_start", engineOpen = "engine_open", engineStop = "engine_stop"
        case readArmed = "read_armed", readFailed = "read_failed", wireReceived = "wire_received"
        case engineClosed = "engine_closed", engineCompleted = "engine_completed"
        case ping, pong, pingFailed = "ping_failed", pongTimeout = "pong_timeout"
        case decoded, decodeFailed = "decode_failed", ignored
        case batchQueued = "batch_queued", batchFinished = "batch_finished", batchPosted = "batch_posted"
    }

    static func record(_ stage: Stage, operation: UUID, count: Int = 0, code: Int = 0) {
        log.info("mls_transport stage=\(stage.rawValue) operation_id=\(operation.uuidString.lowercased()) count=\(min(max(count, 0), 999999999)) code=\(min(max(code, -999999), 999999))", subsystems: .mls)
    }

    static func message(_ event: Event, stage: MlsIncomingTrace.Stage) {
        let message = (event as? MessageNewEventDTO)?.message ?? (event as? NotificationMessageNewEventDTO)?.message
        guard let message, let encrypted = message.encryptedData else { return }
        MlsIncomingTrace.record(stage, uuid: message.id, ciphertext: Data(encrypted))
    }
}
