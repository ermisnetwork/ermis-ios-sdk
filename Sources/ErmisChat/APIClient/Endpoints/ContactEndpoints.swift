//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// Create the endpoint to get user's friend list.
///
/// - Parameters:
///   - projectId: The project identifier.
/// - Returns: The endpoint to get user's friend list.
extension Endpoint {
    static func getFriendContacts(projectId: String?) -> Endpoint<FriendContactListPayload> {
        .init(
            path: .friendContacts,
            method: .post,
            body: [
                "project_id": projectId ?? ""
            ]
        )
    }
}
