//
// Copyright 2025 Ermis Inc.
//

import Foundation

struct OtpRequestBody: Encodable {

    let identifier: String
    let otp: String
    let method: OtpMethod
    let apiKey: String

    init(identifier: String, otp: String, method: OtpMethod, apiKey: String) {
        self.identifier = identifier
        self.otp = otp
        self.method = method
        self.apiKey = apiKey
    }

    enum CodingKeys: String, CodingKey {
        case identifier
        case otp
        case method
        case apikey = "apikey"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(identifier, forKey: .identifier)
        try container.encode(otp, forKey: .otp)
        try container.encode(method, forKey: .method)
        try container.encode(apiKey, forKey: .apikey)
    }
}
