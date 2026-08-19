//
// Copyright 2026 Ermis Inc.
//

import Foundation

public enum E2eeTransferPhase: String, Codable, CaseIterable, Sendable {
    case preparing
    case encrypting
    case uploading
    case waitingForSystem
    case reconciling
    case finalizing
    case waitingForUnlock
    case sending
    case failedRetryable
    case failedTerminal
    case canceled
    case confirmed
}

/// Stable categories suitable for UI and telemetry. Raw URLSession, Keychain, URLs, keys, and
/// opaque background-task tokens never cross the public API boundary.
public enum E2eeTransferFailureReason: String, Codable, Sendable {
    case networkUnavailable
    case serviceTemporarilyUnavailable
    case uploadExpired
    case backgroundTaskMissing
    case insufficientDiskSpace
    case waitingForUnlock
    case localKeyUnavailableAfterReinstall
    case integrityFailure
    case invalidServerResponse
    case attachmentTooLarge
    case attachmentAlreadyBound
    case permissionDenied
    case multipartUnavailable
    case sourceUnavailable
    case canceledByUser
    case unknown
}

public struct E2eeTransferProgress: Equatable, Sendable {
    public let phase: E2eeTransferPhase
    public let completedBytes: Int64
    public let totalBytes: Int64
    public let failureReason: E2eeTransferFailureReason?
    public let hasUnscheduledParts: Bool

    public var fractionCompleted: Double {
        guard totalBytes > 0 else { return phase == .confirmed ? 1 : 0 }
        return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
    }

    /// Sending every request-body byte is not the attachment success boundary. Keep UI progress
    /// below 100% until Bellboy completes the attachment and confirms the message send.
    var presentationFractionCompleted: Double {
        phase == .confirmed ? 1 : min(fractionCompleted, 0.99)
    }

    public init(
        phase: E2eeTransferPhase,
        completedBytes: Int64,
        totalBytes: Int64,
        failureReason: E2eeTransferFailureReason? = nil,
        hasUnscheduledParts: Bool = false
    ) {
        self.phase = phase
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.failureReason = failureReason
        self.hasUnscheduledParts = hasUnscheduledParts
    }
}

enum E2eeTransferUploadMode: String, Codable, Sendable {
    case singlePut = "single_put"
    case multipart

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        switch try container.decode(String.self) {
        case Self.singlePut.rawValue, "singlePut":
            self = .singlePut
        case Self.multipart.rawValue:
            self = .multipart
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported E2EE attachment upload mode"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct PendingE2eeMultipartPart: Codable, Equatable, Sendable {
    let number: Int
    let offset: UInt64
    let size: UInt64
    var putURL: URL? = nil
    var completedBytes: Int64? = nil
    var eTag: String?
    var taskIdentifier: Int?
    var taskToken: String?
    var localFileURL: URL?

    var isUploaded: Bool {
        eTag != nil
    }
}

struct PendingE2eeAsset: Codable, Equatable, Sendable {
    var attachmentId: String
    var assetId: String
    let kind: E2eeAttachmentAssetKind
    /// Stable client-generated key for retrying the logical attachment init. Original and
    /// preview assets belonging to the same attachment carry the same value.
    var idempotencyKey: String? = nil
    var sourceURL: URL?
    var canonicalCiphertextURL: URL?
    var ciphertextSize: UInt64?
    var ciphertextSha256: String?
    var sealedSecret: E2eeSealedAttachmentSecret?
    var frameSize: UInt32? = nil
    var plaintextSize: UInt64? = nil
    var plaintextSha256: String? = nil
    var display: [String: RawJSON]? = nil
    var uploadMode: E2eeTransferUploadMode?
    var uploadExpiresAt: Date?
    var putURL: URL? = nil
    var objectKey: String? = nil
    var multipartUploadId: String? = nil
    var multipartPartSize: UInt64? = nil
    var maxPartRetries: Int? = nil
    var retryMaxElapsedSeconds: Int? = nil
    var completedBytes: Int64? = nil
    var taskIdentifier: Int?
    var taskToken: String?
    var isUploaded: Bool = false
    var parts: [PendingE2eeMultipartPart]
}

/// Exact, durable service-completion intent. The lease and opaque multipart ETags are generated
/// once and reused byte-for-byte after a timeout or unknown HTTP result.
struct PendingE2eeAttachmentCompletionIntent: Codable, Equatable, Sendable {
    let attachmentId: String
    let request: CompleteE2eeAttachmentRequest
    var isServiceCompleted: Bool
}

struct PendingE2eeTransferAttempt: Codable, Equatable, Sendable {
    static let version = 1

    let version: Int
    let attemptId: String
    let taskToken: String
    let accountId: String
    let messageId: String
    let cid: String
    var phase: E2eeTransferPhase
    var completedBytes: Int64
    var totalBytes: Int64
    var failureReason: E2eeTransferFailureReason?
    var assets: [PendingE2eeAsset]
    var completionIntents: [PendingE2eeAttachmentCompletionIntent]?
    let createdAt: Date
    var updatedAt: Date

    init(
        attemptId: String = UUID().uuidString,
        taskToken: String = UUID().uuidString,
        accountId: String,
        messageId: String,
        cid: String,
        phase: E2eeTransferPhase = .preparing,
        completedBytes: Int64 = 0,
        totalBytes: Int64 = 0,
        assets: [PendingE2eeAsset] = [],
        now: Date = Date()
    ) {
        version = Self.version
        self.attemptId = attemptId
        self.taskToken = taskToken
        self.accountId = accountId
        self.messageId = messageId
        self.cid = cid
        self.phase = phase
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        failureReason = nil
        self.assets = assets
        completionIntents = nil
        createdAt = now
        updatedAt = now
    }

    public var hasUnscheduledParts: Bool {
        assets.contains { asset in
            asset.uploadMode == .multipart && asset.parts.contains { part in
                part.eTag == nil && part.taskToken == nil
            }
        }
    }

    var publicProgress: E2eeTransferProgress {
        E2eeTransferProgress(
            phase: phase,
            completedBytes: completedBytes,
            totalBytes: totalBytes,
            failureReason: failureReason,
            hasUnscheduledParts: hasUnscheduledParts
        )
    }
}

enum E2eeTransferStateError: Error, Equatable {
    case invalidVersion(Int)
    case invalidAttemptId
    case invalidTaskToken
    case invalidByteCounts
    case invalidTransition(from: E2eeTransferPhase, to: E2eeTransferPhase)
    case progressRegression
    case failureReasonMismatch
    case identityMutation
    case invalidMultipartParts

    var diagnosticCode: String {
        switch self {
        case .invalidVersion:
            return "invalid_version"
        case .invalidAttemptId:
            return "invalid_attempt_id"
        case .invalidTaskToken:
            return "invalid_task_token"
        case .invalidByteCounts:
            return "invalid_byte_counts"
        case let .invalidTransition(from, to):
            return "invalid_transition_\(from.rawValue)_to_\(to.rawValue)"
        case .progressRegression:
            return "progress_regression"
        case .failureReasonMismatch:
            return "failure_reason_mismatch"
        case .identityMutation:
            return "identity_mutation"
        case .invalidMultipartParts:
            return "invalid_multipart_parts"
        }
    }
}

func e2eeTransferDiagnostic(_ error: Error) -> String {
    (error as? E2eeTransferStateError)?.diagnosticCode
        ?? String(describing: type(of: error))
}

extension PendingE2eeTransferAttempt {
    func validate() throws {
        guard version == Self.version else { throw E2eeTransferStateError.invalidVersion(version) }
        guard UUID(uuidString: attemptId) != nil else { throw E2eeTransferStateError.invalidAttemptId }
        guard UUID(uuidString: taskToken) != nil else { throw E2eeTransferStateError.invalidTaskToken }
        guard completedBytes >= 0, totalBytes >= 0, completedBytes <= totalBytes || totalBytes == 0 else {
            throw E2eeTransferStateError.invalidByteCounts
        }
        let isFailure = phase == .failedRetryable || phase == .failedTerminal
        guard isFailure == (failureReason != nil) else {
            throw E2eeTransferStateError.failureReasonMismatch
        }
        var tokens = Set<String>()
        for token in [taskToken] + assets.flatMap({ asset in
            [asset.taskToken].compactMap { $0 } + asset.parts.compactMap(\.taskToken)
        }) {
            guard UUID(uuidString: token) != nil, tokens.insert(token).inserted else {
                throw E2eeTransferStateError.invalidTaskToken
            }
        }
        for asset in assets {
            let assetCompletedBytes = asset.completedBytes ?? 0
            guard assetCompletedBytes >= 0,
                  UInt64(assetCompletedBytes) <= (asset.ciphertextSize ?? 0) else {
                throw E2eeTransferStateError.invalidByteCounts
            }
            try Self.validateMultipartParts(asset)
        }
        try validateCompletionIntents()
    }

    func validateUpdate(from previous: Self) throws {
        try validate()
        guard attemptId == previous.attemptId,
              taskToken == previous.taskToken,
              accountId == previous.accountId,
              messageId == previous.messageId,
              cid == previous.cid,
              createdAt == previous.createdAt else {
            throw E2eeTransferStateError.identityMutation
        }
        guard completedBytes >= previous.completedBytes else {
            throw E2eeTransferStateError.progressRegression
        }
        guard Self.allowedTransitions[previous.phase, default: []].contains(phase)
            || previous.phase == phase else {
            throw E2eeTransferStateError.invalidTransition(from: previous.phase, to: phase)
        }
    }

    private static let allowedTransitions: [E2eeTransferPhase: Set<E2eeTransferPhase>] = [
        .preparing: [.encrypting, .waitingForUnlock, .failedRetryable, .failedTerminal, .canceled],
        .encrypting: [.uploading, .waitingForUnlock, .failedRetryable, .failedTerminal, .canceled],
        .uploading: [.waitingForSystem, .reconciling, .finalizing, .failedRetryable, .failedTerminal, .canceled],
        // A background URLSession removes a task as soon as its completion callback is
        // delivered. When the final asset callback is drained, transport is authoritative and
        // the attempt advances directly from waiting to Bellboy `/complete` finalization.
        .waitingForSystem: [.reconciling, .uploading, .finalizing, .failedRetryable, .failedTerminal, .canceled],
        .reconciling: [.uploading, .waitingForSystem, .finalizing, .failedRetryable, .failedTerminal, .canceled],
        .finalizing: [.sending, .waitingForUnlock, .failedRetryable, .failedTerminal, .canceled],
        .waitingForUnlock: [.preparing, .encrypting, .finalizing, .failedRetryable, .failedTerminal, .canceled],
        .sending: [.confirmed, .failedRetryable, .failedTerminal, .canceled],
        // A service `complete` timeout retries the same durable lease/ETag intent. Upload expiry
        // still creates a fresh attempt, but the state machine must permit the former recovery.
        // A URLSession task can disappear from `getAllTasks()` immediately before its durable
        // completion callback is drained. The exact matching callback is allowed to revive only
        // that transport attempt; callers still cannot create a new ciphertext/network intent.
        // A later durable callback can provide authoritative terminal evidence (for example a
        // non-retryable HTTP response) after an earlier missing-task/network classification.
        // Without this edge, that callback remains in the journal and poisons every reconcile.
        .failedRetryable: [.uploading, .finalizing, .failedTerminal, .canceled],
        .failedTerminal: [.canceled],
        .canceled: [],
        .confirmed: []
    ]

    private static func validateMultipartParts(_ asset: PendingE2eeAsset) throws {
        guard !asset.parts.isEmpty else { return }
        guard asset.uploadMode == .multipart,
              let cipherSize = asset.ciphertextSize,
              let configuredPartSize = asset.multipartPartSize,
              configuredPartSize > 0,
              asset.parts.count <= 256,
              asset.parts.map(\.number) == Array(1...asset.parts.count) else {
            throw E2eeTransferStateError.invalidMultipartParts
        }

        var expectedOffset: UInt64 = 0
        for (index, part) in asset.parts.enumerated() {
            let isLast = index == asset.parts.count - 1
            guard part.offset == expectedOffset,
                  part.size > 0,
                  part.size <= configuredPartSize,
                  isLast || part.size == configuredPartSize,
                  (part.completedBytes ?? 0) >= 0,
                  UInt64(part.completedBytes ?? 0) <= part.size,
                  part.putURL?.scheme?.lowercased() == "https",
                  part.putURL?.host?.isEmpty == false else {
                throw E2eeTransferStateError.invalidMultipartParts
            }
            let (nextOffset, overflow) = expectedOffset.addingReportingOverflow(part.size)
            guard !overflow else { throw E2eeTransferStateError.invalidMultipartParts }
            expectedOffset = nextOffset
        }
        guard expectedOffset == cipherSize else {
            throw E2eeTransferStateError.invalidMultipartParts
        }
    }

    private func validateCompletionIntents() throws {
        guard let completionIntents else { return }
        let attachmentIds = Set(assets.map(\.attachmentId))
        guard !completionIntents.isEmpty,
              completionIntents.count == attachmentIds.count,
              Set(completionIntents.map(\.attachmentId)) == attachmentIds else {
            throw E2eeTransferStateError.invalidMultipartParts
        }
        for intent in completionIntents {
            guard UUID(uuidString: intent.attachmentId) != nil else {
                throw E2eeTransferStateError.invalidMultipartParts
            }
            do {
                try intent.request.validate()
            } catch {
                throw E2eeTransferStateError.invalidMultipartParts
            }
        }
    }
}
