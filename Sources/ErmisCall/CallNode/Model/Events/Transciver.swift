//
// Copyright 2025 Ermis Inc.
//

import Foundation
import ErmisChat

public struct TransciverEvent: CallNodeEventProtocol {
    public var type: CallNodeEventType = .transciver
    public var state: TransciverState

    public var payload: Data {
        return (try! JSONEncoder().encode(state)) ?? Data()
    }

    public init?(payload: Data) {
        do {
            self.state = try JSONDecoder().decode(TransciverState.self, from: payload)
        } catch {
            return nil
            log.debug("[Call] Failed to decode TransciverState: \(error)")
        }
    }
    
    public init(state: TransciverState) {
        self.state = state
    }
}
