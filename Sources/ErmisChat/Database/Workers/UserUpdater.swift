//
// Copyright 2025 Ermis Inc.
//

import Foundation
import ErmisShared

/// Makes user-related calls to the backend and updates the local storage with the results.
class UserUpdater: Worker {
    /// Mutes the user with the provided `userId`.
    /// - Parameters:
    ///   - userId: The user identifier.
    ///   - completion: Called when the API call is finished. Called with `Error` if the remote update fails.
    ///
    func muteUser(_ userId: UserId, completion: ((Error?) -> Void)? = nil) {
        apiClient.request(endpoint: .muteUser(userId)) {
            completion?($0.error)
        }
    }

    /// Unmutes the user with the provided `userId`.
    /// - Parameters:
    ///   - userId: The user identifier.
    ///   - completion: Called when the API call is finished. Called with `Error` if the remote update fails.
    ///
    func unmuteUser(_ userId: UserId, completion: ((Error?) -> Void)? = nil) {
        apiClient.request(endpoint: .unmuteUser(userId)) {
            completion?($0.error)
        }
    }

    /// Makes a single user query call to the backend and updates the local storage with the results.
    ///
    /// - Parameters:
    ///   - userId: The user identifier
    ///   - completion: Called when the API call is finished. Called with `Error` if the remote update fails.
    ///
    func loadUser(_ userId: UserId, projectId: String, completion: ((Error?) -> Void)? = nil) {
        apiClient
            .request(endpoint: .getUser(id: userId, projectId: projectId)) { (result: Result<UserPayload, Error>) in
                switch result {
                case let .success(user):
                    self.database.write({ session in
                        try session.saveUser(payload: user, projectId: projectId)
                    }, completion: { error in
                        if let error = error {
                            log.error("[USER] state=persist_failed \(PrivacySafeLogMetadata.errorFields(error))")
                        }
                        completion?(error)
                    })
                case let .failure(error):
                    completion?(error)
                }
            }
    }
}

extension ClientError {
    class UserDoesNotExist: ClientError {
        init(userId: UserId) {
            super.init("There is no user with id: <\(userId)>.")
        }
    }
}
