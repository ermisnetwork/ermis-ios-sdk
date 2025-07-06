//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// A Client error.
open class ClientError: Error, CustomStringConvertible {
    public struct Location: Equatable {
        public let file: String
        public let line: Int
    }

    public let location: Location?

    public let message: String?

    /// An underlying `Error`.
    public let underlyingError: Error?

    public var errorDescription: String? {
        if let ermisApiError {
            return ermisApiError.message
        }
        return underlyingError.map(String.init(describing:))
    }

    /// The ermis api error if the underlying error comes from a server error.
    public var ermisApiError: ErmisApiError? { underlyingError as? ErmisApiError }

    /// Retrieve the localized description for this error.
    public var localizedDescription: String {
        errorDescription ?? message ?? ""
    }

    public private(set) lazy var description = "Error \(type(of: self)) in \(location?.file ?? ""):\(location?.line ?? 0)"
        + (localizedDescription.isEmpty ? "" : " -> ")
        + localizedDescription

    /// A client error based on an external general error.
    /// - Parameters:
    ///   - error: an external error.
    ///   - file: a file name source of an error.
    ///   - line: a line source of an error.
    public init(with error: Error? = nil, _ file: StaticString = #file, _ line: UInt = #line) {
        message = nil
        underlyingError = error
        location = .init(file: "\(file)", line: Int(line))
    }

    /// An error based on a message.
    /// - Parameters:
    ///   - message: an error message.
    ///   - file: a file name source of an error.
    ///   - line: a line source of an error.
    public init(_ message: String, _ file: StaticString = #file, _ line: UInt = #line) {
        self.message = message
        location = .init(file: "\(file)", line: Int(line))
        underlyingError = nil
    }
}

extension ClientError {
    /// An unexpected error.
    public class Unexpected: ClientError {}

    /// An unknown error.
    public class Unknown: ClientError {}
}

// This should probably live only in the test target since it's not "true" equatable
extension ClientError: Equatable {
    public static func == (lhs: ClientError, rhs: ClientError) -> Bool {
        type(of: lhs) == type(of: rhs)
            && String(describing: lhs.underlyingError) == String(describing: rhs.underlyingError)
            && String(describing: lhs.localizedDescription) == String(describing: rhs.localizedDescription)
    }
}

extension ClientError {
    /// Returns `true` the ermis code determines that the token is expired.
    var isExpiredTokenError: Bool {
        (underlyingError as? ErmisApiError)?.isExpiredTokenError == true ||
        (underlyingError as? WebSocketEngineError)?.code == 1005
    }

    /// Returns `true` if underlaying error is `ErrorPayload` with code is inside invalid token codes range.
    var isInvalidTokenError: Bool {
        (underlyingError as? ErmisApiError)?.isInvalidTokenError == true ||
        (underlyingError as? WebSocketEngineError)?.code == 1005

    }
}
