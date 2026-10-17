//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// A middleware which saves the incoming data from the Event to the database.
struct EventDataProcessorMiddleware: EventMiddleware {
    func handle(event: Event, session: DatabaseSession) -> Event? {
        if let removed = event as? MemberRemovedEventDTO,
           let member = session.member(userId: removed.member.userId, cid: removed.cid),
           let joinedAt = member.memberCreatedAt?.bridgeDate,
           joinedAt > removed.createdAt,
           member.isJoined || member.channelRoleRaw == MemberRole.pending.rawValue {
            // This must precede saveEvent: the old payload would overwrite the newer
            // membership timestamp before MemberEventMiddleware can compare it.
            log.info("mls_membership_event stage=obsolete_removed_ignored source=websocket", subsystems: .mls)
            return nil
        }
        guard let payload = (event as? EventDTO)?.payload else {
            return event
        }

        do {
            try session.saveEvent(payload: payload)
            return event
        } catch {
            log.error("Failed saving incoming `Event` data to DB. Error: \(error)")
            return nil
        }
    }
}
