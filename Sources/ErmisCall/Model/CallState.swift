//
// Copyright 2025 Ermis Inc.
//

import Foundation
import ErmisChat

// Represent a call state.
public
enum CallState: Int {
    case idle
    case starting
    case reported
    case ringing
    case connecting
    case connected
    case ending
    case ended

    public var isConnected: Bool {
        switch self {
        case .connected, .ending, .ended:
            return true
        default:
            return false
        }
    }
}
