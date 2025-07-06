//
// Copyright 2025 Ermis Inc.
//

import Foundation

struct RegisterRequestBody: Encodable {

    let email: String
    let password: String
    let apiKey: String

    enum CodingKeys: String, CodingKey {
        case email
        case password
        case apikey
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(email, forKey: .email)
        try container.encode(password, forKey: .password)
        try container.encode(apiKey, forKey: .apikey)
    }
}
