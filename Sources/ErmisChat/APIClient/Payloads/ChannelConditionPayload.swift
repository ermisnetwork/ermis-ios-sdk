//
// Copyright 2025 Ermis Inc.
//

public struct ChannelConditionPayload: Decodable {
    public var tokenName: String
    public var minimumBalance: Double
    public var linkToPurchase: String
    public var conditionType: ConditionType

    enum CodingKeys: String, CodingKey {
        case tokenName = "token_name"
        case minimumBalance = "minimum_balance"
        case linkToPurchase = "link_to_purchase"
        case conditionType = "condition_type"
    }

    public
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.tokenName = try container.decode(String.self, forKey: .tokenName)
        self.minimumBalance = try container.decode(Double.self, forKey: .minimumBalance)
        self.linkToPurchase = try container.decode(String.self, forKey: .linkToPurchase)
        self.conditionType = try container.decode(ConditionType.self, forKey: .conditionType)
    }

    public init(tokenName: String, minimumBalance: Double) {
        self.tokenName = tokenName
        self.minimumBalance = minimumBalance
        self.linkToPurchase = "https://google.com.vn"
        self.conditionType = .token
    }
}

public enum ConditionType: String, Decodable {
    case token
    case nft
}
