//
// Copyright 2025 Ermis Inc.
//

import Foundation

extension Endpoint {
    /// Create the endpoint to send call signal.
    ///
    /// - Parameters:
    ///   - body: The `CallSignalRequestBody` instance.
    /// - Returns: The endpoint send call signal.
    static func signal(body: CallSignalRequestBody) -> Endpoint<CallSignalRequestPayload> {
        .init(path: .signal,
              method: .post,
              body: body,
              needConnectionId: true,
              needToken: true)
    }

}

