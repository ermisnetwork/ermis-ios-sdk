//
// Copyright 2025 Ermis Inc.
//

import Foundation

public enum CallConnectionStatus {
    case normal
    case lowConnection
    case yourConnectionIsBeingEstablished
    case theirConnectionIsBeingEstablished(userIds: [String])
}

