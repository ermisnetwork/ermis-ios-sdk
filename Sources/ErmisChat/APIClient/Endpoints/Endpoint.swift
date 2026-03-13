//
// Copyright 2025 Ermis Inc.
//

import Foundation

enum URLType: String, Codable {
    case auth
    case normal
    case sticker
}

struct Endpoint<ResponseType: Decodable>: Codable {
    let path: EndpointPath
    let method: EndpointMethod
    let query: Encodable?
    let needConnectionId: Bool
    let needDeviceId: Bool
    let needToken: Bool
    let urlType: URLType
    let body: Encodable?

    init(
        path: EndpointPath,
        method: EndpointMethod,
        query: Encodable? = nil,
        body: Encodable? = nil,
        needConnectionId: Bool = false,
        needDeviceId: Bool = false,
        needToken: Bool = true,
        urlType: URLType = .normal
    ) {
        self.path = path
        self.method = method
        self.query = query
        self.body = body
        self.needConnectionId = needConnectionId
        self.needDeviceId = needDeviceId
        self.needToken = needToken
        self.urlType = urlType
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case path
        case method
        case queryItems
        case requiresConnectionId
        case requiresDeviceId
        case requiresToken
        case body
        case urlType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(EndpointPath.self, forKey: .path)
        method = try container.decode(EndpointMethod.self, forKey: .method)
        query = try container.decodeIfPresent(Data.self, forKey: .queryItems)
        needConnectionId = try container.decode(Bool.self, forKey: .requiresConnectionId)
        needDeviceId = try container.decodeIfPresent(Bool.self, forKey: .requiresDeviceId) ?? false
        needToken = try container.decode(Bool.self, forKey: .requiresToken)
        body = try container.decodeIfPresent(Data.self, forKey: .body)
        urlType = try container.decode(URLType.self, forKey: .urlType)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encode(method, forKey: .method)
        if let queryItemsData = try query?.encodedAsData() {
            try container.encode(queryItemsData, forKey: .queryItems)
        }
        try container.encode(needConnectionId, forKey: .requiresConnectionId)
        try container.encode(needDeviceId, forKey: .requiresDeviceId)
        try container.encode(needToken, forKey: .requiresToken)
        if let body = try body?.encodedAsData() {
            try container.encode(body, forKey: .body)
        }
        try container.encode(urlType, forKey: .urlType)
    }
}

private extension Encodable {
    func encodedAsData() throws -> Data {
        try JSONEncoder.ermis.encode(AnyEncodable(self))
    }
}

enum EndpointMethod: String, Codable, Equatable {
    case get = "GET"
    case post = "POST"
    case patch = "PATCH"
    case delete = "DELETE"
}

/// A type representing empty response of an Endpoint.
public struct EmptyResponse: Decodable {
    enum CodingKeys: CodingKey {
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        self.init()
    }

}

/// A type representing empty body for `.post` Endpoints.
/// Our backend currently expects a body (not `nil`), even if it's empty.
struct EmptyBody: Codable, Equatable {}
