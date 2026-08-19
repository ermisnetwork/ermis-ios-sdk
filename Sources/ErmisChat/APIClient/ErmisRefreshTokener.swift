//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// The object support refresh token.
public class ErmisRefreshTokenHelper {
    private let stateQueue = DispatchQueue(label: "network.ermis.refresh-token-helper")
    private var storedToken: Token
    private var storedRefreshToken: String?
    private var didConsumeInitialToken = false

    var token: Token {
        stateQueue.sync { storedToken }
    }

    var refreshToken: String? {
        stateQueue.sync { storedRefreshToken }
    }
    var onAuthorizationChanged: ((AuthenticationPayload) -> Void)?
    var onRefreshTokenExpired: (() -> Void)?

    public init(token: Token,
         refreshToken: String? = nil,
         onAuthorizationChanged: ((AuthenticationPayload) -> Void)? = nil,
         onRefreshTokenExpired: (() -> Void)? = nil) {
        storedToken = token
        storedRefreshToken = refreshToken
        self.onAuthorizationChanged = onAuthorizationChanged
        self.onRefreshTokenExpired = onRefreshTokenExpired
    }

    /// Uses the host-provided token once for initial connection. A later provider invocation means
    /// the server rejected that token, so returning the same JWT again would loop forever.
    func consumeInitialTokenIfValid() -> Token? {
        stateQueue.sync {
            guard !didConsumeInitialToken else { return nil }
            didConsumeInitialToken = true
            return storedToken.isExpired ? nil : storedToken
        }
    }

    func update(token: Token, refreshToken: String?) {
        stateQueue.sync {
            storedToken = token
            if let refreshToken {
                storedRefreshToken = refreshToken
            }
        }
    }
}
