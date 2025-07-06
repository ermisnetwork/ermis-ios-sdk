//
// Copyright 2025 Ermis Inc.
//

import Foundation

extension Endpoint {
    /// Create the endpoint to get user list by user list query.
    ///
    /// - Parameters:
    ///   - query: The `UserListQuery` instance to fetch user list.
    /// - Returns: The endpoint to get user list.
    static func users(query: UserListQuery)
        -> Endpoint<UserListPayload> {
        .init(
            path: .usersSearch,
            method: .post,
            query: query        )
    }

    /// Create the endpoint to get user list from idetifier list.
    ///
    /// - Parameters:
    ///   - ids: List of user identifier.
    ///   - projectId: The project identifier.
    /// - Returns: The endpoint to get user list.
    static func users(with ids: [String], projectId: String) -> Endpoint<UserListPayload> {
        let bodyParam = UserBatchRequestPayload(users: ids, projectId: projectId)
        let queryParameters: [String: Int] = ["page_size": ids.count]
        return .init(path: .userBatch,
                     method: .post,
                     query: queryParameters,
                     body: bodyParam
        )
    }

    /// Create the endpoint to update user's infomation.
    ///
    /// - Parameters:
    ///   - id: The user identifier.
    ///   - payload: The `UserUpdateRequestBody` has updated infomation.
    /// - Returns: The endpoint to update user's infomation.
    static func updateUser(
        id: UserId,
        payload: UserUpdateRequestBody
    ) -> Endpoint<UserPayload> {
        return .init(
            path: .updateUsers,
            method: .patch,
            body: payload
        )
    }

    /// Create the endpoint to get user's infomation.
    ///
    /// - Parameters:
    ///   - id: The user identifier.
    ///   - projectId: The project identifier
    /// - Returns: The endpoint to get user's infomation.
    static func getUser(id: UserId, projectId: String) -> Endpoint<UserPayload> {
        return .init(path: .getUser(id),
                     method: .get,
                     query: ["project_id": projectId],
                     needConnectionId: false)
    }

    /// Create the endpoint to get user's infomation without accessToken.
    ///
    /// - Parameters:
    ///   - id: The user identifier.
    ///   - projectId: The project identifier
    /// - Returns: The endpoint to get user's infomation.
    static func getUserInfo(id: UserId, projectId: String) -> Endpoint<UserPayload> {
        return .init(path: .getUserInfo(id),
                     method: .get,
                     query: ["project_id": projectId],
                     needConnectionId: false,
                     needToken: false)
    }

    /// Create the endpoint to update user's profile picture.
    ///
    /// - Returns: The endpoint to update user's profile picture.
    static func uploadUserAvatar() -> Endpoint<AvatarUploadPayload> {
        return .init(path: .uploadUserAvatar,
                     method: .post,
                     query: nil,
                     needConnectionId: false,
                     needToken: true)
    }

    /// Create the endpoint to get user challange for delete user's account if account sign in with Wallet.
    ///
    /// - Returns: The endpoint to get user challange for delete account.
    static func getDeleteUserChallange() -> Endpoint<SignWalletPayload> {
        return .init(path: .getDeleteUserChallange,
                     method: .get,
                     needToken: true)
    }

    /// Create the endpoint to delete user's account.
    ///
    /// - Parameters:
    ///   - signature: sinature string get when sign with wallet.
    /// - Returns: The endpoint to delete user's account.
    static func deleteUser(signature: String) -> Endpoint<EmptyResponse> {
        return .init(path: .deleteUser,
                     method: .post,
                     body: [
                        "signature": signature
                     ])
    }

    /// Create the endpoint to get otp code for delete user's account.
    ///
    /// - Returns: The endpoint to get otp code for delete user's account.
    static func getDeleteUserOtp() -> Endpoint<EmptyResponse> {
        return .init(path: .getDeleteUserOtp,
                     method: .get,
                     needToken: true)
    }

    /// Create the endpoint to delete user's account.
    ///
    /// - Parameters:
    ///   - otp: The otp has been send to user phone or email.
    /// - Returns: The endpoint to delete user's account.
    static func deleteUser(body: OtpRequestBody) -> Endpoint<EmptyResponse> {
        return .init(path: .deleteUser,
                     method: .delete,
                     body: body)
    }
}
