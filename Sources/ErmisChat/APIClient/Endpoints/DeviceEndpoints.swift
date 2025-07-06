//
// Copyright 2025 Ermis Inc.
//

import Foundation

extension Endpoint {
    /// Create the endpoint to add a device to the user.
    ///
    /// - Parameters:
    ///   - fcmToken: fcmToken to be added.
    ///   - deviceToken: Pushkit device token to be added. This will used to send voip push.
    /// - Returns: The endpoint for adding a device.
    static func addDevice(
        fcmToken: DeviceId,
        deviceToken: DeviceId?
    ) -> Endpoint<EmptyResponse> {
        let body: [String: String?] = [
            "id": fcmToken,
            "device_token": deviceToken
        ]

        return .init(
            path: .devices("add"),
            method: .post,
            body: body,
            needConnectionId: true
        )
    }

    /// Create the endpoint to remove a device from the user.
    ///
    /// - Parameters:
    ///   - fcmToken: fcmToken to be added.
    /// - Returns: The endpoint for removing a device.
    static func removeDevice(fcmToken: DeviceId) -> Endpoint<EmptyResponse> {
        .init(
            path: .devices("delete"),
            method: .post,
            query: ["connection_id": UUID().uuidString],
            body: ["id": fcmToken]
        )
    }

    /// Create the endpoint to query devices registered to a user
    ///
    /// - Parameters:
    ///   - userId: UserId for adding the device.
    /// - Returns: The endpoint with `DevicesPayload` in the response.
    static func devices(userId: UserId) -> Endpoint<DeviceListPayload> {
        .init(
            path: .devices(""),
            method: .get,
            query: ["user_id": userId],
            needConnectionId: true
        )
    }
}
