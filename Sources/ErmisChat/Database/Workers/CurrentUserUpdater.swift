//
// Copyright 2025 Ermis Inc.
//

import CoreData
import Foundation

/// Updates current user data to the backend and updates local storage.
class CurrentUserUpdater: Worker {
    /// Updates the current user data.
    ///
    /// By default all data is `nil`, and it won't be updated unless a value is provided.
    ///
    /// - Parameters:
    ///   - currentUserId: The current user identifier.
    ///   - name: Optionally provide a new name to be updated.
    ///   - imageURL: Optionally provide a new image to be updated.
    ///   - completion: Called when user is successfuly updated, or with error.
    func updateUserData(
        currentUserId: UserId,
        projectId: String,
        name: String? = nil,
        imageData: Data? = nil,
        completion: ((Error?) -> Void)? = nil
    ) {
        let params: [Any?] = [name]
        guard !params.allSatisfy({ $0 == nil }) || imageData != nil else {
            log.warning("Update user request not performed. All provided data was nil.")
            completion?(nil)
            return
        }

        let payload = UserUpdateRequestBody(
            name: name
        )

        if let imageData = imageData {
            apiClient.uploadUserAvatar(imageData) { [weak self] result in
                switch result {
                case .success(let avatarPayload):
                    self?.database.write({ (session) in
                        session.currentUser?.user(of: projectId)?.imageURL = URL(string: avatarPayload.avatar)
                    }) { error in
                        if let name = name {
                            self?.updateUserInfo(currentUserId: currentUserId,
                                                 projectId: projectId,
                                                 name: name,
                                                 completion: completion)
                        } else {
                            completion?(nil)
                        }
                    }
                case .failure(let failure):
                    completion?(failure)
                }
            }
        } else {
            if name.isEmptyOrNil {
                return
            }
            updateUserInfo(currentUserId: currentUserId,
                           projectId: projectId,
                           name: name,
                           completion: completion)
        }
    }

    func updateUserInfo(currentUserId: String,
                        projectId: String,
                        name: String? = nil,
                        completion: ((Error?) -> Void)? = nil) {

        let payload = UserUpdateRequestBody(
            name: name
        )

        apiClient.request(endpoint: .updateUser(id: currentUserId,
                                                payload: payload)) { [weak self] result in
            switch result {
            case .success(let userPayload):
                self?.database.write({ session in
                    let userDTO = try session.saveUser(payload: userPayload,
                                                       projectId: projectId)
                    session.currentUser?.users.insert(userDTO)
                }, completion: { error in
                    completion?(error)
                })
            case .failure(let failure):
                completion?(failure)
            }
        }
    }

    /// Registers a device for push notifications to the current user.
    /// - Parameters:
    ///   - fcmToken: The device id.
    ///   - deviceToken: The push provider.
    ///   - projectId: The current project identifier.
    ///   - completion: Called when device is successfully registered, or with error.
    func addDevice(
        fcmToken: DeviceId,
        deviceToken: DeviceId?,
        projectId: String,
        completion: ((Error?) -> Void)? = nil
    ) {
        database.write { (session) in
            try session.saveCurrentDevice(fcmToken, projectId: projectId)
        }

        apiClient
            .request(
                endpoint: .addDevice(
                    fcmToken: fcmToken,
                    deviceToken: deviceToken
                ),
                completion: { result in
                    if let error = result.error {
                        log.debug("Device token \(fcmToken) failed to be registered on backend.\n Reason: \(error.localizedDescription)")
                        completion?(error)
                        return
                    }
                    log.debug("Device token \(fcmToken), \(deviceToken) was successfully registered on backend.")
                    completion?(nil)
                }
            )
    }

    /// Removes a registered device from the current user.
    /// - Parameters:
    ///   - fcmToken: fcmToken to be removed. You can obtain registered devices via `currentUser.devices`.
    ///   - completion: Called when device is successfully deregistered, or with error.
    func removeDevice(fcmToken: DeviceId, completion: ((Error?) -> Void)? = nil) {
        database.write { (session) in
            session.deleteDevice(id: fcmToken)
        }

        apiClient
            .request(
                endpoint: .removeDevice(
                    fcmToken: fcmToken
                ),
                completion: { result in
                    completion?(result.error)
                }
            )
    }

    /// Updates the registered devices for the current user from backend.
    /// 
    /// - Parameters:
    ///     - currentUserId: The current user identifier.
    ///     - projectId: The current project identifier.
    ///     - completion: Called when request is successfully completed, or with error.
    func fetchDevices(currentUserId: UserId, projectId: String, completion: ((Error?) -> Void)? = nil) {
        apiClient.request(endpoint: .devices(userId: currentUserId)) { [weak self] result in
            do {
                let devicesPayload = try result.get()
                self?.database.write({ (session) in
                    // Since this call always return all device, we want' to clear the existing ones
                    // to remove the deleted devices.
                    try session.saveCurrentUserDevices(devicesPayload.devices,
                                                       projectId: projectId,
                                                       clearExisting: true)
                }) { completion?($0) }
            } catch {
                completion?(error)
            }
        }
    }

    func getInfo(_ userId: UserId, projectId: String, completion: ((Error?) -> Void)? = nil) {
        apiClient
            .request(endpoint: .getUser(id: userId, projectId: projectId)) { (result: Result<UserPayload, Error>) in
                switch result {
                case let .success(user):
                    self.database.write({ session in
                        try session.saveUser(payload: user, projectId: projectId)
                    }, completion: { error in
                        if let error = error {
                            log.error("Failed to save user with id: <\(userId)> to the database. Error: \(error)")
                        }
                        completion?(error)
                    })
                case let .failure(error):
                    completion?(error)
                }
            }
    }

    /// Marks all channels for a user as read.
    /// - Parameter completion: Called when the API call is finished. Called with `Error` if the remote update fails.
    func markAllRead(completion: ((Error?) -> Void)? = nil) {
        apiClient.request(endpoint: .markAllRead()) {
            completion?($0.error)
        }
    }
}
