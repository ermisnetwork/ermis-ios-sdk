//
// Copyright 2025 Ermis Inc.
//

import Foundation

public class CallSignalRequestPayload: Decodable {
    public let callId: String

    enum CodingKeys: String, CodingKey {
        case callId = "call_id"
    }

    required public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.callId = try container.decode(String.self, forKey: .callId)
    }
}


