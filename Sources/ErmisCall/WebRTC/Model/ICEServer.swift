//
// Copyright 2025 Ermis Inc.
//

import Foundation
import StreamWebRTC

// A type which represent WebRTC IceServer.
public struct ICEServer: Codable, Hashable {
    public var userName: String
    public var password: String
    public var urls: [String]

    public init(userName: String, password: String, urls: [String]) {
        self.password = password
        self.urls = urls
        self.userName = userName
    }

    func toRTCICEServer() -> RTCIceServer {
        RTCIceServer(urlStrings: urls, username: userName, credential: password)
    }
}


