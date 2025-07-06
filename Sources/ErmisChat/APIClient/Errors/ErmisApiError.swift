//
// Copyright 2025 Ermis Inc.
//

import Foundation

public
enum ErmisErrorType {
    case internalServerError
    case serviceUnavailable
    case unAuthorized
    case apiNotFound
    case inputNotCorrect
    case channelNotFound
    case noPermission
    case notAMemberOfChannel
    case bannedFromChannel
    case needAcceptInvite
    case dontHaveCapability
    case alreadyIsMember
    case needOnline
    case needWaitForMessageCoolDown
    case needUnblockFirst
    case alreadyBlocked
    case alreadyUnblocked
    case messageContainUnallowedContent
    case callInprogress
    case callNotInProgress
    case otherCallInProgress
    case unknown

    var code: Int {
        switch self {
        case .internalServerError:
            return 0
        case .serviceUnavailable:
            return 1
        case .unAuthorized:
            return 2
        case .apiNotFound:
            return 3
        case .inputNotCorrect:
            return 4
        case .channelNotFound:
            return 5
        case .noPermission:
            return 6
        case .notAMemberOfChannel:
            return 7
        case .bannedFromChannel:
            return 8
        case .needAcceptInvite:
            return 9
        case .dontHaveCapability:
            return 10
        case .alreadyIsMember:
            return 11
        case .needOnline:
            return 12
        case .needWaitForMessageCoolDown:
            return 13
        case .needUnblockFirst:
            return 14
        case .alreadyBlocked:
            return 15
        case .alreadyUnblocked:
            return 16
        case .messageContainUnallowedContent:
            return 17
        case .callInprogress:
            return 18
        case .callNotInProgress:
            return 19
        case .otherCallInProgress:
            return 20
        case .unknown:
            return 999
        }
    }

    init(code: Int) {
        switch code {
        case 0:
            self = .internalServerError
        case 1:
            self = .serviceUnavailable
        case 2:
            self = .unAuthorized
        case 3:
            self = .apiNotFound
        case 4:
            self = .inputNotCorrect
        case 5:
            self = .channelNotFound
        case 6:
            self = .noPermission
        case 7:
            self = .notAMemberOfChannel
        case 8:
            self = .bannedFromChannel
        case 9:
            self = . needAcceptInvite
        case 10:
            self = .dontHaveCapability
        case 11:
            self = .alreadyIsMember
        case 12:
            self = .needOnline
        case 13:
            self = .needWaitForMessageCoolDown
        case 14:
            self = .needUnblockFirst
        case 15:
            self = .alreadyBlocked
        case 16:
            self = .alreadyUnblocked
        case 17:
            self = .messageContainUnallowedContent
        case 18:
            self = .callInprogress
        case 19:
            self = .callNotInProgress
        case 20:
            self = .otherCallInProgress
        default:
            self = .unknown
        }
    }
}

public
struct ErmisApiError: Error {
    public let type: ErmisErrorType
    public let code: Int
    public let httpStatusCode: Int
    public let message: String
    public let channelConditions: [ChannelConditionPayload]?

    init(payload: ErmisErrorPayload, httpStatusCode: Int) {
        self.type = ErmisErrorType(code: payload.ermisCode)
        self.code = payload.ermisCode
        self.httpStatusCode = httpStatusCode
        self.message = payload.message
        self.channelConditions = payload.channelCondtions
    }

    init(type: ErmisErrorType, statusCode: Int, message: String) {
        self.type = type
        self.code = type.code
        self.httpStatusCode = statusCode
        self.message = message
        self.channelConditions = nil
    }

    var ermisErrorPayload: ErmisErrorPayload {
        return .init(ermisCode: code, message: message)
    }
}

extension ErmisApiError {
    /// Returns `true` if the code determines that the token is expired.
    var isExpiredTokenError: Bool {
        httpStatusCode == 401
    }

    /// Returns `true` if code is within invalid token codes range.
    var isInvalidTokenError: Bool {
        httpStatusCode == 401 // Ermis token expired
    }

    /// Returns `true` if status code is within client error codes range.
    var isClientError: Bool {
        return ClosedRange.clientErrorCodes ~= httpStatusCode
    }
}

extension ClosedRange where Bound == Int {
    /// The range of HTTP request status codes for client errors.
    static let clientErrorCodes: Self = 400...499
}
