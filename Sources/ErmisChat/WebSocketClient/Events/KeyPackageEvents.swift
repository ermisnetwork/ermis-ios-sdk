//
// Copyright 2026 Ermis Inc.
//

import Foundation

struct KeyPackageRefillEvent: Event {
    let idempotencyKey: String
    let deviceId: String
    let usableCount: Int
    let target: Int
    let requestedDelta: Int
    let reason: String
    let generation: Int
    let version: Int
}

final class KeyPackageRefillEventDTO: EventDTO {
    let payload: EventPayload
    let refill: KeyPackageRefillEvent

    init(from response: EventPayload) throws {
        guard
            let idempotencyKey = response.idempotencyKey,
            !idempotencyKey.isEmpty,
            let deviceId = response.deviceId,
            !deviceId.isEmpty,
            let usableCount = response.usableCount,
            let target = response.target,
            let requestedDelta = response.requestedDelta,
            let reason = response.banReason,
            let generation = response.generation,
            response.version == 1,
            E2eeKeyPackageRefillPolicy.isValidEvent(
                usableCount: usableCount,
                target: target,
                requestedDelta: requestedDelta,
                generation: generation
            )
        else {
            throw ClientError("Invalid KeyPackage refill event")
        }
        payload = response
        refill = .init(
            idempotencyKey: idempotencyKey,
            deviceId: deviceId,
            usableCount: usableCount,
            target: target,
            requestedDelta: requestedDelta,
            reason: reason,
            generation: generation,
            version: 1
        )
    }

    func toDomainEvent(session: DatabaseSession) -> Event? { refill }
}
