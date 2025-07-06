//
// Copyright 2025 Ermis Inc.
//

import Foundation

extension EndpointPath {
    var shouldBeQueuedOffline: Bool {
        switch self {
        case .sendMessage, .editMessage, .deleteMessage, .addReaction, .deleteReaction:
            return true
        default:
            return false
        }
    }
}

extension Endpoint {
    var shouldBeQueuedOffline: Bool {
        path.shouldBeQueuedOffline
    }
}
