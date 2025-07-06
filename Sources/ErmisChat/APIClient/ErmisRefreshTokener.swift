//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// The object support refresh token.
public class ErmisRefreshTokenHelper {
    var token: Token
    var refreshToken: String?
    var onAuthorizationChanged: ((AuthenticationPayload) -> Void)?
    var onRefreshTokenExpired: (() -> Void)?

    public init(token: Token,
         refreshToken: String? = nil,
         onAuthorizationChanged: ((AuthenticationPayload) -> Void)? = nil,
         onRefreshTokenExpired: (() -> Void)? = nil) {
        self.token = token
        self.refreshToken = refreshToken
        self.onAuthorizationChanged = onAuthorizationChanged
        self.onRefreshTokenExpired = onRefreshTokenExpired
    }
}
