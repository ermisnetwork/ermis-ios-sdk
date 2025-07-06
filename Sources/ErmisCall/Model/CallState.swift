//
// Copyright 2025 Ermis Inc.
//

import Foundation
import ErmisChat

// Represent a call state.
public
enum CallState: Int {
    case idle
    case ringing
    case connecting
    case connected
    case ended

    public var isConnected: Bool {
        switch self {
        case .connected, .ended:
            return true
        default:
            return false
        }
    }
}
