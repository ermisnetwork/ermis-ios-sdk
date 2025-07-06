//
// Copyright 2025 Ermis Inc.
//

import Foundation

extension Endpoint {
    /// Create the endpoint to subscrible for user info change events.
    ///
    /// - Returns: The endpoint to subscrible for user info change events.
    static func subscribe() -> Endpoint<SSEPayload> {
        .init(
            path: .subscribe,
            method: .get,
            needConnectionId: false,
            needToken: true
        )
    }
}
