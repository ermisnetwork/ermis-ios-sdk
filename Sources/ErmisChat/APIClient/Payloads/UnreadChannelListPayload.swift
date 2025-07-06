//
// Copyright 2025 Ermis Inc.
//

import Foundation


public class UnreadProjectListPayload {
    public var projects: [UnreadProjectPayload] = []

    public init(projects: [UnreadProjectPayload]) {
        self.projects = projects
    }
}

public class UnreadProjectPayload {
    public let projectId: String
    public var unreadCount: Int

    public var hasUnread: Bool {
        unreadCount > 0
    }

    public init(projectId: String, unreadCount: Int) {
        self.projectId = projectId
        self.unreadCount = unreadCount
    }
}


