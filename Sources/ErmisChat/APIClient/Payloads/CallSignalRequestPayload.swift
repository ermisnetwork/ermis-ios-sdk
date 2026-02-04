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
        
        // Handle callId as either String or Number from the backend
        if let callIdString = try? container.decode(String.self, forKey: .callId) {
            self.callId = callIdString
        } else if let callIdInt = try? container.decode(Int.self, forKey: .callId) {
            self.callId = String(callIdInt)
        } else if let callIdInt64 = try? container.decode(Int64.self, forKey: .callId) {
            self.callId = String(callIdInt64)
        } else {
            throw DecodingError.typeMismatch(
                String.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected callId to be a String or Number"
                )
            )
        }
    }
}


