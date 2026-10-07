//
// Copyright 2026 Ermis Inc.
//

import Foundation

struct GroupInfoRefreshRequestedEvent: ChannelSpecificEvent {
    let cid: ChannelId
    let parentCid: ChannelId? = nil
    let topicCids: [ChannelId] = []
    let request: GroupInfoRefreshRequestPayload
    let version: Int
}

final class GroupInfoRefreshRequestedEventDTO: EventDTO {
    let payload: EventPayload

    init(from response: EventPayload) throws {
        guard
            let cid = response.cid,
            let requestId = response.requestId,
            let minimumEpoch = response.minimumEpoch,
            let deadlineAt = response.deadlineAt,
            let expiresAt = response.expiresAt,
            let reason = response.banReason,
            let attemptCount = response.attemptCount,
            response.version == 1
        else {
            throw ClientError("Invalid GroupInfo refresh event")
        }
        payload = response
        request = .init(
            requestId: requestId,
            minimumEpoch: minimumEpoch,
            deadlineAt: deadlineAt,
            expiresAt: expiresAt,
            reason: reason,
            attemptCount: attemptCount,
            leaseToken: nil,
            leaseExpiresAt: nil
        )
        self.cid = cid
        version = 1
    }

    let cid: ChannelId
    let request: GroupInfoRefreshRequestPayload
    let version: Int

    func toDomainEvent(session: DatabaseSession) -> Event? {
        GroupInfoRefreshRequestedEvent(cid: cid, request: request, version: version)
    }
}

struct GroupInfoUploadedEvent: ChannelSpecificEvent {
    let cid: ChannelId
    let parentCid: ChannelId? = nil
    let topicCids: [ChannelId] = []
    let requestId: String
    let epoch: Int
    let hash: String
    let version: Int
}

final class GroupInfoUploadedEventDTO: EventDTO {
    let payload: EventPayload

    init(from response: EventPayload) throws {
        guard
            let cid = response.cid,
            let requestId = response.requestId,
            let epoch = response.epoch,
            let hash = response.hash,
            response.version == 1
        else {
            throw ClientError("Invalid GroupInfo uploaded event")
        }
        payload = response
        self.cid = cid
        self.requestId = requestId
        self.epoch = epoch
        self.hash = hash
        version = 1
    }

    let cid: ChannelId
    let requestId: String
    let epoch: Int
    let hash: String
    let version: Int

    func toDomainEvent(session: DatabaseSession) -> Event? {
        GroupInfoUploadedEvent(
            cid: cid,
            requestId: requestId,
            epoch: epoch,
            hash: hash,
            version: version
        )
    }
}
