//
// Copyright 2026 Ermis Inc.
//

import Foundation

enum E2eeAttachmentRemoteErrorCategory: String, Sendable {
    case networkUnavailable
    case serviceTemporarilyUnavailable
    case attachmentBusy
    case retryConflict
    case attachmentTooLarge
    case invalidAttachment
    case attachmentAlreadyBound
    case multipartRequired
    case permissionDenied
    case unknown
}

struct E2eeAttachmentRemoteError: Error, Equatable, Sendable {
    let category: E2eeAttachmentRemoteErrorCategory
    let isRetryable: Bool

    var publicFailureReason: E2eeTransferFailureReason {
        switch category {
        case .networkUnavailable:
            return .networkUnavailable
        case .serviceTemporarilyUnavailable, .attachmentBusy, .retryConflict:
            return .serviceTemporarilyUnavailable
        case .attachmentTooLarge:
            return .attachmentTooLarge
        case .attachmentAlreadyBound:
            return .attachmentAlreadyBound
        case .multipartRequired:
            return .multipartUnavailable
        case .permissionDenied:
            return .permissionDenied
        case .invalidAttachment, .unknown:
            return .invalidServerResponse
        }
    }

    static func classify(_ error: Error) -> Self {
        if let urlError = unwrap(error) as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
                 .cannotFindHost, .dnsLookupFailed, .timedOut:
                return .init(category: .networkUnavailable, isRetryable: true)
            default:
                return .init(category: .unknown, isRetryable: false)
            }
        }

        guard let apiError = unwrap(error) as? ErmisApiError else {
            return .init(category: .unknown, isRetryable: false)
        }
        let message = apiError.message.lowercased()
        let knownCodes: [(String, E2eeAttachmentRemoteErrorCategory, Bool)] = [
            ("e2ee_attachment_busy", .attachmentBusy, true),
            ("e2ee_attachment_retry_conflict", .retryConflict, true),
            ("e2ee_attachment_too_large", .attachmentTooLarge, false),
            ("e2ee_attachment_bound", .attachmentAlreadyBound, false),
            ("e2ee_attachment_multipart_required", .multipartRequired, false),
            ("e2ee_attachment_invalid", .invalidAttachment, false),
        ]
        if let known = knownCodes.first(where: { message.contains($0.0) }) {
            return .init(category: known.1, isRetryable: known.2)
        }
        if apiError.httpStatusCode == 401 || apiError.httpStatusCode == 403 {
            return .init(category: .permissionDenied, isRetryable: false)
        }
        if apiError.httpStatusCode == 408 || apiError.httpStatusCode == 429
            || (500...599).contains(apiError.httpStatusCode) {
            return .init(category: .serviceTemporarilyUnavailable, isRetryable: true)
        }
        return .init(category: .unknown, isRetryable: false)
    }

    private static func unwrap(_ error: Error) -> Error {
        (error as? ClientError)?.underlyingError ?? error
    }
}
