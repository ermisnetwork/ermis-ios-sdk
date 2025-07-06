//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// The middleware listens for `UserUpdatedEvent`s and updates the database accordingly.
struct UserUpdateMiddleware: EventMiddleware {
    func handle(event: Event, session: DatabaseSession) -> Event? {
        guard let userUpdatedEvent = event as? UserUpdatedEventDTO else { return event }
        do {
            try session.saveUser(payload: userUpdatedEvent.user, projectId: userUpdatedEvent.payload.getProjectId())
        } catch {
            log.error("Failed to update user in the database, error: \(error)")
        }
        return event
    }
}
