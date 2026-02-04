//
// Copyright 2025 Ermis Inc.
//

import Foundation
import CallKit
import ErmisChat
import ErmisCall

/// Actor-isolated state management for CallManager
/// This ensures all state mutations are thread-safe and race-condition free
public actor CallManagerState {
    
    // MARK: - State Properties
    
    private(set) var currentCall: Call?

    private(set) var isIdle: Bool = true
    private(set) var isCallKitReady: Bool = true
    private(set) var lastCallEndedTime: Date?
    
    private(set) var callUUIDDictionary: [String: UUID] = [:]
    private(set) var endingCallUUIDs: Set<UUID> = []
    private(set) var historyCallState: [UUID: CXCall] = [:]
    
    // MARK: - Configuration
    
    private let minimumCallInterval: TimeInterval = 2.0

    // MARK: - Initialization
    
    public init() {
        
    }
    
    // MARK: - Call Management
    
    /// Atomically check if a new call can be started and reserve the slot
    /// - Returns: True if call can be created, false otherwise
    func canCreateCall() -> Bool {
        log.debug("[CallManagerState] canCreateCall() - isIdle: \(isIdle), isCallKitReady: \(isCallKitReady), currentCall: \(currentCall != nil), endingCallUUIDs: \(endingCallUUIDs)", subsystems: .call)
        
        guard isIdle else {
            log.warning("[CallManagerState] Cannot create call - not idle", subsystems: .call)
            return false
        }
        
        guard isCallKitReady else {
            log.warning("[CallManagerState] Cannot create call - CallKit not ready", subsystems: .call)
            return false
        }
        
        guard currentCall == nil else {
            log.warning("[CallManagerState] Cannot create call - currentCall exists", subsystems: .call)
            return false
        }
        
        if let lastEnded = lastCallEndedTime,
           Date().timeIntervalSince(lastEnded) < minimumCallInterval {
            log.warning("[CallManagerState] Cannot create call - too soon (last: \(lastEnded))", subsystems: .call)
            return false
        }
        
        guard endingCallUUIDs.isEmpty else {
            log.warning("[CallManagerState] Cannot create call - calls still ending: \(endingCallUUIDs)", subsystems: .call)
            return false
        }
        
        log.debug("[CallManagerState] Can create call - reserving slot", subsystems: .call)
        
        // Atomically reserve the slot
        isIdle = false
        isCallKitReady = false
        
        return true
    }
    
    /// Set the current call
    func setCurrentCall(_ call: Call?) {
        currentCall = call
    }
    
    /// Restore state after failed call creation
    func restoreStateAfterFailedCreation() {
        log.debug("[CallManagerState] Restoring state after failed call creation", subsystems: .call)
        isIdle = true
        isCallKitReady = true
    }
    
    /// Check if this is the current call
    func isCurrentCall(_ call: Call) async -> Bool {
        return await currentCall?.uuid == call.uuid
    }
    
    /// Check if call exists with ID
    func hasCallWithId(_ callId: String) async -> Bool {
        return await currentCall?.isCallWithId(callId) == true
    }
    
    // MARK: - Call Ending State
    
    func insertEndingCallUUID(_ uuid: UUID) {
        log.debug("[CallManagerState] Adding UUID to ending set: \(uuid)", subsystems: .call)
        endingCallUUIDs.insert(uuid)
    }
    
    func removeEndingCallUUID(_ uuid: UUID) {
        log.debug("[CallManagerState] Removing UUID from ending set: \(uuid)", subsystems: .call)
        endingCallUUIDs.remove(uuid)
    }
    
    func clearEndingCallUUIDs() {
        log.debug("[CallManagerState] Clearing all ending UUIDs: \(endingCallUUIDs)", subsystems: .call)
        endingCallUUIDs.removeAll()
    }
    
    func isEndingCallUUIDsEmpty() -> Bool {
        return endingCallUUIDs.isEmpty
    }
    
    func containsEndingCallUUID(_ uuid: UUID) -> Bool {
        return endingCallUUIDs.contains(uuid)
    }
    
    // MARK: - UUID Dictionary
    
    func addToCallUUIDDictionary(callId: String, uuid: UUID) {
        log.debug("[CallManagerState] Adding callId: \(callId) -> uuid: \(uuid)", subsystems: .call)
        callUUIDDictionary[callId] = uuid
    }
    
    func getCallUUID(for callId: String) -> UUID? {
        return callUUIDDictionary[callId]
    }
    
    func removeFromCallUUIDDictionary(callId: String) {
        callUUIDDictionary.removeValue(forKey: callId)
    }
    
    func callUUIDDictionaryContains(callId: String) -> Bool {
        return callUUIDDictionary[callId] != nil
    }
    
    // MARK: - CallKit State
    
    func setCallKitReady(_ value: Bool) {
        isCallKitReady = value
    }
    
    // MARK: - Call History
    
    func updateHistoryCallState(_ call: CXCall) {
        historyCallState[call.uuid] = call
    }
    
    // MARK: - Reset
    
    /// Atomically reset all state
    func resetAllState() {
        log.warning("[CallManagerState] resetAllState() called", subsystems: .call)
        log.debug("[CallManagerState] BEFORE reset: isIdle: \(isIdle), isCallKitReady: \(isCallKitReady), currentCall: \(currentCall != nil), endingCallUUIDs: \(endingCallUUIDs.count)", subsystems: .call)
        
        isIdle = true
        isCallKitReady = true
        lastCallEndedTime = Date()
        callUUIDDictionary.removeAll()
        endingCallUUIDs.removeAll()
        currentCall = nil
    }
}
