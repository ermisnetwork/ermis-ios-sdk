//
// Copyright 2025 Ermis Inc.
//

import Foundation

struct LoginRequestBody: Encodable {

    enum CodingKeys: String, CodingKey {
        case email
        case password
        case apikey
    }

    let email: String
    let password: String
    let apiKey: String

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(email, forKey: .email)
        try container.encode(password, forKey: .password)
        try container.encode(apiKey, forKey: .apikey)
    }
}
