//
// Copyright 2025 Ermis Inc.
//

import Foundation
import ErmisChat
import PushKit
import CallKit
import AVFAudio
import UIKit
import Combine

public enum CallKitState {
    case idle
    case requestingStartCall
    case requestingEndCall
    case inProgress
}

public enum CallManagerMessage {
    case startEndingCall(uuid: UUID, id: String, cid: ChannelId?)
    case endCall(uuid: UUID, id: String, cid: ChannelId?)
    case createOutgoingCallError(uuid: UUID, error: Error)
    case failedToConnect(uuid: UUID, error: Error)
}

public protocol CallManagerDelegate: AnyObject {
    func callManager(_ manager: CallManager, didAccept call: Call?)
}

public class CallManager: NSObject, CXProviderDelegate, CXCallObserverDelegate, Sendable {
    public static let shared = CallManager()

    public var sessionId = UUID().uuidString.lowercased()
    var client: ErmisClient!
    var connectionController: ConnectionController!
    var callProvider :CXProvider
    var callController: CXCallController

    private var callKitQueue = DispatchQueue(label: "ermis_call_kit_queue", qos: .userInitiated)

    private var state = CallManagerState()

    lazy var  eventsController = client.eventsController()
    public lazy var ioAccessManager = IOAccessManager()

    public var audioManager: ErmisCallAudioManager {
        return ErmisCallAudioManager.shared
    }

    public weak var delegate: CallManagerDelegate?
    public var messagePublisher = PassthroughSubject<CallManagerMessage, Never>()

    public var pendingTasks: [Task<Void, Never>] = []

    public var callKitState: CallKitState = .idle

    // MARK: - Computed Properties (for backwards compatibility)

    public var currentCall: Call? {
        get async {
            await state.currentCall
        }
    }

    public var isIdle: Bool {
        get async {
            await state.isIdle
        }
    }

    public var isCallKitReady: Bool {
        get async {
            await state.isCallKitReady
        }
    }

    public var endingCallUUIDs: Set<UUID> {
        get async {
            await state.endingCallUUIDs
        }
    }

    // MARK: - Helper Methods

    public func addToCallUUIDDictionary(callId: String, uuid: UUID) async {
        await state.addToCallUUIDDictionary(callId: callId, uuid: uuid)
    }

    public func isEndingCallUUIDsEmpty() async -> Bool {
        return await state.isEndingCallUUIDsEmpty()
    }

    public func containsEndingCallUUID(_ uuid: UUID) async -> Bool {
        return await state.containsEndingCallUUID(uuid)
    }

    public static var needShowRequestMicrophoneAccessAlert: Bool {
        get {
            UserDefaults.standard.bool(forKey: "callKit.microphoneAccessDenied")
        }

        set {
            UserDefaults.standard.setValue(newValue, forKey: "callKit.microphoneAccessDenied")
        }
    }

    override init() {
        let providerConfig = CXProviderConfiguration()
        providerConfig.supportsVideo = true
        providerConfig.supportedHandleTypes = [.generic]
        providerConfig.maximumCallsPerCallGroup = 1
        providerConfig.maximumCallGroups = 1
        providerConfig.ringtoneSound = "ringback.mp3"
        providerConfig.includesCallsInRecents = true
        callProvider = CXProvider(configuration: providerConfig)
        callController = CXCallController()

        super.init()
        self.callProvider.setDelegate(self, queue: callKitQueue)
        self.callController.callObserver.setDelegate(self, queue: callKitQueue)
    }

    public func config(with client: ErmisClient?) {
        self.client = client
        // Register push registry
        eventsController.delegate = self
        guard let client else {
            return
        }
        connectionController = client.connectionController()
    }

    // MARK: - Create call
    public func canStartNewCall() async -> Bool {
        let isIdle = await state.isIdle
        let hasCurrentCall = await state.currentCall != nil
        let lastEnded = await state.lastCallEndedTime

        log.debug("[CallManager] canStartNewCall() called. isIdle: \(isIdle), currentCall exists: \(hasCurrentCall), lastCallEndedTime: \(String(describing: lastEnded))", subsystems: .call)

        // Check is state valid
        guard isIdle else {
            log.warning("[CallManager] Call manager state is not idle", subsystems: .call)
            return false
        }

        // First, check our internal state
        if hasCurrentCall {
            log.warning("[CallKit] Cannot start call - currentCall still exists", subsystems: .call)
            return false
        }

        // Check cooldown time
        if let lastEnded,
           Date().timeIntervalSince(lastEnded) < 1.0 {
            log.warning("[CallManager] Call attempted too soon", subsystems: .call)
            return false
        }

        await resetCallKitIfNeeded()

        return true
    }

    /// Creates a new  outgoing call in the given channel.
    ///
    /// - Parameters:
    ///   - channel: The channel
    ///   - isVideoCall: A boolean value detect this call is video call or audio call.
    ///
    /// - Returns: New outgoing call.
    public func createNewOutgoingCall(in channel: Channel, isVideoCall: Bool) async -> Call? {
        log.debug("[CallManager] createNewOutgoingCall(in:isVideoCall:) called with channel: \(channel.cid), isVideoCall: \(isVideoCall)", subsystems: .call)

        let canCreate = await state.canCreateCall()

        guard canCreate else {
            log.debug("[CallManager] Can not create outgoing call.", subsystems: .call)
            return nil
        }

        let isIdle = await state.isIdle
        let isCallKitReady = await state.isCallKitReady
        let hasCurrentCall = await state.currentCall != nil
        let endingUUIDs = await state.endingCallUUIDs

        log.debug("[CallManager] State check - isCallKitReady: \(isCallKitReady), isIdle: \(isIdle)", subsystems: .call)
        log.debug("[CallManager] State check - currentCall: \(hasCurrentCall)", subsystems: .call)
        log.debug("[CallManager] State check - endingCallUUIDs: \(endingUUIDs)", subsystems: .call)
        log.debug("[CallManager] State check - callObserver.calls: \(callController.callObserver.calls.count)", subsystems: .call)

        // Check if we're trying to recreate a call in the same channel
        if let currentCall = await state.currentCall {
            let details = await currentCall.details
            if details.cid == channel.cid {
                return currentCall
                log.debug("[CallManager] Returning existing call in same channel", subsystems: .call)
                log.debug("[CallManager] ═══════════════════════════════════════", subsystems: .call)
            }
        }

        let uuid = UUID()
        log.debug("[CallManager] Creating new call with UUID: \(uuid)", subsystems: .call)
        guard let call = await Call(sessionId: sessionId,
                              uuid: uuid,
                              callId: uuid.uuidString,
                              channel: channel,
                              client: client,
                              isVideo: isVideoCall,
                              isIncoming: false) else {
            log.debug("[CallManager] ❌ Failed to create new call with uuid: \(uuid.uuidString)", subsystems: .call)
            log.debug("[CallManager] ═══════════════════════════════════════", subsystems: .call)
            // ✅ ACTOR FIX: Restore state if call creation fails
            await state.restoreStateAfterFailedCreation()
            return nil
        }

        await state.setCurrentCall(call)
        log.debug("[CallManager] ✅ Created new outgoing call with uuid: \(uuid.uuidString)", subsystems: .call)
        log.debug("[CallManager] ═══════════════════════════════════════", subsystems: .call)
        return call
    }

    /// Creates a new  outgoing call in the given channel.
    ///
    /// - Parameters:
    ///   - channelId: The channel identifier
    ///   - isVideoCall: A boolean value detect this call is video call or audio call.
    ///
    /// - Returns: New outgoing call.
    public func createNewOutgoingCall(in cid: ChannelId, isVideoCall: Bool) async -> Call? {
        log.debug("[CallManager] createNewOutgoingCall(in:isVideoCall:) called with cid: \(cid), isVideoCall: \(isVideoCall)", subsystems: .call)

        // ✅ ACTOR FIX: Atomically check and reserve the call slot
        let canCreate = await state.canCreateCall()

        guard canCreate else {
            log.debug("[CallManager] ═══════════════════════════════════════", subsystems: .call)
            return nil
        }

        let observedCalls = callController.callObserver.calls
        if !observedCalls.isEmpty {
            log.warning("[CallManager] CallKit still has \(observedCalls.count) pending calls:")
            for call in observedCalls {
                log.warning("  - \(call.uuid): hasEnded=\(call.hasEnded)")
            }

            // Restore state before returning
            await state.restoreStateAfterFailedCreation()
            return nil
        }

        log.debug("[CallManager] ═══════════════════════════════════════", subsystems: .call)
        log.debug("[CallManager] createNewOutgoingCall CALLED", subsystems: .call)
        log.debug("[CallManager] Channel: \(cid), isVideo: \(isVideoCall)", subsystems: .call)
        let hasCurrentCall = await state.currentCall != nil
        log.debug("[CallManager] Current call exists: \(hasCurrentCall)", subsystems: .call)

        if let currentCall = await state.currentCall {
            let details = await currentCall.details
            if details.cid == cid {
                return currentCall
            }
        }

        let uuid = UUID()
        guard let call = await Call(sessionId: sessionId,
                              uuid: uuid,
                              callId: uuid.uuidString,
                              cid: cid,
                              client: client,
                              isVideo: isVideoCall,
                              isIncoming: false) else {
            log.debug("[Call] Failed to create new call with uuid: \(uuid.uuidString)", subsystems: .call)
            // ✅ ACTOR FIX: Restore state if call creation fails
            await state.restoreStateAfterFailedCreation()
            return nil
        }

        await state.setCurrentCall(call)
        log.debug("[Call] Create new call with uuid: \(uuid.uuidString)", subsystems: .call)
        return call
    }

    /// Creates a new  incoming call when receive `createCall` signal event.
    ///
    /// - Parameters:
    ///   - event: The `CallSignalEvent`
    ///   - uuid: The `UUID` of the call that report to CallKit.
    ///
    /// - Returns: New incoming call.
    @MainActor
    public func createNewIncomingCall(from event: CallSignalEvent, uuid: UUID) -> Call? {
        log.debug("[CallManager] createNewIncomingCall(from:uuid:) called with event callId: \(event.callId), uuid: \(uuid.uuidString)", subsystems: .call)
        guard let call = Call(sessionId: sessionId,
                              uuid: uuid,
                              callId: event.callId,
                              cid: event.cid,
                              client: client,
                              isVideo: event.isVideo ?? false,
                              isIncoming: true) else {
            log.debug("[Call] Failed to create new incoming call with uuid: \(uuid.uuidString)", subsystems: .call)
            return nil
        }

        let signaling = Signaler(client: client, cid: event.cid)
        let relayUrls = ["https://iroh-relay.ermis.network:8443"]
        guard let callNodeClient = CallNodeClient(signaling: signaling, relayUrls: relayUrls) else {
            return nil
        }
        call.callNodeClient.remoteAddress = event.metadata?.address

        pendingTasks.append(Task.detached() {
            await try? self.connectionSocket()
        })
        return call
    }

    // MARK: - Call
    func getCallUUID(for callId: String) async -> UUID? {
        return await state.getCallUUID(for: callId)
    }

    // Remove current call without send ending signal.
    public func clearCall(_ callId: String, with reason: CXCallEndedReason) {
        log.debug("[CallManager] clearCall(_:with:) called with callId: \(callId), reason: \(reason)", subsystems: .call)

        Task { @MainActor [weak self] in
            guard let self else { return }

            let currentCall = await state.currentCall
            let isEmpty = await state.isEndingCallUUIDsEmpty()

            guard let currentCall, await currentCall.isCallWithId(callId), isEmpty else {
                log.debug("[CallManager] clearCall guard failed - currentCall: \(String(describing: currentCall)), isEndingCallUUIDsEmpty: \(isEmpty)", subsystems: .call)
                return
            }

            guard await isEndingCallUUIDsEmpty() else {
                return
            }

            let details = await currentCall.details

            currentCall.callNodeClient.preStop()
            currentCall.callNodeClient.close()
            log.warning("[Call] clearCall: \(details.callId), reason: \(reason)", subsystems: .call)
            await state.insertEndingCallUUID(currentCall.uuid)

            callProvider.reportCall(with: details.uuid, endedAt: Date(), reason: reason)

            UIApplication.shared.isIdleTimerDisabled = false
            self.sendStartEndingCallNotification(details.callId, callUUID: details.uuid, cid: details.cid)
            sendEndCallNotification(details.callId, callUUID: details.uuid, cid: details.cid)
            self.pendingTasks.forEach({ $0.cancel()})
            await currentCall.setState(.ended)
            await self.onCallEnded(currentCall)
        }
    }

    /// End the call with given identifier.
    ///
    /// - Parameters:
    ///   - callId: The call identifier.
    /// End the call with given identifier.
    ///
    public func endCall(with callId: String) {
        log.debug("[CallManager] endCall(with:) called with callId: \(callId)", subsystems: .call)


        Task { @MainActor [weak self] in
            guard let self else { return }

            let endingUUIDs = await state.endingCallUUIDs
            let callUUIDDict = await state.callUUIDDictionary

            log.debug("[CallKit] ═══════════════════════════════════════", subsystems: .call)
            log.debug("[CallKit] ═══ endCall(with:) CALLED ═══", subsystems: .call)
            log.debug("[CallKit] callId: \(callId)", subsystems: .call)
            log.debug("[CallKit] endingCallUUIDs before check: \(endingUUIDs)", subsystems: .call)
            log.debug("[CallKit] callUUIDDictionary: \(callUUIDDict)", subsystems: .call)

            guard await state.isEndingCallUUIDsEmpty() else {
                log.debug("[CallKit] ❌ endCall BLOCKED - endingCallUUIDs not empty: \(endingUUIDs)", subsystems: .call)
                log.debug("[CallKit] ═══════════════════════════════════════", subsystems: .call)
                return
            }

            log.debug("[CallKit] ✅ endCall guard PASSED - proceeding", subsystems: .call)

            guard let currentCall = await state.currentCall, await currentCall.isCallWithId(callId) else {
                log.warning("[CallKit] Ending call that nil or wrong, callID: \(callId)", subsystems: .call)
                return
            }

            let details = await currentCall.details

            self.pendingTasks.forEach({ $0.cancel()})

            await state.insertEndingCallUUID(currentCall.details.uuid)
            currentCall.callNodeClient.preStop()
            await currentCall.callNodeClient.close()

            switch details.state {
                // Call still not reported to callkit, no need to report call ended.
            case .idle, .starting:
                log.warning("[CallManager] Ending the call that not reported to callkit", subsystems: .call)
                sendEndCallNotification(details.callId, callUUID: details.uuid, cid: details.cid)
                await resetValue()
                return
            default:
                break
            }

            requestEndCallTransaction(currentCall)

            Task(priority: .userInitiated) {
                sendEndCallNotification(details.callId, callUUID: details.uuid, cid: details.cid)
                await performCallCleanUp(currentCall)
            }
        }
    }

    private func requestEndCallTransaction(_ call: Call) {
        Task { @MainActor in
            let callId = await call.callId
            let details = await call.details

            log.debug("[CallManager] requestEndCallTransaction(_:) START for callId: \(callId), uuid: \(details.uuid)", subsystems: .call)

            // Prevent duplicate end call requests
            if callKitState == .requestingEndCall {
                log.debug("[CallManager] End call transaction already in progress for UUID: \(details.uuid), skipping duplicate request", subsystems: .call)
                return
            }
            let pendingActions = callProvider.pendingCallActions(of: CXEndCallAction.self, withCall: details.uuid)
            if !pendingActions.isEmpty {
                log.debug("[CallManager] Pending CXEndCallAction already exists for UUID: \(details.uuid), skipping duplicate request", subsystems: .call)
                return
            }

            callKitState = .requestingEndCall

            log.debug("[CallKit] endcall creating transaction for UUID: \(details.uuid)", subsystems: .call)

            let endAction = CXEndCallAction(call: details.uuid)

            let transaction = CXTransaction()
            transaction.addAction(endAction)
            log.debug("[CallKit] About to requestTransaction for UUID: \(details.uuid)", subsystems: .call)
            do {
                try await requestTransaction(transaction)
                callKitState = .idle
            } catch {
                log.debug("[CallKit] Request endcall transaction completed with error: \(error)")
                callKitState = .idle
                sendEndCallNotification(details.callId, callUUID: details.uuid, cid: details.cid)
                await performCallCleanUp(call)
                callProvider.reportCall(with: details.uuid, endedAt: Date(), reason: .failed)
            }
        }
    }

    func handleEndCallTimeout(_ call: Call) async {
        let details = await call.details
        sendEndCallNotification(details.callId, callUUID: details.uuid, cid: details.cid)
        await self.performCallCleanUp(call)
        self.callProvider.reportCall(with: details.uuid, endedAt: Date(), reason: .unanswered)
        await onCallEnded(call)
    }

    func sendEndCallNotification(_ callId: String, callUUID: UUID, cid: ChannelId?) {
        log.debug("[CallManager] Send end call notificaiton: \(callUUID)", subsystems: .call)
        messagePublisher.send(.endCall(uuid: callUUID, id: callId, cid: cid))
        Task { @MainActor in
            NotificationCenter.default.post(name: .callDidEnded,
                                            object: self,
                                            userInfo: [
                                                "call_id": callId,
                                                "call_uuid": callUUID,
                                                "cid": cid
                                            ]
            )
        }

    }

    func sendStartEndingCallNotification(_ callId: String, callUUID: UUID, cid: ChannelId?) {
        log.debug("[CallManager] Send start ending call notification for callId: \(callId), uuid: \(callUUID)", subsystems: .call)
        messagePublisher.send(.startEndingCall(uuid: callUUID, id: callId, cid: cid))
    }

    func sendMissedCallNotification(_ callSignalEvent: CallSignalEvent) {
        log.debug("[CallManager] Send miss call notification callId: \(callSignalEvent.callId)", subsystems: .call)
        if let data = try? JSONEncoder().encode(callSignalEvent) {
            let content = UNMutableNotificationContent()
            let dataStringValue = String(data: data, encoding: .utf8)
            content.userInfo = ["data": dataStringValue]
            content.title = "Ermis"
            content.body = callSignalEvent.isVideo == true ? "Missed video call" : "Missed audio call"
            let request = UNNotificationRequest(identifier: UUID().uuidString,
                                                content: content,
                                                trigger: nil)
            Task {
                do {
                    try await UNUserNotificationCenter.current().add(request)
                } catch {
                    log.error("[CallManager] Failed to send missed call notification: \(error)", subsystems: .call)
                }
            }
        }
    }
    ////
    func connectionSocket() async throws {
        return try await withCheckedThrowingContinuation { continuation in
            guard let connectionController else {
                continuation.resume(throwing: ClientError("[CallManager] Connection controller is nil."))
                return
            }
            guard client.connectionStatus != .connected else {
                continuation.resume()
                return
            }

            connectionController.connect(completion: { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func handleStartCallTimeout(_ call: Call) {
        Task { @MainActor [weak self] in
            guard let self else { return }

            let callId = await call.callId
            let details = await call.details

            log.error("[CallManager] handleStartCallTimeout(_:) called for callId: \(callId), uuid: \(details.uuid), ending call", subsystems: .call)
            sendEndCallNotification(details.callId, callUUID: details.uuid, cid: details.cid)
            await state.insertEndingCallUUID(details.uuid)

            Task.detached(priority: .userInitiated) {
                do {
                    try await call.callNodeClient.endCall()
                } catch {
                    log.error("[CallManager] handleStartCallTimeout - endCall failed: \(error)")
                }
                await self.onCallEnded(call)
                await self.state.setCallKitReady(true)
            }
        }
    }

    func onCallEnded(_ call: Call) async {
        let callId = await call.callId
        let details = await call.details

        log.debug("[CallManager] onCallEnded(_:) START for callId: \(callId), uuid: \(details.uuid)", subsystems: .call)

        // Check if this is still our current call BEFORE clearing anything
        let isCurrentCall = await state.isCurrentCall(call)

        // Clean up the call object
//        await call.close()
        log.debug("[CallManager] Call closed for callId: \(callId)", subsystems: .call)

        if details.state != .ended {
            await call.setState(.ended)
            log.debug("[CallManager] Call state set to ended for callId: \(callId)", subsystems: .call)
        }

//        sendEndCallNotification(details.callId, callUUID: details.uuid, cid: details.cid)

        // Only reset if this was our current call
        if isCurrentCall {
            log.debug("[CallManager] onCallEnded: call was currentCall, resetting values", subsystems: .call)
            await resetValue()
        } else {
            await state.removeEndingCallUUID(details.uuid)
            log.debug("[CallManager] onCallEnded: call was NOT currentCall, removed from endingCallUUIDs", subsystems: .call)
        }

        log.debug("[CallManager] ✅ onCallEnded END - Cleanup complete for callId: \(callId)", subsystems: .call)
    }

    private func cleanupOrphanedCallKitCalls() {
        //        let orphanedCalls = callController.callObserver.calls.filter { !$0.hasEnded }
        //
        //        for call in orphanedCalls {
        //            // Skip if this is our current/pending call
        //            guard !pendingStartCallUUIDs.contains(call.uuid) else { continue }
        //            guard currentCall?.details.uuid != call.uuid else { continue }
        //
        //            log.warning("[CallKit] Cleaning orphaned call: \(call.uuid)")
        //
        //            // Use CXEndCallAction transaction instead of just reporting
        //            let endAction = CXEndCallAction(call: call.uuid)
        //            let transaction = CXTransaction(action: endAction)
        //
        //            callController.request(transaction) { error in
        //                if let error {
        //                    // Fallback: force report as ended
        //                    self.callProvider.reportCall(with: call.uuid, endedAt: Date(), reason: .failed)
        //                }
        //            }
        //        }
    }

    private func performCallCleanUp(_ call: Call) async {
        let callId = await call.callId
        let details = await call.details
        let isLocalId = await call.isLocalId
        let isMissed = await call.isMissed

        pendingTasks.forEach({ $0.cancel()})
        pendingTasks.removeAll()

        log.debug("[CallManager] performCallCleanUp(_:) START for callId: \(callId), uuid: \(details.uuid)", subsystems: .call)
        if !isLocalId {
            do {
                if details.state.isConnected || isMissed {
                    log.debug("[CallManager] performCallCleanUp: Try to endCall for callId: \(callId)", subsystems: .call)
                    try await call.endCall()
                } else if !details.isIncoming {
                    log.debug("[CallManager] performCallCleanUp: Try to endCall for outgoing callId: \(callId)", subsystems: .call)
                    try await call.endCall()
                } else {
                    log.debug("[CallManager] performCallCleanUp: Try to rejectCall for incoming callId: \(callId)", subsystems: .call)
                    try await call.rejectCall()
                }
            } catch {
                log.error("[CallManager] Failed to send end signal: \(error)", subsystems: .call)
            }
        }

        await onCallEnded(call)
        log.debug("[CallManager] performCallCleanUp(_:) END for callId: \(callId)", subsystems: .call)
    }
    // MARK: - Report call events.
    /// Report new incomming call to `CallKit`
    package func reportIncommingCall(_ event: CallSignalEvent, completion: @escaping () -> Void) {
        log.debug("[CallManager] reportIncommingCall(_:) called with event: \(String(describing: event))", subsystems: .call)
        
        // CRITICAL FIX: Generate UUID and report to CallKit IMMEDIATELY, before any other work
        var callUUID = UUID()
//        let currentCall = await self.state.currentCall
//        let endingUUIDs = await self.state.endingCallUUIDs
//
//        if let event, let currentCall, await currentCall.isCallWithId(event.callId) {
//            callUUID = await currentCall.uuid
//        } else if let event, currentCall == nil {
//            let call = await createNewIncomingCall(from: event, uuid: callUUID)
//            await state.setCurrentCall(call)
//        }
        Task {
            let call = await createNewIncomingCall(from: event, uuid: callUUID)
            await state.setCurrentCall(call)
        }

        let callUpdate = CXCallUpdate()
        callUpdate.hasVideo = event.isVideo ?? false
        callUpdate.supportsDTMF = false
        callUpdate.supportsHolding = false
        callUpdate.supportsGrouping = false
        callUpdate.supportsUngrouping = false
        callUpdate.localizedCallerName = event.channel.name ??
        event.channel.directUserMembership?.name ??
        event.channel.cid.rawValue ?? "Unknown"
        callUpdate.remoteHandle = CXHandle(type: .generic, value: event.cid.rawValue)

        // Configure audio session BEFORE reporting (this is fast and synchronous)
        ErmisCallAudioManager.shared.configureAudioSession(isIncomingCall: true, isVideoCall: callUpdate.hasVideo)
        
        do {
            try callProvider.reportNewIncomingCall(with: callUUID, update: callUpdate, completion: { error in
                completion()
            })
            log.debug("[CallKit] Successfully reported incoming call: \(callUUID.uuidString)", subsystems: .call)
        } catch let error {
            log.error("[CallManager] Failed to report incoming call: \(error.localizedDescription)", subsystems: .call)
            if let error = error as? CXErrorCodeIncomingCallError {
                switch error.code {
                case .unknown:
                    log.debug("[CallKit] Failed to report incoming call: [.unknown]")
                case .unentitled:
                    log.debug("[CallKit] Failed to report incoming call: [.unentitled]")
                case .callUUIDAlreadyExists:
                    log.debug("[CallKit] Failed to report incoming call: [.callUUIDAlreadyExists]")
                case .filteredByDoNotDisturb:
                    log.debug("[CallKit] Failed to report incoming call: [.filteredByDoNotDisturb]")
                case .filteredByBlockList:
                    log.debug("[CallKit] Failed to report incoming call: [.filteredByBlockList]")
                @unknown default:
                    log.debug("[CallKit] Failed to report incoming call: [@unknown]")
                }
            }
        }
    }

    @MainActor
    public func reportOutgoingCallStarted(_ call: Call) async {
        let details = await call.details
        log.debug("[CallManager] reportOutgoingCallStarted(_:) called for callId: \(details.callId), uuid: \(details.uuid)", subsystems: .call)

        await call.setState(.starting)

        let uuid = details.uuid
        let isVideo = details.isVideo
        let title = details.title
        let cid = details.cid

        log.debug("[CallKit] Reporting outgoing call: \(uuid)", subsystems: .call)
        log.debug("[CallKit] Current call: \(callController.callObserver.calls)")

        // Prevent duplicate start call transaction requests
        if callKitState == .requestingStartCall {
            log.debug("[CallManager] Start call transaction already in progress for UUID: \(uuid), skipping duplicate request", subsystems: .call)
            return
        }
        callKitState = .requestingStartCall

        let handle = CXHandle(type: .generic, value: cid.rawValue)
        var startCallAction = CXStartCallAction(call: uuid, handle: handle)
        startCallAction.isVideo = isVideo
        startCallAction.contactIdentifier = title
        let transaction = CXTransaction()
        transaction.addAction(startCallAction)

        do {
            try await requestTransaction(transaction)
            callKitState = .idle
            log.debug("[CallKit] Report outgoing call: \(uuid)", subsystems: .call)
        } catch let error {
            callKitState = .idle
            log.error("[CallKit] Failed to report outgoing call: \(uuid) with error: \(error)", subsystems: .call)
            self.messagePublisher.send(.createOutgoingCallError(uuid: uuid, error: error))
            let callId = await call.callId
            let cid = await call.details.cid
            await self.resetValue()
        }
    }

    @MainActor
    package func reportUpdateCall(for callUUID: UUID, localizedCallName: String? = nil, hasVideo: Bool? = nil) {
        log.debug("[CallManager] reportUpdateCall(for:localizedCallName:hasVideo:) called for uuid: \(callUUID)", subsystems: .call)
        let callUpdate = CXCallUpdate()
        if let hasVideo {
            callUpdate.hasVideo = hasVideo
        }
        if let localizedCallName {
            callUpdate.localizedCallerName = localizedCallName
        }
        callUpdate.supportsDTMF = false
        callUpdate.supportsHolding = false
        callUpdate.supportsGrouping = false
        callUpdate.supportsUngrouping = false
        callProvider.reportCall(with: callUUID, updated: callUpdate)
    }



    @MainActor
    package func reportOutgoingCallStartConnecting(_ event: CallSignalEvent?) {
        log.debug("[CallManager] reportOutgoingCallStartConnecting(_:) called with event: \(String(describing: event))", subsystems: .call)
        
        Task { @MainActor [weak self] in
            guard let self, let event else {
                log.warning("[CallManager] reportOutgoingCallStartConnecting: event is nil", subsystems: .call)
                return
            }
            
            let currentCall = await state.currentCall
            guard let currentCall, await currentCall.isCallWithId(event.callId) else {
                log.warning("[CallManager] receive wrong event, can not report outgoing call start connecting: currentCall: \(String(describing: currentCall)), event: \(event)", subsystems: .call)
                return
            }

            let callUUID = await currentCall.details.uuid
            await state.addToCallUUIDDictionary(callId: event.callId, uuid: callUUID)
            callProvider.reportOutgoingCall(with: callUUID, startedConnectingAt: Date())
        }
    }

    @MainActor
    package func reportOutgoingCallConnected(uuid: UUID?, connectedAt connectedDate: Date?) {
        guard let uuid else {
            return
        }
        callProvider.reportOutgoingCall(with: uuid, connectedAt: connectedDate)
        log.debug("[CallManager] reportOutgoingCallConnected(uuid:connectedAt:) called for uuid: \(uuid.uuidString), connectedAt: \(String(describing: connectedDate))", subsystems: .call)
    }

    @MainActor
    package func reportCallEnded(_ event: CallSignalEvent, reason: CXCallEndedReason) {
        log.debug("[CallManager] reportCallEnded(_:, reason:) called for callId: \(event.callId), reason: \(reason)", subsystems: .call)
        
        Task { [weak self] in
            guard let self else { return }
            
            guard let uuid = await getCallUUID(for: event.callId) else {
                log.debug("[CallManager] reportCallEnded: no callUUID found for callId: \(event.callId)", subsystems: .call)
                return
            }
            
            callProvider.reportCall(with: uuid, endedAt: event.createdAt, reason: reason)
            log.debug("[CallManager] Request call ended \(uuid.uuidString) reason: \(String(describing: reason))", subsystems: .call)
        }
    }

    @MainActor
    private func requestTransaction(_ transaction: CXTransaction) async throws {
        log.debug("[CallManager] requestTransaction(_:) CALLED with actions: \(transaction.actions)", subsystems: .call)
        do {
            try await callController.request(transaction)
            log.debug("[CallManager] Request transaction succeeded", subsystems: .call)
        } catch let error {
            log.error("[CallManager] Request transaction failed: \(error.localizedDescription)", subsystems: .call)
            if let error = error as? CXErrorCodeRequestTransactionError {
                switch error.code {
                case .unknown:
                    log.debug("[CallKit] Unknown error", subsystems: .call)
                case .unentitled:
                    log.debug("[CallKit] App not entitled for CallKit", subsystems: .call)
                case .unknownCallProvider:
                    log.debug("[CallKit] Unknown call provider - need to recreate provider", subsystems: .call)
                case .emptyTransaction:
                    log.debug("[CallKit] Empty transaction", subsystems: .call)
                case .unknownCallUUID:
                    log.debug("[CallKit] Call UUID not found - call may already ended", subsystems: .call)
                case .callUUIDAlreadyExists:
                    log.debug("[CallKit] Call UUID already exists", subsystems: .call)
                case .invalidAction:
                    log.debug("[CallKit] Invalid action for current call state", subsystems: .call)
                case .maximumCallGroupsReached:
                    log.debug("[CallKit] Maximum call groups reached", subsystems: .call)
                @unknown default:
                    log.debug("[CallKit] New unhandled error: \(error.code.rawValue)", subsystems: .call)
                }
            }
            throw error
        }
    }

    // MARK: - Ringing audio
    func playRingingSoundIfNeeded() async {
        let details = await state.currentCall?.details
        guard details?.isIncoming == false, details?.state == .ringing else {
            return
        }
        guard let url = Bundle.ermisCall.url(forResource: "ringback", withExtension: "mp3") else {
            return
        }
        RingingAudioPlayer.shared.playSound(at: url,
                                            vibrate: false,
                                            useBuiltInReceiver: details?.isVideo == false)
    }

    func stopPlayingRingingSound() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let details = await state.currentCall?.details
            guard details?.isIncoming == false else {
                return
            }
            RingingAudioPlayer.shared.stopPlaying(false)
        }
    }
    // MARK: - CXProviderDelegate
    @MainActor
    public func providerDidBegin(_ provider: CXProvider) {
        log.debug("[CallManager] providerDidBegin(_:) called", subsystems: .call)
        log.debug("[CallKit] Provider did begin.", subsystems: .call)
//        let providerConfig = CXProviderConfiguration()
//        providerConfig.supportsVideo = true
//        providerConfig.supportedHandleTypes = [.generic]
//        providerConfig.maximumCallsPerCallGroup = 1
//        providerConfig.maximumCallGroups = 1
//        providerConfig.ringtoneSound = "ringback.mp3"
//
//        callProvider.configuration = providerConfig
    }

    @MainActor
    public func providerDidReset(_ provider: CXProvider) {
        log.debug("[CallManager] providerDidReset(_:) called", subsystems: .call)
        
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let currentCall = await state.currentCall {
                let callId = await currentCall.details.callId
                log.debug("[CallManager] providerDidReset - clearing currentCall with callId: \(callId)", subsystems: .call)
                clearCall(callId, with: .failed)
            }
            log.debug("[CallKit] provider did reset.", subsystems: .call)
        }
    }

    @MainActor
    public func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        log.debug("[CallManager] provider(_:perform:) called with CXStartCallAction, uuid: \(action.callUUID)", subsystems: .call)
        log.debug("[CallKit] provider perform call start: \(action.callUUID).", subsystems: .call)
        
        Task { @MainActor [weak self] in
            guard let self else {
                action.fail()
                return
            }
            
            guard let currentCall = await state.currentCall, await currentCall.uuid == action.callUUID else {
                log.debug("[CallManager] failed to perform start call action", subsystems: .call)
                action.fail()
                return
            }
            
            let isVideo = await currentCall.details.isVideo ?? false
            let details = await currentCall.details
            ErmisCallAudioManager.shared.configureAudioSession(isIncomingCall: false, isVideoCall: isVideo)

            let title = details.title
            reportUpdateCall(for: action.callUUID, localizedCallName: title)
//            callProvider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())

            pendingTasks.append(
                Task.detached(priority: .userInitiated) { [weak self] in
                    do {
                        guard !Task.isCancelled else {
                            return
                        }
                        try await currentCall.createCall()
                    } catch {
                        if Task.isCancelled {
                            return
                        }
                        self?.messagePublisher.send(.createOutgoingCallError(uuid: action.callUUID, error: error))
                        await self?.onCallEnded(currentCall)
                    }
                }
            )
            action.fulfill()
            await currentCall.setState(.reported)
        }
    }

    @MainActor
    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        log.debug("[CallManager] provider(_:perform:) called with CXAnswerCallAction, uuid: \(action.callUUID)", subsystems: .call)
        log.debug("[CallKit] provider perform call answer: \(action.callUUID).", subsystems: .call)
        
        let isMicrophoneAccessGranted = ioAccessManager.isMicrophoneAccessGranted
        guard isMicrophoneAccessGranted else {
            CallManager.needShowRequestMicrophoneAccessAlert = true
            Task { @MainActor [weak self] in
                if let details = await self?.state.currentCall?.details {
                    log.debug("[CallManager] Microphone access denied, ending call with callId: \(details.callId)", subsystems: .call)
                    self?.endCall(with: details.callId)
                }
            }
            action.fulfill()
            return
        }

        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self, !Task.isCancelled else {
                action.fulfill()
                return
            }
            
            let currentCall = await state.currentCall

            do {
                guard let currentCall else {
                    throw ClientError("Current call is nil.")
                }
                delegate?.callManager(self, didAccept: currentCall)
                log.debug("[CallKit] Answering call")
                log.debug("[CallKit] Connecting socket...")
                try await connectionSocket()
                log.debug("[CallKit] Connected socket")
                log.debug("[CallKit] Send accepted call signal")
                try await currentCall.acceptCall()
                log.debug("[CallKit] Send accepted call signal success.")
                // Wait until call connected.
                var retryCount = 0
                while await state.currentCall?.details.state != .connected {
                    guard !Task.isCancelled else {
                        log.debug("[CallKit] TASK CANCELED")
                        action.fail()
                        return
                    }
                    log.debug("[CallKit] WAITING FOR CONNECT")
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                action.fulfill(withDateConnected: Date())
                log.debug("[CallKit] FULFIL ANSWER ACTION")
            } catch(let error) {
                log.debug("[CallKit] provider perform call answer failed with error: \(error)", subsystems: .call)
                action.fail()
                guard let currentCall, await currentCall.isCallWithId(action.callUUID.uuidString) else {
                    log.warning("[CallManager] perform answercall, end call but call not found with uuid: \(action.callUUID)", subsystems: .call)
                    return
                }
                await state.insertEndingCallUUID(currentCall.uuid)
                try? await currentCall.endCall()
                let details = await currentCall.details
                messagePublisher.send(.failedToConnect(uuid: details.uuid,
                                                       error: ClientError("Can't connect call")))
                await performCallCleanUp(currentCall)
            }
        }
        pendingTasks.append(task)
    }

    @MainActor
    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        log.debug("[CallManager] provider(_:perform:) called with CXEndCallAction, uuid: \(action.callUUID)", subsystems: .call)
        log.debug("[CallManager] Perform end call action.", subsystems: .call)
        
        Task { @MainActor [weak self] in
            guard let self else {
                action.fulfill()
                return
            }
            
            guard let currentCall = await state.currentCall, await currentCall.uuid == action.callUUID else {
                log.debug("[CallManager] End call action called with uuid not matching currentCall, fulfilling immediately.", subsystems: .call)
                action.fulfill()
                return
            }
            
            self.pendingTasks.forEach({ $0.cancel()})
            
            if await state.isEndingCallUUIDsEmpty() {
                currentCall.callNodeClient.preStop()
                Task.detached(priority: .userInitiated) {
                    await self.sendEndCallNotification(currentCall.details.callId,
                                            callUUID: currentCall.details.uuid,
                                            cid: currentCall.details.cid)
                    await self.performCallCleanUp(currentCall)
                }
            }
            action.fulfill()
        }
    }

    @MainActor
    public func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        log.debug("[CallManager] provider(_:perform:) called with CXSetHeldCallAction, uuid: \(action.callUUID)", subsystems: .call)
        log.debug("[CallKit] provider did perform held call: \(action.callUUID).", subsystems: .call)
        action.fulfill()
    }

    @MainActor
    public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        log.debug("[CallManager] provider(_:perform:) called with CXSetMutedCallAction, uuid: \(action.callUUID), isMuted: \(action.isMuted)", subsystems: .call)
        log.debug("[CallKit] provider did perform muted call: \(action.callUUID).", subsystems: .call)
        
        Task { @MainActor [weak self] in
            guard let self else {
                action.fail()
                return
            }
            
            let currentCall = await state.currentCall
            do {
                try await currentCall?.setMute(action.isMuted)
                action.fulfill()
            } catch let error {
                log.debug("[CallManager] Failed to set mute state with error: \(error)", subsystems: .call)
                action.fail()
            }
        }
    }
    
    @MainActor
    public func provider(_ provider: CXProvider, perform action: CXSetGroupCallAction) {
        log.debug("[CallManager] provider(_:perform:) called with CXSetGroupCallAction, uuid: \(action.callUUID)", subsystems: .call)
        log.debug("[CallKit] provider did perform set group call: \(action.callUUID).", subsystems: .call)
        action.fulfill()
    }

    @MainActor
    public func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
        log.debug("[CallManager] provider(_:perform:) called with CXPlayDTMFCallAction, uuid: \(action.callUUID)", subsystems: .call)
        log.debug("[CallKit] provider did perform play dtmf call: \(action.callUUID).", subsystems: .call)
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        log.error("[CallManager] provider(_:timedOutPerforming:) called with action: \(action)", subsystems: .call)
        Task {
            if let action = action as? CXStartCallAction {
                if let currentCall = await state.currentCall {
                    await state.insertEndingCallUUID(currentCall.uuid)
                    let details = await currentCall.details
                    messagePublisher.send(.createOutgoingCallError(uuid: action.callUUID,
                                                                   error: ClientError("Can't start outgoing call.")))
                    await onCallEnded(currentCall)
                }
            } else if let action = action as? CXAnswerCallAction {
                if let currentCall = await state.currentCall {
                    await state.insertEndingCallUUID(currentCall.uuid)
                    let details = await currentCall.details
                    messagePublisher.send(.failedToConnect(uuid: details.uuid,
                                                           error: ClientError("Can't connect call")))
                    await performCallCleanUp(currentCall)
                }
            } else if let action = action as? CXEndCallAction {
//                if let currentCall = await state.currentCall {
//                    await self.sendEndCallNotification(currentCall.details.callId,
//                                                       callUUID: currentCall.details.uuid,
//                                                       cid: currentCall.details.cid)
//                    await self.performCallCleanUp(currentCall)
//                }
            }
        }

    }

    @MainActor
    public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        log.debug("[CallManager] provider(_:didActivate:) called with audioSession", subsystems: .call)
        log.debug("[CallKit] provider did activate audio session.", subsystems: .call)
        
        Task { @MainActor [weak self] in
            log.debug("[Call] Did activate audio session start.", subsystems: .call)
            guard let self else { return }
            let currentCall = await state.currentCall
            await currentCall?.didActiveAudioSession()
            await playRingingSoundIfNeeded()
        }
    }

    @MainActor
    public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        log.debug("[CallManager] provider(_:didDeactivate:) called with audioSession", subsystems: .call)
        log.debug("[CallKit] provider did reset audio session.", subsystems: .call)
        
        Task { @MainActor [weak self] in
            guard let self else { return }
            let currentCall = await state.currentCall
            await currentCall?.didDeactiveAudioSession()
        }
    }

    // MARK: - PushRegistry
    public func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        let deviceToken = pushCredentials.token.reduce("", { $0 + String(format: "%02X", $1) })
        client?.currentUserController().setDeviceToken(deviceToken: deviceToken) { error in
            if let error {
                log.error("adding a device failed with an error \(error)", subsystems: .call)
            }
        }
    }

    public func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) throws {
        log.debug("[CallManager] pushRegistry(_:didReceiveIncomingPushWith:for:completion:) called with payload: \(payload.dictionaryPayload)", subsystems: .call)
        log.debug("[CallKit] Received incoming call with payload: \(payload.dictionaryPayload)", subsystems: .call)
        
        guard let client else {
            log.error("[CallManager] Client is nil, reporting fallback call", subsystems: .call)
            throw ClientError("Client is not avaiable.")
        }

        let callSignalEvent = try client.handelPushKitPayload(payload.dictionaryPayload)

//        // Reject call if has other ongoing call.
//        if let currentCall,
//           await currentCall.details.callId != callSignalEvent.callId,
//           await currentCall.details.state != .ended, endingUUIDs.isEmpty {
//            let uuid = UUID()
//            let callUpdate = CXCallUpdate()
//            callUpdate.hasVideo = callSignalEvent.isVideo ?? false
//            callUpdate.supportsDTMF = false
//            callUpdate.supportsHolding = false
//            callUpdate.supportsGrouping = false
//            callUpdate.supportsUngrouping = false
//            callUpdate.localizedCallerName = callSignalEvent.channel.name ??
//            callSignalEvent.channel.directUserMembership?.name ??
//            callSignalEvent.channel.cid.rawValue ?? "Unknown"
//            do {
//                // Report to CallKit immediately - this is required
//                try await self.callProvider.reportNewIncomingCall(with: uuid, update: callUpdate)
//                callReported = true
//                // Then immediately end it since we're rejecting - report as answered elsewhere
//                self.callProvider.reportCall(with: uuid, endedAt: Date(), reason: .answeredElsewhere)
//                log.debug("[CallManager] Rejected incoming call due to ongoing call", subsystems: .call)
//            } catch let error {
//                log.error("[CallManager] Failed to report/reject busy call: \(error)", subsystems: .call)
//            }
//            return
//        }

        // Reduce wait time to avoid CallKit timeout - max 1 second instead of 3
//        var retryCount = 0
//        while await !self.state.isEndingCallUUIDsEmpty() && retryCount < 10 {
//            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
//            retryCount += 1
//        }

        // Report call immediately - don't wait any longer
        self.reportIncommingCall(callSignalEvent, completion: completion)
    }

    public func reportFakeCall(completion: @escaping () -> Void) {
        let uuid = UUID()
        let update = CXCallUpdate()
        update.localizedCallerName = "Unknown Caller" // Or "Missed Call"

        // You MUST report the call to stay alive

        callProvider.reportNewIncomingCall(with: uuid, update: update) { error in
            completion()
            if error == nil {
                let endAction = CXEndCallAction(call: uuid)
                let transaction = CXTransaction(action: endAction)
                self.callController.request(transaction) { _ in

                }
            }
        }
    }

    // MARK: - CXCallObserverDelegate
    public func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        log.debug("[CallManager] callObserver(_:callChanged:) called for call UUID: \(call.uuid), ended: \(call.hasEnded), connected: \(call.hasConnected)", subsystems: .call)
        
        Task { @MainActor [weak self] in
            await self?.state.updateHistoryCallState(call)
        }
    }

    // MARK: - Others
    public func ensureWebsocketConnected() async -> Bool {
        log.debug("[CallManager] ensureWebsocketConnected() ENTRY, status: \(client.connectionStatus)", subsystems: .call)
        if client.connectionStatus == .connected {
            log.debug("[CallManager] Already connected, returning true", subsystems: .call)
            return true
        }
        log.debug("[CallManager] Calling connectionController.connect", subsystems: .call)
        return await withCheckedContinuation { continuation in
            self.connectionController.connect { [weak self] error in
                log.debug("[CallManager] connectionController.connect callback, error: \(String(describing: error))", subsystems: .call)
                if let error, self?.client.connectionStatus != .connected {
                    continuation.resume(returning: false)
                } else {
                    continuation.resume(returning: true)
                }
            }
        }
    }

    public func resetValue() async {
        log.warning("[CallManager] resetValue() called - resetting all values.", subsystems: .call)
//        
//        let beforeIsIdle = await state.isIdle
//        let beforeIsReported = await state.isCallKitReportedCall
//        let beforeIsReady = await state.isCallKitReady
//        let beforeLastEnded = await state.lastCallEndedTime
//        let beforeUUIDCount = await state.callUUIDDictionary.count
//        let beforeEndingCount = await state.endingCallUUIDs.count
//        let beforeHasCall = await state.currentCall != nil
//        
//        log.debug("[CallManager] BEFORE reset: isIdle: \(beforeIsIdle), isCallKitReportedCall: \(beforeIsReported), isCallKitReady: \(beforeIsReady), lastCallEndedTime: \(String(describing: beforeLastEnded)), callUUIDDictionary count: \(beforeUUIDCount), endingCallUUIDs count: \(beforeEndingCount), currentCall exists: \(beforeHasCall)", subsystems: .call)
//        
        await state.resetAllState()
//        
//        let afterIsIdle = await state.isIdle
//        let afterIsReported = await state.isCallKitReportedCall
//        let afterIsReady = await state.isCallKitReady
//        let afterLastEnded = await state.lastCallEndedTime
//        let afterUUIDCount = await state.callUUIDDictionary.count
//        let afterEndingCount = await state.endingCallUUIDs.count
//        let afterHasCall = await state.currentCall != nil
//        
//        log.debug("[CallManager] AFTER reset: isIdle: \(afterIsIdle), isCallKitReportedCall: \(afterIsReported), isCallKitReady: \(afterIsReady), lastCallEndedTime: \(String(describing: afterLastEnded)), callUUIDDictionary count: \(afterUUIDCount), endingCallUUIDs count: \(afterEndingCount), currentCall exists: \(afterHasCall)", subsystems: .call)
    }

    private func resetCallKitIfNeeded() async {
        log.debug("[CallManager] resetCallKitIfNeeded() called", subsystems: .call)
        let hasCurrentCall = await state.currentCall != nil
        if !hasCurrentCall, callController.callObserver.calls.contains(where: { !$0.hasEnded }) {
            resetCallKit()
        }
    }

    private func resetCallKit() {
        log.warning("[CallManager] resetCallKit() called - Force reseting callkit", subsystems: .call)
        log.debug("[CallManager] pending transaction\(callProvider.pendingTransactions)")
        callProvider.invalidate()
        let providerConfig = CXProviderConfiguration()
        providerConfig.supportsVideo = true
        providerConfig.supportedHandleTypes = [.generic]
        providerConfig.maximumCallsPerCallGroup = 1
        providerConfig.maximumCallGroups = 1
        providerConfig.ringtoneSound = "ringback.mp3"
        providerConfig.includesCallsInRecents = true
        callProvider = CXProvider(configuration: providerConfig)
        callController = CXCallController()
        //
        self.callProvider.setDelegate(self, queue: callKitQueue)
        self.callController.callObserver.setDelegate(self, queue: callKitQueue)
    }
}
// MARK: - EventsControllerDelegate
extension CallManager: EventsControllerDelegate {
    public func eventsController(_ controller: EventsController, didReceiveEvent event: any Event) {
        if let event = event as? CallSignalEvent {
            Task { @MainActor [weak self] in
                guard let self else { return }
                
                let isCurrentUser = event.userId == client.currentUserId
                let isCurrentDevice = event.sessionId == self.sessionId
                let callUUID = await getCallUUID(for: event.callId)
                let isCurrentCall = await state.hasCallWithId(event.callId)
                
                log.debug("""
[CallManager] Call manager received event: 
- Event: CallAction: \(event.callAction)
- UUID: \(String(describing: callUUID))
- Action: \(event.callAction)
- Other: Is currentUser: \(isCurrentUser), isCurrentDevice: \(isCurrentDevice), is currentCall: \(isCurrentCall)
""", subsystems: .call)

                if isCurrentCall && isCurrentDevice {
                    log.debug("[CallManager] Receive call event from self, skip.")
                    return
                }
                
                switch event.callAction {
                case .createCall:
                    if isCurrentCall, isCurrentDevice {
                        if let currentCall = await state.currentCall {
                            let channelName = event.channel.name ??
                            event.channel.directUserMembership?.name ??
                            event.channel.cid.rawValue ?? "Unknown"
                            await reportUpdateCall(for: currentCall.details.uuid,
                                             localizedCallName: channelName,
                                             hasVideo: event.isVideo)
                        }
                    }
                    if !isCurrentUser {
//                        // Voip come before, so ignore this signal.
//                        if await state.callUUIDDictionaryContains(callId: event.callId) {
//                            return
//                        }
//                        // Wait for ending calls to complete using proper async check
//                        Task {
//                            var retryCount = 0
//                            while await !self.state.isEndingCallUUIDsEmpty() && retryCount < 50 {
//                                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
//                                retryCount += 1
//                            }
//                            await self.reportIncommingCall(event)
//                        }
                    }
                case .acceptCall:
                    // Call answer from other device.
                    if isCurrentUser, !isCurrentDevice, isCurrentCall {
                        clearCall(event.callId, with: .answeredElsewhere)
                    } else if !isCurrentUser, isCurrentCall {
                        if let currentCall = await state.currentCall, await currentCall.isLocalId == true {
                            await currentCall.setRemoteCallId(event.callId)
                        }
                        await reportOutgoingCallStartConnecting(event)
                    }
                case .signalCall:
                    break
                case .endCall:
                    if isCurrentCall {
                        clearCall(event.callId, with: .remoteEnded)
                    }
                case .missCall:
                    if isCurrentCall, !isCurrentUser {
                        clearCall(event.callId, with: .unanswered)
                        sendMissedCallNotification(event)
                    } else if isCurrentCall, isCurrentUser {
                        clearCall(event.callId, with: .unanswered)
                    }
                case .rejectCall:
                    if isCurrentCall, isCurrentUser {
                        if isCurrentDevice {
                            clearCall(event.callId, with: .unanswered)
                        } else {
                            clearCall(event.callId, with: .declinedElsewhere)
                        }
                    } else if isCurrentCall, !isCurrentUser {
                        clearCall(event.callId, with: .remoteEnded)
                    }
                default:
                    break
                }
            }
        }
    }
}

