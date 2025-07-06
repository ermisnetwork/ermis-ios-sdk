//
// Copyright 2025 Ermis Inc.
//

import Foundation

public class AuthenticationPayload: Decodable {

    enum CodingKeys: String, CodingKey {
        case token
        case refreshToken = "refresh_token"
        case userId = "user_id"
        case projectId = "project_id"
        case isFirstLogin = "is_first_login"
    }
    
    public let token: String
    public let refreshToken: String?
    public let userId: UserId
    public let projectId: String?
    public let isFirstLogin: Bool

    required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = try container.decode(String.self, forKey: .token)
        refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
        userId = try container.decode(String.self, forKey: .userId)
        projectId = try container.decodeIfPresent(String.self, forKey: .projectId)
        isFirstLogin = try container.decodeIfPresent(Bool.self, forKey: .isFirstLogin) ?? false
    }

}
