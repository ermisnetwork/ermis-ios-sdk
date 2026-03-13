//
// Copyright 2025 Ermis Inc.
//

import Foundation

struct E2eEventMiddleware: EventMiddleware {
    func handle(event: any Event, session: any DatabaseSession) -> (any Event)? {
        do {
            switch event {
            case let event as HealthCheckEvent:
                break
            default:
                break
            }
        }
        return event
    }
}
