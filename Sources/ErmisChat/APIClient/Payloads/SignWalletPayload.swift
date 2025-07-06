//
// Copyright 2025 Ermis Inc.
//

import Foundation

public struct SignWalletPayload: Codable {
    public let challenge: String

    public var value: ConnectionChanlenge? {
        let data = Data(challenge.utf8)
        let decoder = JSONDecoder()
        return try! decoder.decode(ConnectionChanlenge.self, from: data)
    }
}

public struct ConnectionChanlenge: Codable {
    public let types: ChallengeType
    public let domain: ChallengeDomain
    public let primaryType: String
    public let message: ChallengeMessage

}

public struct ChallengeType: Codable {
    let domain: [ChallengeTypeItem]
    let ownership: [ChallengeTypeItem]

    enum CodingKeys: String, CodingKey {
        case domain = "EIP712Domain"
        case ownership = "ProofOfOwnership"
    }
}

public struct ChallengeTypeItem: Codable {
    let name: String
    let type: String
}

public struct ChallengeDomain: Codable {
    let name: String
    let version: String
}

public struct ChallengeMessage: Codable {
    public let wallet: String
    public let content: String
    public let nonce: String

    enum CodingKeys: String, CodingKey {
        case wallet = "Wallet address"
        case content = "Content"
        case nonce = "Nonce"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.wallet = try container.decode(String.self, forKey: .wallet)
        self.content = try container.decode(String.self, forKey: .content)
        self.nonce = try container.decode(String.self, forKey: .nonce)
    }
}
