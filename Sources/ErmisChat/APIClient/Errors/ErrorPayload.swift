//
// Copyright 2025 Ermis Inc.
//

import Foundation

public
struct ErmisErrorPayload: Decodable {
    /// An ermis api error code.
    public let ermisCode: Int
    /// A error message.
    public let message: String
    /// A channel conditions if have
    public let channelCondtions: [ChannelConditionPayload]?
    let mlsRebootstrapState: MlsRebootstrapState?
    let mlsRebootstrapReason: MlsRebootstrapReason?
    let mlsRebootstrapRetryable: Bool?
    let expectedGeneration: Int?
    let currentGeneration: Int?
    let currentEpoch: Int?
    let operationKey: String?

    enum CodingKeys: String, CodingKey {
        case ermisCode = "ermis_code"
        case message
        case channelConditions = "channel_conditions"
        case mlsRebootstrapState = "state"
        case mlsRebootstrapReason = "reason"
        case mlsRebootstrapRetryable = "retryable"
        case expectedGeneration = "expected_generation"
        case currentGeneration = "current_generation"
        case currentEpoch = "current_epoch"
        case operationKey = "operation_key"
    }

    public
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.ermisCode = try container.decode(Int.self, forKey: .ermisCode)
        self.message = try container.decode(String.self, forKey: .message)
        self.channelCondtions = try container.decodeIfPresent([ChannelConditionPayload].self,
                                                              forKey: .channelConditions)
        self.mlsRebootstrapState = try container.decodeIfPresent(
            MlsRebootstrapState.self,
            forKey: .mlsRebootstrapState
        )
        self.mlsRebootstrapReason = try container.decodeIfPresent(
            MlsRebootstrapReason.self,
            forKey: .mlsRebootstrapReason
        )
        self.mlsRebootstrapRetryable = try container.decodeIfPresent(
            Bool.self,
            forKey: .mlsRebootstrapRetryable
        )
        self.expectedGeneration = try container.decodeIfPresent(Int.self, forKey: .expectedGeneration)
        self.currentGeneration = try container.decodeIfPresent(Int.self, forKey: .currentGeneration)
        self.currentEpoch = try container.decodeIfPresent(Int.self, forKey: .currentEpoch)
        self.operationKey = try container.decodeIfPresent(String.self, forKey: .operationKey)
    }

    init(ermisCode: Int, message: String) {
        self.ermisCode = ermisCode
        self.message = message
        self.channelCondtions = nil
        self.mlsRebootstrapState = nil
        self.mlsRebootstrapReason = nil
        self.mlsRebootstrapRetryable = nil
        self.expectedGeneration = nil
        self.currentGeneration = nil
        self.currentEpoch = nil
        self.operationKey = nil
    }

    public
    var description: String {
        "Ermis api error - #\(ermisCode) message: \(message)"
    }
}

public
struct WebSocketErrorPayload: LocalizedError, Decodable {
    enum CodingKeys: String, CodingKey {
        case code
        case message
        case statusCode = "StatusCode"
    }

    /// An error code.
    public let code: Int
    /// An error message.
    public let message: String
    /// A http status code.
    public let statusCode: Int
}
