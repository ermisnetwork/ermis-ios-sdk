//
// Copyright 2025 Ermis Inc.
//

import Foundation

public struct CallConnected: CallNodeEventProtocol {
    public var type: CallNodeEventType = .connected

    public var payload: Data {
        return Data()
    }

    public init?(payload: Data) {

    }

    public init() {
        
    }
}
