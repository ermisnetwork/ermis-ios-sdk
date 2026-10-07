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
    private var refreshCompletions: [(Result<Token, Error>) -> Void] = []
    private var refreshInFlight = false
    private var revision = 0
    private var refreshCycle = 0
    private var refreshResponseClaimed = false

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
            revision += 1
            storedToken = token
            if let refreshToken {
                storedRefreshToken = refreshToken
            }
        }
    }

    /// One HTTP refresh per active helper. Callbacks run outside the state queue.
    func loadRefreshedToken(
        request: (Token, String, @escaping (Result<AuthenticationPayload, Error>) -> Void) -> Void,
        completion: @escaping (Result<Token, Error>) -> Void
    ) {
        let snapshot: (Token, String, Int, Int)? = stateQueue.sync {
            refreshCompletions.append(completion)
            guard !refreshInFlight else { return nil }
            refreshInFlight = true
            refreshCycle += 1
            refreshResponseClaimed = false
            return (storedToken, storedRefreshToken ?? "", revision, refreshCycle)
        }
        guard let (previous, refresh, expectedRevision, cycle) = snapshot else { return }
        let finish: (Result<AuthenticationPayload, Error>) -> Void = { response in
            // A duplicate/late network completion must not drain a later flight.
            let ownsResponse = self.stateQueue.sync { () -> Bool in
                guard self.refreshInFlight, self.refreshCycle == cycle,
                      !self.refreshResponseClaimed else { return false }
                self.refreshResponseClaimed = true
                return true
            }
            guard ownsResponse else { return }
            var acceptedPayload: AuthenticationPayload?
            let result: Result<Token, Error> = response.flatMap { payload in
                Result { try payload.validatedToken(matching: previous) }
            }
            let delivery: Result<Token, Error> = self.stateQueue.sync {
                var finalResult = result
                if self.revision != expectedRevision {
                    finalResult = .failure(ClientError.InvalidToken("The saved session changed during renewal."))
                } else if case let .success(token) = result, case let .success(payload) = response {
                    self.storedToken = token
                    if let rotated = payload.refreshToken, !rotated.isEmpty { self.storedRefreshToken = rotated }
                    self.revision += 1
                    acceptedPayload = payload
                }
                return finalResult
            }
            if let acceptedPayload { self.onAuthorizationChanged?(acceptedPayload) }
            let callbacks = self.stateQueue.sync {
                let callbacks = self.refreshCompletions
                self.refreshCompletions = []
                self.refreshInFlight = false
                return callbacks
            }
            callbacks.forEach { $0(delivery) }
        }
        guard !refresh.isEmpty else { finish(.failure(ClientError.MissingRefreshToken())); return }
        request(previous, refresh, finish)
    }
}
