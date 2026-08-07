//
// Copyright 2025 Ermis Inc.
//

import Foundation

extension Endpoint {
    /// Create the endpoint to connect websocket.
    ///
    /// - Parameters:
    ///   - userInfo: The user's infomation.
    ///   - token: The access token.
    ///   - apiKey: Current apikey.
    /// - Returns: The endpoint to connect websocket.
    static func webSocketConnect(
        userInfo: UserInfo,
        token: Token?,
        deviceId: String,
        apiKey: String
    ) -> Endpoint<EmptyResponse> {
        .init(
            path: .connect,
            method: .get,
            query: [
                "device_id": deviceId,
                E2eeByteWireFormat.webSocketQueryName: E2eeByteWireFormat.headerValue
            ],
            body: WebSocketConnectPayload(userInfo: userInfo, token: token, apiKey: apiKey)
        )
    }
}
