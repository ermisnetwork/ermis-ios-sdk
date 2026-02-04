//
// Copyright 2025 Ermis Inc.
//

import Foundation

public protocol CallNodeEventProtocol {
    var type: CallNodeEventType { get }
    var payload: Data { get }
    var data: Data { get }

    init?(payload: Data)
}

extension CallNodeEventProtocol {
    public var data: Data {
        var data = payload
        data.insert(type.rawValue, at: 0)
        return data
    }
}
