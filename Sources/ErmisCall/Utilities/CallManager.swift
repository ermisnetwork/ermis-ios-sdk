//
// Copyright 2025 Ermis Inc.
//

import Foundation
import ErmisChat
import PushKit
import CallKit
import AVFAudio
import UIKit

public protocol CallManagerDelegate: AnyObject {
    func callManager(_ manager: CallManager, didAccept call: Call?)
}

public class CallManager: NSObject, CXProviderDelegate {
    public static let shared = CallManager()
    
    public var sessionId = UUID().uuidString.lowercased()
    var client: ErmisClient!
    var callProvider :CXProvider
    let callController: CXCallController
    var calls: [Call] = []
    var callUUIDDictionary: [String: UUID] = [:]
    lazy var  eventsController = client.eventsController()
    public lazy var ioAccessManager = IOAccessManager()
    /// Return current active call.
    public var currentCall: Call? {
        return calls.last(where: { $0.details.state != .ended })
    }

    public weak var delegate: CallManagerDelegate?

    public var pendingTasks: [Task<Void, Never>] = []
    public var endingCallUUIDs = Set<UUID>()

    public static var needShowRequestMicrophoneAccessAlert: Bool {
        get {
            UserDefaults.standard.bool(forKey: "callKit.microphoneAccessDenied")
        }

        set {
            UserDefaults.standard.setValue(newValue, forKey: "callKit.microphoneAccessDenied")
        }
    }

    lazy var onCallEnded: ((Call?) -> Void) = { [weak self] call in
        defer {
            self?.callUUIDDictionary.removeAll()
            self?.endingCallUUIDs.removeAll()
            self?.calls.removeAll()
//            self?.calls.removeAll(where: { $0.details.callId == call.details.callId })
//            self?.calls.removeAll(where: { $0.details.state == .ended })
        }
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        guard let call else { return }
        self?.sendEndCallNotification(call)
        try? call.audioManager.didDeactivateAudioSession()

    }

    override init() {
        let providerConfig = CXProviderConfiguration()
        providerConfig.supportsVideo = true
        providerConfig.supportedHandleTypes = [.generic]
        providerConfig.maximumCallsPerCallGroup = 1
        providerConfig.maximumCallGroups = 1
        providerConfig.ringtoneSound = "ringback.mp3"

        callProvider = CXProvider(configuration: providerConfig)
        callController = CXCallController()
        super.init()
        self.callProvider.setDelegate(self, queue: nil)
    }

    public func config(with client: ErmisClient?) {
        self.client = client
        // Register push registry
        eventsController.delegate = self
    }

    // MARK: - Create call
    /// Creates a new  outgoing call in the given channel.
    ///
    /// - Parameters:
    ///   - channelId: The channel identifier
    ///   - isVideoCall: A boolean value detect this call is video call or audio call.
    ///
    /// - Returns: New outgoing call.
    public func createNewOutgoingCall(in channelId: ChannelId, isVideoCall: Bool) -> Call? {
        if let currentCall, currentCall.details.cid == channelId {
            return currentCall
        } else if let currentCall {
            return nil
        }

        let uuid = UUID()
        guard let call = Call(sessionId: sessionId,
                        uuid: uuid,
                        callId: uuid.uuidString,
                        cid: channelId,
                        client: client,
                        isVideo: isVideoCall,
                              isIncoming: false) else {
            log.debug("[Call] Failed to create new call with uuid: \(uuid.uuidString)", subsystems: .call)
            
            return nil
        }
        addCall(call)
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
    public func createNewIncomingCall(from event: CallSignalEvent, uuid: UUID) {
        guard let call = Call(sessionId: sessionId,
                        uuid: uuid,
                        callId: event.callId,
                        cid: event.cid,
                        client: client,
                        isVideo: event.isVideo ?? false,
                              isIncoming: true) else {
            log.debug("[Call] Failed to create new incoming call with uuid: \(uuid.uuidString)", subsystems: .call)
            forceEndcall()
            return
        }
        call.callNodeClient.call?.callNodeClient.remoteAddress = event.metadata?.address
        pendingTasks.append(Task {
            await try? call.connectionSocket()
        })
        addCall(call)
    }

    // MARK: - Call

    /// Get call in channel.
    ///
    /// - Parameters:
    ///   - cid: The channel identifier.
    ///
    /// - Returns: The call in given channel. Return nil if not exist call in this channel.
    public func call(in cid: ChannelId) -> Call? {
        return calls.first { $0.details.cid == cid && $0.details.state != .ended }
    }

    /// Get call with call identifier.
    ///
    /// - Parameters:
    ///   - callId: The call identifier.
    ///
    /// - Returns: The call with given identifier. Return nil if the call is not exist.
    public func call(with callId: String) -> Call? {
        return calls.first { $0.details.callId == callId }
    }


    func call(with uuid: UUID) -> Call? {
        return calls.first(where: { $0.details.uuid == uuid })
    }

    func getCallUUID(for callId: String) -> UUID? {
        return callUUIDDictionary[callId]
    }

    /// Add new call if not exist.
    func addCall(_ call: Call) {
        if !call.isLocalId {
            callUUIDDictionary[call.details.callId] = call.details.uuid
        }
//        calls.removeAll(where: { $0.details.state == .ended })
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        guard self.call(with: call.details.uuid) == nil else {
            return
        }
        log.debug("callUUIDDictionary: \(callUUIDDictionary)", subsystems: .call)
        log.debug("[Call] Current calls: \(self.calls.map(\.details.callId))", subsystems: .call)
        log.debug("[Call] Add new call: \(call.details.callId)", subsystems: .call)
        self.calls.append(call)
    }

    // Remove current call without send ending signal.
    func removeCall(_ call: Call?, with reason: CXCallEndedReason) {
        log.warning("[Call] Remove call: \(call?.details.callId), reason: \(reason)", subsystems: .call)
        guard let call, endingCallUUIDs.isEmpty else {
            return
        }
        endingCallUUIDs.insert(call.details.uuid)
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = false
        }

        callProvider.reportCall(with: call.details.uuid, endedAt: Date(), reason: reason)
        Task(priority: .high) { [weak self] in
            try? await call.close()
            onCallEnded(call)
        }
    }

    /// End the call with given identifier.
    ///
    /// - Parameters:
    ///   - callId: The call identifier.
    public func endCall(with callId: String) {
        guard let call = call(with: callId), endingCallUUIDs.isEmpty else {
            return
        }
        endingCallUUIDs.insert(call.details.uuid)
        Task(priority: .high) { [weak self] in
            guard let self else {
                return
            }
            self.pendingTasks.forEach({ $0.cancel()})
            await endCall(call)
        }
    }

    func endCall(_ call: Call?) async {
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        guard let call else {
            return
        }
        log.debug("[CallKit] endcall with UUID: \(call.details.uuid)", subsystems: .call)
        let endAction = CXEndCallAction(call: call.details.uuid)

        let transaction = CXTransaction()
        transaction.addAction(endAction)
        requestTransaction(transaction, completion: { [weak self] error in
            if let error {
                // Force ended call
                self?.forceEndcall()

            }
        })
    }

    func forceEndcall() {
        guard let currentCall else {
            return
        }
        self.callProvider.reportCall(with: currentCall.details.uuid, endedAt: Date(), reason: .failed)
        onCallEnded(currentCall)
    }

    func sendEndCallNotification(_ call: Call) {
        NotificationCenter.default.post(name: .callDidEnded,
                                        object: self,
                                        userInfo: [
                                            "call_id": call.details.callId,
                                            "cid": call.details.cid
                                        ]
        )
    }

    func sendMissedCallNotification(_ callSignalEvent: CallSignalEvent) {
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
                    log.error("[Ermis Call] Failed to send missed call notification: \(error)", subsystems: .call)
                }
            }
        }
    }
    // MARK: - Report call events.
    /// Report new incomming call to `CallKit`
    package func reportIncommingCall(_ event: CallSignalEvent?, completion: @escaping (Error?) -> Void) {
        log.debug("[ErmisCall] Report incomming call: \(String(describing: event))", subsystems: .call)
        let callUpdate = CXCallUpdate()
        callUpdate.hasVideo = event?.isVideo ?? false
        callUpdate.supportsDTMF = false
        callUpdate.supportsHolding = false
        callUpdate.supportsGrouping = false
        callUpdate.supportsUngrouping = false
        callUpdate.localizedCallerName = event?.channel.name ??
        event?.channel.directUserMembership?.name ??
        event?.channel.cid.rawValue ?? "Unknown"

        var callUUID = UUID()
        if let event, let call = call(with: event.callId) {
            callUUID = call.details.uuid
        } else if let event {
            createNewIncomingCall(from: event, uuid: callUUID)
        }

        callUpdate.remoteHandle = CXHandle(type: .generic, value: event?.cid.rawValue ?? callUUID.uuidString)
        callProvider.reportNewIncomingCall(with: callUUID, update: callUpdate, completion: { [unowned self] error in
            if let error {
                log.error("[PushKit] Failed to report incoming call: \(error.localizedDescription)", subsystems: .call)
            } else {
                ErmisCallAudioManager.shared.configureAudioSession(isIncomingCall: true, isVideoCall: callUpdate.hasVideo)
                currentCall?.setState(.ringing)
                log.debug("[PushKit] Reported incoming call: \(callUUID.uuidString)", subsystems: .call)
            }
            completion(error)
        })
    }

    package func reportOutgoingCallStarted(_ call: Call) {
        log.debug("[PushKit] Report outgoing call: \(call.details.uuid)", subsystems: .call)
        let handle = CXHandle(type: .generic, value: call.details.cid.rawValue)
        var startCallAction = CXStartCallAction(call: call.details.uuid, handle: handle)
        startCallAction.isVideo = call.details.isVideo
        let transaction = CXTransaction()
        transaction.addAction(startCallAction)
        requestTransaction(transaction, completion: { _ in })
    }

    package func reportUpdateCall(for callUUID: UUID, localizedCallName: String? = nil, hasVideo: Bool? = nil) {
        log.debug("[PushKit] Report call update: \(callUUID)", subsystems: .call)
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

    package func reportOutgoingCallStartConnecting(_ event: CallSignalEvent?) {
        log.debug("[CallKit] Report outgoing call start connecting: \(String(describing: event))", subsystems: .call)
        var callUUID = UUID()
        if let event, let call = call(with: event.callId) {
            callUUID = call.details.uuid
        }
        callUUIDDictionary[event?.callId ?? callUUID.uuidString] = callUUID
        callProvider.reportOutgoingCall(with: callUUID, startedConnectingAt: event?.createdAt)
    }

    package func reportOutgoingCallConnected(uuid: UUID?, connectedAt connectedDate: Date?) {
        guard let uuid else {
            return
        }
        callProvider.reportOutgoingCall(with: uuid, connectedAt: connectedDate)
        log.debug("[CallKit] Report outgoing call \(uuid.uuidString) connected at: \(connectedDate)", subsystems: .call)
    }

    /// Report call ended to callkit, this will stop ringging. Often use when other device answer or end call.
    package func reportCallEnded(_ event: CallSignalEvent, reason: CXCallEndedReason) {
        guard let uuid = getCallUUID(for: event.callId) else {
            return
        }
        callProvider.reportCall(with: uuid, endedAt: event.createdAt, reason: reason)
        log.debug("[CallKit] Request call ended \(uuid.uuidString) reason: \(String(describing: reason))", subsystems: .call)
    }

    private func requestTransaction(_ transaction: CXTransaction, completion: @escaping (Error?) -> Void) {
        callController.request(transaction) { error in
            if let error {
                log.error("[CallKit] Request transaction failed: \(error.localizedDescription)", subsystems: .call)
            } else {
                log.debug("[CallKit] Request transaction succeeded", subsystems: .call)
            }
            completion(error)
        }
    }

    // MARK: - Ringing audio
    func playRingingSoundIfNeeded() {
        guard currentCall?.details.isIncoming == false, currentCall?.details.state == .ringing else {
            return
        }
        guard let url = Bundle.ermisCall.url(forResource: "ringback", withExtension: "mp3") else {
            return
        }
        RingingAudioPlayer.shared.playSound(at: url,
                                            vibrate: false,
                                            useBuiltInReceiver: currentCall?.details.isVideo == false)
    }

    func stopPlayingRingingSound() {
        guard currentCall?.details.isIncoming == false else {
            return
        }
        RingingAudioPlayer.shared.stopPlaying(false)
    }
    // MARK: - CXProviderDelegate
    public func providerDidBegin(_ provider: CXProvider) {
        log.debug("[CallKit] Provider did begin.", subsystems: .call)
        let providerConfig = CXProviderConfiguration()
        providerConfig.supportsVideo = true
        providerConfig.supportedHandleTypes = [.generic]
        providerConfig.maximumCallsPerCallGroup = 1
        providerConfig.maximumCallGroups = 1
        providerConfig.ringtoneSound = "ringback.mp3"

        callProvider.configuration = providerConfig
    }

    public func providerDidReset(_ provider: CXProvider) {
        log.debug("[CallKit] provider did reset.", subsystems: .call)
    }

    public func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        log.debug("[CallKit] provider perform call start: \(action).", subsystems: .call)
        ErmisCallAudioManager.shared.configureAudioSession(isIncomingCall: false, isVideoCall: currentCall?.details.isVideo ?? false)
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        log.debug("[CallKit] provider perform call answer: \(action).", subsystems: .call)
        let isMicrophoneAccessGranted = ioAccessManager.isMicrophoneAccessGranted
        guard isMicrophoneAccessGranted else {
            CallManager.needShowRequestMicrophoneAccessAlert = true
            if let currentCall {
                Task(priority: .high) {
                    await CallManager.shared.endCall(currentCall)
                }
            }
            action.fulfill()
            return
        }
//        ErmisCallAudioManager.shared.configureAudioSession(isIncomingCall: true, isVideoCall: currentCall?.details.isVideo ?? false)

        let task = Task { [weak self] in
            guard let self, !Task.isCancelled else {
                action.fulfill()
                return
            }
            do {
                delegate?.callManager(self, didAccept: currentCall)
                log.debug("[CallKit] Answering call")
                log.debug("[CallKit] Connecting socket...")
                try await currentCall?.connectionSocket()
                log.debug("[CallKit] Connected socket")
                log.debug("[CallKit] Send accepted call signal")
                try await currentCall?.acceptCall()
                log.debug("[CallKit] Send accepted call signal success.")
                // Wait until call connected.
                while currentCall?.details.state != .connected {
                    guard !Task.isCancelled else {
                        log.debug("[CallKit] TASK CANCELED")
                        return
                    }
                    log.debug("[CallKit] WAITING FOR CONNECT")
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                action.fulfill(withDateConnected: Date())
                log.debug("[CallKit] FULFIL ANSWER ACTION")
            } catch(let error) {
                log.debug("[CallKit] provider perform call answer failed with erorr: \(error)", subsystems: .call)
                action.fulfill()
                if let currentCall {
                    Task(priority: .high) {
                        await endCall(currentCall)
                    }
                }
            }
        }
        pendingTasks.append(task)
    }

    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        log.debug("[CallKit] provider perform end call: \(action).", subsystems: .call)
        guard let currentCall = calls.first(where: { $0.details.uuid == action.callUUID}) else {
            log.warning("[CallKit] provider perform end call: call not found", subsystems: .call)
            return
        }

        Task(priority: .high) { [weak self] in
            guard let self else {
                return
            }
            do {
                if currentCall.details.state.isConnected || currentCall.isMissed {
                    try await currentCall.endCall()
                    onCallEnded(currentCall)
                    action.fulfill()
                } else {
                    log.debug("[Call] Reject call when Perform end call action \(currentCall.details.callId) - call counts: \(calls.count)", subsystems: .call)
                    try await currentCall.rejectCall()
                    onCallEnded(currentCall)
                    action.fulfill()
                }
            } catch let error {
                onCallEnded(currentCall)
                action.fulfill()
            }
        }
    }

    public func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        log.debug("[CallKit] provider did perform held call: \(action).", subsystems: .call)
    }

    public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        log.debug("[CallKit] provider did perform muted call: \(action).", subsystems: .call)
        Task(priority: .high) {
            do {
                try await currentCall?.setMute(action.isMuted)
                action.fulfill()
            } catch let error {
                action.fail()
            }
        }
    }
    //
    public func provider(_ provider: CXProvider, perform action: CXSetGroupCallAction) {
        log.debug("[CallKit] provider did perform set group call: \(action).", subsystems: .call)
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
        log.debug("[CallKit] provider did perform play dtmf call: \(action).", subsystems: .call)
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        log.debug("[CallKit] provider did time out performing: \(action).", subsystems: .call)
        Task {
            do {
                try await currentCall?.endCall()
                onCallEnded(currentCall)
                action.fulfill()
            } catch let error {
                action.fulfill()
            }
        }
    }

    public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        log.debug("[CallKit] provider did activate audio session.", subsystems: .call)
        currentCall?.didActiveAudioSession()
        playRingingSoundIfNeeded()
    }

    public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        log.debug("[CallKit] provider did reset audio session.", subsystems: .call)
        currentCall?.didDeactiveAudioSession()
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

    public func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        guard type == .voIP else { return }
        log.debug("[PushKit] Received incoming call with payload: \(payload.dictionaryPayload)", subsystems: .call)

        guard let client else {
            reportIncommingCall(.none, completion: { _ in
                completion()
            })
            return
        }

        client.handelPushKitPayload(payload.dictionaryPayload) { [unowned self] result in
            log.debug("[Call] Handle pushkit payload result: \(result)", subsystems: .call)
            switch result {
            case .success(let callSignalEvent):
                // Reject call if has other ongoing call.
                if let currentCall, currentCall.details.callId != callSignalEvent.callId, currentCall.details.state != .ended, endingCallUUIDs.isEmpty {
                    let uuid = UUID()
                    let callUpdate = CXCallUpdate()
                    callUpdate.hasVideo = callSignalEvent.isVideo ?? false
                    callUpdate.supportsDTMF = false
                    callUpdate.supportsHolding = false
                    callUpdate.supportsGrouping = false
                    callUpdate.supportsUngrouping = false
                    callUpdate.localizedCallerName = callSignalEvent.channel.name ??
                    callSignalEvent.channel.directUserMembership?.name ??
                    callSignalEvent.channel.cid.rawValue ?? "Unknown"
                    self.callProvider.reportNewIncomingCall(with: uuid, update: callUpdate) { error in
                        if error == nil {
                            self.callProvider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
                        }
                    }
                    return
                } else if !endingCallUUIDs.isEmpty {
                    onCallEnded(currentCall)
                }
                reportIncommingCall(callSignalEvent, completion: { _ in
                    completion()
                })
            case .failure(let error):
                log.error("[PushKit] Cannot handle pushkit payload: \(error)", subsystems: .call)
                reportIncommingCall(.none, completion: { _ in
                    completion()
                })
                completion()
            }
        }
    }
}
// MARK: - EventsControllerDelegate
extension CallManager: EventsControllerDelegate {
    public func eventsController(_ controller: EventsController, didReceiveEvent event: any Event) {
        if let event = event as? CallSignalEvent {
            let isCurrentUser = event.userId == client.currentUserId
            let isCurrentDevice = event.sessionId == self.sessionId
            let callUUID = getCallUUID(for: event.callId)
            let isCurrentCall = event.callId == currentCall?.details.callId
            log.debug("""
[CallKit] Call manager received event: 
- UUID: \(callUUID)
- Action: \(event.callAction)
- Other: Is currentUser: \(isCurrentUser), isCurrentDevice: \(isCurrentDevice), is currentCall: \(isCurrentCall)
""", subsystems: .call)
            switch event.callAction {
            case .createCall:
                if isCurrentCall, isCurrentDevice, let currentCall {
                    let channelName = event.channel.name ??
                    event.channel.directUserMembership?.name ??
                    event.channel.cid.rawValue ?? "Unknown"
                    reportUpdateCall(for: currentCall.details.uuid,
                                     localizedCallName: channelName,
                                     hasVideo: event.isVideo)
                }
                if !isCurrentUser {
                    // Voip come before, so ignore this signal.
                    guard !callUUIDDictionary.contains(where: { $0.key == event.callId }) else {
                        return
                    }
                     reportIncommingCall(event, completion: { _ in })
                }
            case .acceptCall:
                // Call answer from other device.
                if isCurrentUser, !isCurrentDevice {
                    // TODO: - Find other way to make call history
//                    reportIncommingCall(event, completion: { _ in })
                    removeCall(currentCall, with: .answeredElsewhere)
                } else if !isCurrentUser, isCurrentCall {
                    if let currentCall, currentCall.isLocalId == true {
                        currentCall.setRemoteCallId(event.callId)
                    }
                    reportOutgoingCallStartConnecting(event)
                }
            case .signalCall:
                // If revice call signal in not valid state --> Close
                guard let currentCall else {
                    return
                }
                switch event.signal?.type {
                case .ice:
                    if currentCall.details.state != .ringing,
                       currentCall.details.state != .connecting,
                       currentCall.details.state != .connected {
                        removeCall(currentCall, with: .answeredElsewhere)
                    }
                case .offer, .answer:
                    if currentCall.details.state != .ringing,
                       currentCall.details.state != .connecting,
                       currentCall.details.state != .connected {
                        removeCall(currentCall, with: .answeredElsewhere)
                    }
                default:
                    break
                }
            case .endCall:
                if isCurrentCall {
                    removeCall(currentCall, with: .remoteEnded)
                }

            case .missCall:
                if isCurrentCall {
                    removeCall(currentCall, with: .unanswered)

                    if !isCurrentUser {
                        sendMissedCallNotification(event)
                    }
                }
//                if isCurrentUser {
//                    removeCall(currentCall, with: .unanswered)
//                    reportCallEnded(event, reason: .unanswered)
//                    // Prevent case user end call in other ringing device, but current call is connected.
//                    if let currentCall, !isCurrentDevice, currentCall.details.state != .connected {
//                        endCall(with: event.callId)
//                    }
//                } else {
//                    reportCallEnded(event, reason: .unanswered)
//                    endCall(with: event.callId)
//                    sendMissedCallNotification(event)
//                }
            case .rejectCall:
                if isCurrentCall {
                    if isCurrentUser {
                        if isCurrentDevice {
                            removeCall(currentCall, with: .unanswered)
                        } else {
                            removeCall(currentCall, with: .declinedElsewhere)
                        }
                    } else {
                        removeCall(currentCall, with: .remoteEnded)
                    }
                }
//                if isCurrentUser {
//                    if isCurrentDevice {
//                        reportCallEnded(event, reason: .unanswered)
//                        // Prevent case user end call in other ringing device, but current call is connected.
//                        if let currentCall, !isCurrentDevice, currentCall.details.state != .connected {
//                            endCall(with: event.callId)
//                        }
//                    } else {
//                        endCall(with: event.callId)
//                        reportCallEnded(event, reason: .declinedElsewhere)
//                    }
//                } else {
//                    reportCallEnded(event, reason: .remoteEnded)
//                }
            default:
                break
            }
        }
    }
}
