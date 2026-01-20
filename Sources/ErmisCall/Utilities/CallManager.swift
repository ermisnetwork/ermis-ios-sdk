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
    var connectionController: ConnectionController!
    var callProvider :CXProvider
    let callController: CXCallController
    
    package let callsQueue = DispatchQueue(label: "com.ermis.callmanager.calls")
    private var _calls: [Call] = []
    private var _callUUIDDictionary: [String: UUID] = [:]
    private var _endingCallUUIDs = Set<UUID>()
    
    var calls: [Call] {
        get {
            callsQueue.sync { _calls }
        }
        set {
            callsQueue.async(flags: .barrier) { [weak self] in
                self?._calls = newValue
            }
        }
    }
    
    var callUUIDDictionary: [String: UUID] {
        get {
            callsQueue.sync { _callUUIDDictionary }
        }
        set {
            callsQueue.async(flags: .barrier) { [weak self] in
                self?._callUUIDDictionary = newValue
            }
        }
    }
    
    public var endingCallUUIDs: Set<UUID> {
        get {
            callsQueue.sync { _endingCallUUIDs }
        }
        set {
            callsQueue.async(flags: .barrier) { [weak self] in
                self?._endingCallUUIDs = newValue
            }
        }
    }
    
    lazy var  eventsController = client.eventsController()
    public lazy var ioAccessManager = IOAccessManager()

    /// Return current active call.
    public var currentCall: Call? {
        return callsQueue.sync {
            _calls.last(where: { $0.details.state != .ended })
        }
    }

    public var audioManager: ErmisCallAudioManager {
        return ErmisCallAudioManager.shared
    }

    public weak var delegate: CallManagerDelegate?

    public var pendingTasks: [Task<Void, Never>] = []
    
    public func addToCallUUIDDictionary(callId: String, uuid: UUID) {
        callsQueue.async(flags: .barrier) { [weak self] in
            self?._callUUIDDictionary[callId] = uuid
        }
    }
    
    private func removeFromCallUUIDDictionary(callId: String) {
        callsQueue.async(flags: .barrier) { [weak self] in
            self?._callUUIDDictionary.removeValue(forKey: callId)
        }
    }
    
    private func insertEndingCallUUID(_ uuid: UUID) {
        callsQueue.async(flags: .barrier) { [weak self] in
            self?._endingCallUUIDs.insert(uuid)
        }
    }
    
    private func removeEndingCallUUID(_ uuid: UUID) {
        callsQueue.async(flags: .barrier) { [weak self] in
            self?._endingCallUUIDs.remove(uuid)
        }
    }
    
    private func clearEndingCallUUIDs() {
        callsQueue.async(flags: .barrier) { [weak self] in
            self?._endingCallUUIDs.removeAll()
        }
    }
    
    public func isEndingCallUUIDsEmpty() -> Bool {
        callsQueue.sync { _endingCallUUIDs.isEmpty }
    }
    
    public func containsEndingCallUUID(_ uuid: UUID) -> Bool {
        callsQueue.sync { _endingCallUUIDs.contains(uuid) }
    }
    
    private func appendCall(_ call: Call) {
        callsQueue.async(flags: .barrier) { [weak self] in
            self?._calls.append(call)
        }
    }
    
    private func removeCall(withCallId callId: String) {
        callsQueue.async(flags: .barrier) { [weak self] in
            self?._calls.removeAll(where: { $0.details.callId == callId })
        }
    }
    
    private func findCall(withCallId callId: String) -> Call? {
        callsQueue.sync {
            _calls.first { $0.details.callId == callId }
        }
    }
    
    private func findCall(withUUID uuid: UUID) -> Call? {
        callsQueue.sync {
            _calls.first(where: { $0.details.uuid == uuid })
        }
    }

    public static var needShowRequestMicrophoneAccessAlert: Bool {
        get {
            UserDefaults.standard.bool(forKey: "callKit.microphoneAccessDenied")
        }

        set {
            UserDefaults.standard.setValue(newValue, forKey: "callKit.microphoneAccessDenied")
        }
    }

    lazy var onCallEnded: ((Call?) -> Void) = { [weak self] call in
        log.debug("[Call] On call ended callUUID: \(call?.details.uuid)", subsystems: .call)
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        guard let call else { return }
        DispatchQueue.main.async {
            call.callNodeClient.stop()
        }
        if call.details.state != .ended {
            call.details.state == .ended
        }
        self?.sendEndCallNotification(call.details.callId, cid: call.details.cid)
        try? call.audioManager.didDeactivateAudioSession()
        if call.callNodeClient.isCallNodeConnected() {
            Task(priority: .high) { [weak self, weak call] in
                await call?.callNodeClient.close()
                self?.clearEndingCallUUIDs()
                self?.removeCall(withCallId: call?.details.callId ?? "")
            }
        } else {
            self?.clearEndingCallUUIDs()
            self?.removeCall(withCallId: call.details.callId)
        }
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
        guard let client else {
            return
        }
        connectionController = client.connectionController()
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
    public func createNewIncomingCall(from event: CallSignalEvent, uuid: UUID) -> Call? {
        guard let call = Call(sessionId: sessionId,
                        uuid: uuid,
                        callId: event.callId,
                        cid: event.cid,
                        client: client,
                        isVideo: event.isVideo ?? false,
                              isIncoming: true) else {
            log.debug("[Call] Failed to create new incoming call with uuid: \(uuid.uuidString)", subsystems: .call)
//            callNodeClient.close()
            return nil
        }

        let signaling = Signaler(client: client, cid: event.cid)
        let relayUrls = ["https://iroh-relay.ermis.network:8443"]
        guard let callNodeClient = CallNodeClient(signaling: signaling, relayUrls: relayUrls) else {
            return nil
        }
        call.callNodeClient.remoteAddress = event.metadata?.address

        pendingTasks.append(Task {
            await try? connectionSocket()
        })
        addCall(call)
        return call
    }

    // MARK: - Call

    /// Get call in channel.
    ///
    /// - Parameters:
    ///   - cid: The channel identifier.
    ///
    /// - Returns: The call in given channel. Return nil if not exist call in this channel.
    public func call(in cid: ChannelId) -> Call? {
        return callsQueue.sync {
            _calls.first { $0.details.cid == cid && $0.details.state != .ended }
        }
    }

    /// Get call with call identifier.
    ///
    /// - Parameters:
    ///   - callId: The call identifier.
    ///
    /// - Returns: The call with given identifier. Return nil if the call is not exist.
    public func call(with callId: String) -> Call? {
        return findCall(withCallId: callId)
    }


    func call(with uuid: UUID) -> Call? {
        return findCall(withUUID: uuid)
    }

    func getCallUUID(for callId: String) -> UUID? {
        return callsQueue.sync {
            _callUUIDDictionary[callId]
        }
    }

    /// Add new call if not exist.
    func addCall(_ call: Call) {
        callsQueue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            
            if !call.isLocalId {
                self._callUUIDDictionary[call.details.callId] = call.details.uuid
            }
            
            DispatchQueue.main.async {
                UIApplication.shared.isIdleTimerDisabled = true
            }
            
            guard self._calls.first(where: { $0.details.uuid == call.details.uuid }) == nil else {
                return
            }
            
            log.debug("callUUIDDictionary: \(self._callUUIDDictionary)", subsystems: .call)
            log.debug("[Call] Current calls: \(self._calls.map(\.details.callId))", subsystems: .call)
            log.debug("[Call] Add new call: \(call.details.callId)", subsystems: .call)
            self._calls.append(call)
        }
    }

    public func removeCall(_ call: Call) {
        log.debug("[Call] Remove call: \(call)")
        sendStartEndingCallNotification(call.details.callId, cid: call.details.cid)
        sendEndCallNotification(call.details.callId, cid: call.details.cid)
        if !call.isLocalId {
            Task(priority: .high) { [weak self] in
                try? await call.endCall()
                try? call.close()
                self?.removeCall(withCallId: call.details.callId)
            }
        } else {
            try? call.close()
            removeCall(withCallId: call.details.callId)
        }
    }

    // Remove current call without send ending signal.
    public func clearCall(_ callId: String, with reason: CXCallEndedReason) {
        guard let call = call(with: callId), isEndingCallUUIDsEmpty() else {
            return
        }
        log.warning("[Call] Clear call: \(call.details.callId), reason: \(reason)", subsystems: .call)
        insertEndingCallUUID(call.details.uuid)
        call.callNodeClient.close()
        callProvider.reportCall(with: call.details.uuid, endedAt: Date(), reason: reason)
        DispatchQueue.main.async { [weak self] in
            UIApplication.shared.isIdleTimerDisabled = false
            self?.sendStartEndingCallNotification(call.details.callId, cid: call.details.cid)
            self?.pendingTasks.forEach({ $0.cancel()})
            call.setState(.ended)
            self?.onCallEnded(call)
        }
    }

    /// End the call with given identifier.
    ///
    /// - Parameters:
    ///   - callId: The call identifier.
    public func endCall(with callId: String) {
        // Use thread-safe check
        guard let call = call(with: callId), isEndingCallUUIDsEmpty() else {
            log.debug("[CallKit] endCall guard failed - call: \(call(with: callId) != nil), endingCallUUIDs empty: \(isEndingCallUUIDsEmpty())")
            return
        }
        insertEndingCallUUID(call.details.uuid)
        call.callNodeClient.close()
        if Thread.isMainThread {
            self.endCall(call)
        } else {
            DispatchQueue.main.async {
                self.endCall(call)
            }
        }
    }

    private func endCall(_ call: Call) {
        UIApplication.shared.isIdleTimerDisabled = false
        sendStartEndingCallNotification(call.details.callId, cid: call.details.cid)
        self.pendingTasks.forEach({ $0.cancel()})
        log.debug("[CallKit] endcall with UUID: \(call.details.uuid)", subsystems: .call)
        let endAction = CXEndCallAction(call: call.details.uuid)

        let transaction = CXTransaction()
        transaction.addAction(endAction)
        requestTransaction(transaction, completion: { [weak self] error in
            if let error {
                if let error = error as? CXErrorCodeRequestTransactionError {
                    switch error.code {
                    case .unknown:
                        // Code 0 - Lỗi không xác định
                        log.debug("[CallKit] Unknown error")

                    case .unentitled:
                        // Code 1 - App chưa có entitlement cho CallKit
                        log.debug("[CallKit] App not entitled for CallKit")

                    case .unknownCallProvider:
                        // Code 2 - CXProvider không tồn tại hoặc đã bị invalidate
                        log.debug("[CallKit] Unknown call provider - need to recreate provider")
                    case .emptyTransaction:
                        // Code 3 - Transaction không có action nào
                        log.debug("[CallKit] Empty transaction")
                    case .unknownCallUUID:
                        // Code 4 - UUID không tồn tại trong hệ thống
                        log.debug("[CallKit] Call UUID not found - call may already ended")
                    case .callUUIDAlreadyExists:
                        // Code 5 - UUID đã tồn tại (thường gặp khi start call, không phải end call)
                        log.debug("[CallKit] Call UUID already exists")
                    case .invalidAction:
                        // Code 6 - Action không hợp lệ cho trạng thái hiện tại
                        log.debug("[CallKit] Invalid action for current call state")
                    case .maximumCallGroupsReached:
                        // Code 7 - Đã đạt giới hạn số nhóm cuộc gọi
                        log.debug("[CallKit] Maximum call groups reached")

                    @unknown default:
                        log.debug("[CallKit] New unhandled error: \(error.code.rawValue)")
                    }
                    // Call already ended.
                    if error.code == .unknownCallUUID {

                    } else {
                        self?.forceEndcall(callUUID: call.details.uuid)
                    }
                } else {
                    // Force ended call
                    self?.forceEndcall(callUUID: call.details.uuid)
                }
            }
        })
    }

    func forceEndcall(callUUID: UUID) {
        log.debug("[CallManager] Force end call callUUID: \(callUUID)")
        self.callProvider.reportCall(with: callUUID, endedAt: Date(), reason: .failed)
        onCallEnded(call(with: callUUID))
    }

    func sendEndCallNotification(_ callId: String?, cid: ChannelId?) {
        log.debug("[CallManager] Send end call notification callId: \(callId)")
        NotificationCenter.default.post(name: .callDidEnded,
                                        object: self,
                                        userInfo: [
                                            "call_id": callId,
                                            "cid": cid
                                        ]
        )
    }

    func sendStartEndingCallNotification(_ callId: String?, cid: ChannelId?) {
        log.debug("[CallManager] Send start ending call notification callId: \(callId)")
        NotificationCenter.default.post(name: .startEndingCall,
                                        object: self,
                                        userInfo: [
                                            "call_id": callId,
                                            "cid": cid
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
            let call = createNewIncomingCall(from: event, uuid: callUUID)
        }

        callUpdate.remoteHandle = CXHandle(type: .generic, value: event?.cid.rawValue ?? callUUID.uuidString)
        callProvider.reportNewIncomingCall(with: callUUID, update: callUpdate, completion: { [unowned self] error in
            /// Imediately end fake call.
            if event == nil || currentCall == nil {
                callProvider.reportCall(with: callUUID, endedAt: Date(), reason: .failed)
                return
            }
            if let error {
                log.error("[CallKit] Failed to report incoming call: \(error.localizedDescription)", subsystems: .call)
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
                    case .filteredDuringRestrictedSharingMode:
                        log.debug("[CallKit] Failed to report incoming call: [.filteredDuringRestrictedSharingMode]")
                    case .callIsProtected:
                        log.debug("[CallKit] Failed to report incoming call: [.callIsProtected]")
                    case .filteredBySensitiveParticipants:
                        log.debug("[CallKit] Failed to report incoming call: [.filteredBySensitiveParticipants]")
                    @unknown default:
                        log.debug("[CallKit] Failed to report incoming call: [.unknown default]")
                    }
                }
            } else {
                ErmisCallAudioManager.shared.configureAudioSession(isIncomingCall: true, isVideoCall: callUpdate.hasVideo)
                currentCall?.setState(.ringing)
                log.debug("[CallKit] Reported incoming call: \(callUUID.uuidString)", subsystems: .call)
            }
            completion(error)
        })
    }

    package func reportOutgoingCallStarted(_ call: Call) async throws {
        log.debug("[CallKit] Report outgoing call: \(call.details.uuid)", subsystems: .call)
        let handle = CXHandle(type: .generic, value: call.details.cid.rawValue)
        var startCallAction = CXStartCallAction(call: call.details.uuid, handle: handle)
        startCallAction.isVideo = call.details.isVideo
        let transaction = CXTransaction()
        transaction.addAction(startCallAction)
        return try await withCheckedThrowingContinuation { continuation in
            requestTransaction(transaction, completion: { error in
                if let error {
                    log.error("[CallKit] Failed to report outgoing call: \(call.details.uuid) with error: \(error)", subsystems: .call)
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume()
            })
        }
    }

    package func reportUpdateCall(for callUUID: UUID, localizedCallName: String? = nil, hasVideo: Bool? = nil) {
        log.debug("[CallKit] Report call update: \(callUUID)", subsystems: .call)
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
        log.debug("[CallKit] provider perform call start: \(action.callUUID).", subsystems: .call)
        ErmisCallAudioManager.shared.configureAudioSession(isIncomingCall: false, isVideoCall: currentCall?.details.isVideo ?? false)
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        log.debug("[CallKit] provider perform call answer: \(action.callUUID).", subsystems: .call)
        let isMicrophoneAccessGranted = ioAccessManager.isMicrophoneAccessGranted
        guard isMicrophoneAccessGranted else {
            CallManager.needShowRequestMicrophoneAccessAlert = true
            if let currentCall {
                endCall(with: currentCall.details.callId)
            }
            action.fulfill()
            return
        }
//        ErmisCallAudioManager.shared.configureAudioSession(isIncomingCall: true, isVideoCall: currentCall?.details.isVideo ?? false)

        let task = Task(priority: .high) { [weak self] in
            guard let self, !Task.isCancelled else {
                action.fulfill()
                return
            }
            do {
                delegate?.callManager(self, didAccept: currentCall)
                log.debug("[CallKit] Answering call")
                log.debug("[CallKit] Connecting socket...")
                try await connectionSocket()
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
                if let call = call(with: action.callUUID) {
                    Task(priority: .high) {
                        try? await call.endCall()
                    }
                }
                onCallEnded(call(with: action.callUUID))
            }
        }
        pendingTasks.append(task)
    }

    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        log.debug("[CallKit] provider perform end call: \(action.callUUID).", subsystems: .call)
        guard let call = call(with: action.callUUID) else {
            log.warning("[CallKit] provider perform end call: call not found calls: \(calls)", subsystems: .call)
            action.fulfill()
            return
        }

        if !containsEndingCallUUID(call.details.uuid) {
            insertEndingCallUUID(call.details.uuid)
            sendStartEndingCallNotification(call.details.callId, cid: call.details.cid)
        }


        Task(priority: .userInitiated) { [weak self] in
            guard let self else {
                return
            }
            do {
                if call.details.state.isConnected || call.isMissed {
                    try await call.endCall()
                    onCallEnded(call)
                    action.fulfill()
                } else {
                    log.debug("[Call] Reject call when Perform end call action \(call.details.callId) - call counts: \(calls.count)", subsystems: .call)
                    try await call.rejectCall()
                    onCallEnded(currentCall)
                    action.fulfill()
                }
            } catch let error {
                log.debug("[Call] Perform endcall action failed with error: \(error)")
                onCallEnded(call)
                action.fulfill()
            }
        }
    }

    public func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        log.debug("[CallKit] provider did perform held call: \(action.callUUID).", subsystems: .call)
    }

    public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        log.debug("[CallKit] provider did perform muted call: \(action.callUUID).", subsystems: .call)
        do {
            try currentCall?.setMute(action.isMuted)
            action.fulfill()
        } catch let error {
            action.fail()
        }
    }
    //
    public func provider(_ provider: CXProvider, perform action: CXSetGroupCallAction) {
        log.debug("[CallKit] provider did perform set group call: \(action.callUUID).", subsystems: .call)
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
        log.debug("[CallKit] provider did perform play dtmf call: \(action.callUUID).", subsystems: .call)
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        log.debug("[CallKit] provider did time out performing: \(action).", subsystems: .call)
        if let action = action as? CXEndCallAction, let call = call(with: action.callUUID) {
            if currentCall?.details.uuid == call.details.uuid {
                callProvider.reportCall(with: action.callUUID, endedAt: Date(), reason: .failed)
            }
            onCallEnded(call)
        } else if let action = action as? CXStartCallAction, let call = call(with: action.callUUID) {
            onCallEnded(call)
        } else if let action = action as? CXAnswerCallAction, let call = call(with: action.callUUID) {
            onCallEnded(call)
        }
//        Task(priority: .high) { [weak self] in
//            do {
//                try await self?.callNodeClient.endCall()
//                onCallEnded(currentCall)
//                action.fulfill()
//            } catch let error {
//                action.fulfill()
//            }
//        }
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
        log.debug("[CallKit] Received incoming call with payload: \(payload.dictionaryPayload)", subsystems: .call)

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
                }

                // Wait for ending calls to complete using proper async check
                Task { [weak self] in
                    guard let self else { return }
                    var retryCount = 0
                    while !self.isEndingCallUUIDsEmpty() && retryCount < 50 {
                        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                        retryCount += 1
                    }
                    
                    self.reportIncommingCall(callSignalEvent, completion: { _ in
                        completion()
                    })
                }
            case .failure(let error):
                log.error("[CallKit] Cannot handle pushkit payload: \(error)", subsystems: .call)
                reportIncommingCall(.none, completion: { _ in
                    completion()
                })
                completion()
            }
        }
    }

    // MARK: - Others
    public func ensureWebsocketConnected() async -> Bool {
        if client.connectionStatus == .connected {
            return true
        }
        return await withCheckedContinuation { continuation in
            self.connectionController.connect { [weak self] error in
                if let error, self?.client.connectionStatus != .connected {
                    continuation.resume(returning: false)
                } else {
                    continuation.resume(returning: true)
                }
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
- Event: CallAction: \(event.callAction)
- UUID: \(callUUID)
- Action: \(event.callAction)
- Other: Is currentUser: \(isCurrentUser), isCurrentDevice: \(isCurrentDevice), is currentCall: \(isCurrentCall)
""", subsystems: .call)

            if isCurrentCall && isCurrentDevice {
                log.debug("[CallNode] Receive call event from self, skip.")
                return
            }
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
                    // Wait for ending calls to complete using proper async check
                    Task { [weak self] in
                        guard let self else { return }
                        var retryCount = 0
                        while !self.isEndingCallUUIDsEmpty() && retryCount < 50 {
                            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                            retryCount += 1
                        }
                        self.reportIncommingCall(event, completion: { _ in })
                    }
                }
            case .acceptCall:
                // Call answer from other device.
                if isCurrentUser, !isCurrentDevice, isCurrentCall {
                    // TODO: - Find other way to make call history
//                    reportIncommingCall(event, completion: { _ in })
                    clearCall(event.callId, with: .answeredElsewhere)
                } else if !isCurrentUser, isCurrentCall {
                    if let currentCall, currentCall.isLocalId == true {
                        currentCall.setRemoteCallId(event.callId)
                    }
                    reportOutgoingCallStartConnecting(event)
                }
            case .signalCall:
                // TODO: - Remove unused webrtc signal.
                break
            case .endCall:
                if isCurrentCall {
                    clearCall(event.callId, with: .remoteEnded)
                }
            case .missCall:
                if isCurrentCall, !isCurrentUser {
                    endCall(with: event.callId)
                    sendMissedCallNotification(event)
                } else if isCurrentCall, isCurrentUser {
                    clearCall(event.callId, with: .unanswered)
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
                if isCurrentCall, isCurrentUser {
                    if isCurrentDevice {
                        clearCall(event.callId, with: .unanswered)
                    } else {
                        clearCall(event.callId, with: .declinedElsewhere)
                    }
                } else if isCurrentCall, !isCurrentUser {
                    clearCall(event.callId, with: .remoteEnded)
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
