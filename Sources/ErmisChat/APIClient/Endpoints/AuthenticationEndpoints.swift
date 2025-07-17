//
// Copyright 2025 Ermis Inc.
//

import Foundation

extension Endpoint {
    /// Create the endpoint login with email address.
    ///
    /// - Parameters:
    ///   - email: The email address of account.
    ///   - password: The password of account .
    ///   - apiKey: Current project apiKey.
    /// - Returns: The endpoint for login with email address.
    static func loginWithEmail(email: String, password: String, apiKey: String) -> Endpoint<AuthenticationPayload> {
        .init(
            path: .getOtp,
            method: .post,
            query: nil,
            body: LoginRequestBody(email: email, password: password, apiKey: apiKey),
            needToken: false,
            isAuth: true
        )
    }

    /// Create the endpoint login with email address.
    ///
    /// - Parameters:
    ///   - email: The email address of account.
    ///   - password: The password of account .
    ///   - apiKey: Current project apiKey.
    /// - Returns: The endpoint for login with email address.
    static func loginWithOTP(email: String, password: String, apiKey: String) -> Endpoint<AuthenticationPayload> {
        .init(
            path: .getOtp,
            method: .post,
            query: nil,
            body: LoginRequestBody(email: email, password: password, apiKey: apiKey),
            needToken: false,
            isAuth: true
        )
    }

    /// Create the endpoint for register new account with email address.
    ///
    /// - Parameters:
    ///   - email: The email address of account.
    ///   - password: The password of account .
    ///   - apiKey: Current project apiKey.
    /// - Returns: The endpoint for register new account with email address.
    static func register(email: String, password: String, apiKey: String) -> Endpoint<EmptyResponse> {
        .init(
            path: .register,
            method: .post,
            query: nil,
            body: RegisterRequestBody(email: email, password: password, apiKey: apiKey),
            needToken: false,
            isAuth: true
        )
    }

    /// Create the endpoint to send otp to a phone number.
    ///
    /// - Parameters:
    ///   - body: The `GetOtpRequestBody` instance.
    /// - Returns: The endpoint for send otp to a phone number.
    static func getOTP(body: GetOtpRequestBody) -> Endpoint<EmptyResponse> {
        .init(
            path: .getOtp,
            method: .post,
            query: nil,
            body: body,
            needToken: false,
            isAuth: true
        )
    }

    /// Create the endpoint to login with phone number.
    ///
    /// - Parameters:
    ///   - phoneNumber: The phone number to sign in.
    ///   - otp: The otp code send to phone number.
    ///   - apiKey: Apikey of current project.
    /// - Returns: The endpoint for login with phone number.
    static func loginWithOTP(body: OtpRequestBody) -> Endpoint<AuthenticationPayload> {
        .init(
            path: .loginWithOTP,
            method: .post,
            query: nil,
            body: body,
            needToken: false,
            isAuth: true
        )
    }

    /// Create the endpoint to login with phone number.
    ///
    /// - Parameters:
    ///   - token: The google id token.
    ///   - apiKey: Apikey of current project.
    /// - Returns: The endpoint for login with phone number.
    static func loginWithApple(token: String, apiKey: String) -> Endpoint<AuthenticationPayload> {
        .init(
            path: .loginWithApple,
            method: .post,
            query: nil,
            body: [
                "token": token,
                "apikey": apiKey
            ],
            needToken: false,
            isAuth: true
        )
    }

    /// Create the endpoint to login with phone number.
    ///
    /// - Parameters:
    ///   - token: The google id token.
    ///   - apiKey: Apikey of current project.
    /// - Returns: The endpoint for login with phone number.
    static func loginWithGoogle(token: String, apiKey: String) -> Endpoint<AuthenticationPayload> {
        .init(
            path: .loginWithGoogle,
            method: .post,
            query: nil,
            body: [
                "token": token,
                "apikey": apiKey
            ],
            needToken: false,
            isAuth: true
        )
    }

    /// Create the endpoint to refresh access token.
    ///
    /// - Parameters:
    ///   - token: Current token.
    ///   - refresToken: Current refresh token.
    /// - Returns: The endpoint to refresh access token.
    static func refreshToken(_ token: Token, refresToken: String) -> Endpoint<AuthenticationPayload> {
        let param = [
            "refresh_token": refresToken
        ]
        return .init(path: .refreshToken(token),
                     method: .post,
                     body: param,
                     needToken: false,
                     isAuth: true
        )
    }
}
