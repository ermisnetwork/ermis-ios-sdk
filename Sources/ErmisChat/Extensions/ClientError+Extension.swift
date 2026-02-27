//
// Copyright 2025 Ermis Inc.
//

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
