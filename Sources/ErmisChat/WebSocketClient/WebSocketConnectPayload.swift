//
// Copyright 2025 Ermis Inc.
//

import Foundation

class WebSocketConnectPayload: Encodable {
    enum CodingKeys: String, CodingKey {
        case json = "json"
        case authorization = "authorization"
    }

    let json: WebSocketConnectJsonPayload
    let authorization: String?

    init(userInfo: UserInfo, token: Token?, apiKey: String) {
        json = WebSocketConnectJsonPayload(userInfo: userInfo, apiKey: apiKey)
        if let token = token {
            authorization = "Bearer \(token.rawValue)"
        } else {
            authorization = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(json, forKey: .json)
        try container.encodeIfPresent(authorization, forKey: .authorization)
    }
}

struct WebSocketConnectJsonPayload: Encodable {
    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case userDetails = "user_details"
        case serverDeterminesConnectionId = "server_determines_connection_id"
    }

    let userId: UserId
    let userDetails: UserWebSocketPayload
    let serverDeterminesConnectionId: Bool

    init(userInfo: UserInfo, apiKey: String) {
        userId = userInfo.id
        userDetails = UserWebSocketPayload(userInfo: userInfo, apiKey: apiKey)
        serverDeterminesConnectionId = true
        
    }
}

struct UserWebSocketPayload: Encodable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case name
        case apiKey = "api_key"
        case isInvisible = "invisible"
        case imageURL = "image"
        case language
    }

    let id: String
    let apiKey: String
    let name: String?
    let imageURL: URL?
    let isInvisible: Bool?
    let language: String?

    init(userInfo: UserInfo, apiKey: String) {
        id = userInfo.id
        self.apiKey = apiKey
        name = userInfo.name
        imageURL = userInfo.imageURL
        isInvisible = userInfo.isInvisible
        language = userInfo.language?.languageCode
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(apiKey, forKey: .apiKey)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(imageURL, forKey: .imageURL)
        try container.encodeIfPresent(isInvisible, forKey: .isInvisible)
        try container.encodeIfPresent(language, forKey: .language)
    }
}
