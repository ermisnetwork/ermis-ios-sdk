//
// Copyright 2025 Ermis Inc.
//

import Foundation

public struct WalletAuthenticateRequestBody: Codable {
    let address: String
    let signature: String
    let nonce: String
    let apiKey: String
    let expiration: Int? = nil

    enum CodingKeys: String, CodingKey {
        case address
        case signature
        case nonce
        case apiKey = "apikey"
        case expiration
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.address, forKey: .address)
        try container.encode(self.signature, forKey: .signature)
        try container.encode(self.nonce, forKey: .nonce)
        try container.encode(self.apiKey, forKey: .apiKey)
        try container.encodeIfPresent(self.expiration, forKey: .expiration)
    }
}
