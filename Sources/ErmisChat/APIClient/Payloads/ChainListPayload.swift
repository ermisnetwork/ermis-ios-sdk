//
// Copyright 2025 Ermis Inc.
//

import Foundation

public struct ChainListPayload: Codable {
    public var chains: [Int]
    public var joined: [ChainPayload]
    public var notJoined: [ChainPayload]

    enum CodingKeys: String, CodingKey {
        case chains
        case joined
        case notJoined = "not_joined"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.chains = try container.decode([Int].self, forKey: .chains)
        self.joined = try container.decode([ChainPayload].self, forKey: .joined)
        self.notJoined = try container.decode([ChainPayload].self, forKey: .notJoined)
    }
}

public struct ChainPayload: Codable {
    public var chainId: Int
    public var clients: [ErmisClientPayload]
    
    // Dictionary with key is chainId, value is chain's name.
    public static let chainNameDict: [Int: String] = [
        1: "Ethereum",
        42161: "Arbitrum One",
        137: "Polygon",
        43114: "Avalanche C-Chain",
        56: "BNB Smart Chain",
        10: "OP",
        100: "Gnosis",
        324: "zkSync",
        7777777: "Zora",
        8453: "Base",
        42220: "Celo",
        1313161554: "Aurora"
    ]

    enum CodingKeys: String, CodingKey {
        case chainId = "chain_id"
        case clients
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.chainId = try container.decode(Int.self, forKey: .chainId)
        self.clients = try container.decode([ErmisClientPayload].self, forKey: .clients)
    }
    /// Get chain name form chain identifier.
    public static func chainName(of chainId: Int) -> String {
        return chainNameDict[chainId] ?? ""
    }
}
