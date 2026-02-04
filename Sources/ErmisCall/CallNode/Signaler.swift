//
// Copyright 2025 Ermis Inc.
//

import ErmisChat

/// A protocol that represent an object for send and receive signal message.
public protocol SignalingProtocol: AnyObject {
    /// A closure for handle new signale, will be call each time receive new signal.
    var onReceiveCallSignal: ((CallSignalEvent) -> Void)? { get set }

    /// Sending signal.
    ///
    /// - parameters:
    ///    - sessionId: The session identifier.
    ///    - callId: The identifier of the call.
    ///    - action: The `CallAction` of the signal.
    ///    - isVideo: The boolean value define this call is video call or audio call.
    ///    `true` if is video call.
    ///    - signalType: The type of the signal.
    ///    - sdp: The value of the signal, maybe sdp or ice.
    /// - Returns: An instance of `CallSignalRequestPayload` or throw `Error`
    func sendSignal(sessionId: String?,
                    callId: String?,
                    action: CallAction,
                    isVideo: Bool,
                    signalType: SignalType?,
                    sdp: String?, metadata: Metadata?) async throws -> CallSignalRequestPayload
}
/// A class implementation of `SignalingProtocol` for send and handle WebRTC
///  signal message.
public class Signaler: SignalingProtocol {
    /// The `ErmisClient` instance.
    let client: ErmisClient

    /// The `ChannelId` of channel which this call ocurent.
    let cid: ChannelId

    /// The `EventsController` instance.
    let eventsController: EventsController

    /// A closure for handle new signale, will be call each time receive new signal.
    public var onReceiveCallSignal: ((ErmisChat.CallSignalEvent) -> Void)?

    /// Create new `Signaler` instance.
    ///
    /// - Parameters:
    ///    - client: The `ErmisClient` instance.
    ///    - cid: The `ChannelId` instance of channel which this call ocurent.
    /// - Returns: An instance of `Signaling` object.
    public init(client: ErmisClient, cid: ChannelId) {
                self.client = client
                self.cid = cid
                self.eventsController = client.eventsController()
                eventsController.delegate = self
    }

    /// Sending signal.
    ///
    /// - parameters:
    ///    - sessionId: The call session identifier.
    ///    - callId: The identifier of the call.
    ///    - action: The `CallAction` of the signal.
    ///    - isVideo: The boolean value define this call is video call or audio call.
    ///    `true` if is video call.
    ///    - signalType: The type of the signal.
    ///    - sdp: The value of the signal, maybe sdp or ice.
    /// - Returns: An instance of `CallSignalRequestPayload` or throw `Error`
    public func sendSignal(sessionId: String?,
                           callId: String?,
                           action: CallAction,
                           isVideo: Bool,
                           signalType: SignalType?,
                           sdp: String?,
                           metadata: Metadata?) async throws -> CallSignalRequestPayload {
        let payload = try await client.sendSignal(for: callId, sessionId: sessionId, cid: cid, action: action, isVideo: isVideo, signalType: signalType, sdp: sdp, metadata: metadata)
        log.debug("[CallNode] sendSignal for callID \(callId), action: \(action), signalType: \(signalType)")
        return payload
    }
}

// MARK: - EventsControllerDelegate
extension Signaler: EventsControllerDelegate {
    public func eventsController(_ controller: ErmisChat.EventsController,
                                 didReceiveEvent event: any ErmisChat.Event) {
        if let event = event as? CallSignalEvent {
            onReceiveCallSignal?(event)
        }
    }
}
