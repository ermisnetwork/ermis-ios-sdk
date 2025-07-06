//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// Object which represent Http request header.
struct HTTPHeader {
    let key: Key
    let value: String
}

extension HTTPHeader {
    enum Key: String {
        case authorization = "Authorization"
        case contentType = "Content-Type"
        case contentLength = "Content-Length"
    }
}

extension HTTPHeader {
    static func authorization(_ token: String) -> Self {
        .init(key: .authorization, value: token)
    }
}

extension URLRequest {
    mutating func setHTTPHeaders(_ headers: HTTPHeader...) {
        headers.forEach {
            setValue($0.value, forHTTPHeaderField: $0.key.rawValue)
        }
    }

    mutating func addHTTPHeaders(_ headers: HTTPHeader...) {
        headers.forEach {
            addValue($0.value, forHTTPHeaderField: $0.key.rawValue)
        }
    }
}
