//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// The type is designed to store the JWT and the user it is related to.
public struct Token: Codable, Equatable {
    public let rawValue: String
    public let userId: UserId
    public let clientId: String
    public let projectId: String
    public let isErmis: Bool
    public let chainId: Int
    public let expiration: Date?

    /// This variable will not correct if user changed local time.
    public var isExpired: Bool {
        expiration.map { $0 < Date() } ?? false
    }

    /// Creates a `Token` instance from the provided `rawValue` if it's valid.
    /// - Parameter rawValue: The token string in JWT format.
    /// - Throws: `ClientError.InvalidToken` will be thrown if token string is invalid.
    public init(rawValue: String) throws {
        guard let jwtPayload = rawValue.jwtPayload,
              let userId = jwtPayload["user_id"] as? String,
              let clientId = jwtPayload["client_id"] as? String,
        let projectId = jwtPayload["project_id"] as? String,
        let chainId = jwtPayload["chain_id"] as? Int,
        let isErmis = jwtPayload["ermis"] as? Bool else {
            throw ClientError.InvalidToken("Provided token does not contain `user_id`")
        }
        let expiration = (rawValue.jwtPayload?["exp"] as? Int64).map {
            Date(timeIntervalSince1970: TimeInterval($0 / 1000))
        }
        self.init(rawValue: rawValue,
                  userId: userId,
                  clientId: clientId,
                  projectId: projectId,
                  chainId: chainId,
                  isErmis: isErmis,
                  expiration: expiration)
    }

    init(rawValue: String,
         userId: UserId,
         clientId: String,
         projectId: String,
         chainId: Int,
         isErmis: Bool,
         expiration: Date?) {
        self.rawValue = rawValue
        self.userId = userId
        self.expiration = expiration
        self.clientId = clientId
        self.projectId = projectId
        self.chainId = chainId
        self.isErmis = isErmis
    }

    public init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(), let rawValue = try? container.decode(String.self) {
            try self.init(
                rawValue: rawValue
            )
        } else {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let rawValue = try container.decode(String.self, forKey: .rawValue)
            try self.init(rawValue: rawValue)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        try self.rawValue.encode(to: encoder)
    }

    enum CodingKeys: String, CodingKey {
        case rawValue
        case userId = "user_id"
        case clientId = "client_id"
        case projectId = "project_id"
        case isErmis = "ermis"
        case expiration = "exp"
    }
}

extension ClientError {
    public class InvalidToken: ClientError {}
}

private extension String {
    var jwtPayload: [String: Any]? {
        let parts = split(separator: ".")

        if parts.count == 3,
           let payloadData = jwtDecodeBase64(String(parts[1])),
           let json = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any] {
            return json
        }

        return nil
    }

    func jwtDecodeBase64(_ input: String) -> Data? {
        let removeEndingCount = input.count % 4
        let ending = removeEndingCount > 0 ? String(repeating: "=", count: 4 - removeEndingCount) : ""
        let base64 = input.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + ending

        return Data(base64Encoded: base64)
    }
}
