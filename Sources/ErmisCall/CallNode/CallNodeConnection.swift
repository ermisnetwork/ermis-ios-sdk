//
// Copyright 2025 Ermis Inc.
//

import Foundation
import Combine
import ErmisChat
import ErmisCallNode

public class CallNodeConnection {
    var endpoint: ErmisCallEndpointProtocol

    var localAddress: String?
    var hasBeginGop: Bool = false

    public var dataPublisher = PassthroughSubject<Data, Never>()
    public var connectionPublisher = CurrentValueSubject<CallNodeConnectionStatus, Never>(.idle)

    public var isConnected: Bool {
        return connectionPublisher.value == .connected
    }

    init(relayUrls: [String], secretKey: Data?) throws {
        endpoint = try ErmisCallEndpoint(relayUrls: relayUrls, secretKey: secretKey)
        Task {
            do {
                localAddress = try await getLocalAddress()
            } catch {
                log.warning("[CallNode] Failed to get local address with error: \(error)", subsystems: .call)
            }
        }
    }

    public func getLocalAddress() async throws -> String {
        return try endpoint.getLocalEndpointAddr()
    }

    public func connect(to address: String) async throws {
        log.debug("[CallNode] Connecting to address: \(address)", subsystems: .call)
        connectionPublisher.send(.conecting)
        startReceivingData()
        try endpoint.connect(addr: address)
        log.debug("[CallNode] Connected.", subsystems: .call)
        connectionPublisher.send(.connected)
    }

    public func acceptConnect() async throws {
        log.debug("[CallNode] Accepting connection", subsystems: .call)
        self.startReceivingData()
        connectionPublisher.send(.conecting)
        try endpoint.acceptConnection()
        log.debug("[CallNode] Connected.", subsystems: .call)
        connectionPublisher.send(.connected)
    }

    public func sendEvent(_ event: CallNodeEventProtocol) {
        guard isConnected else {
            return
        }
        Task(name: "call_node_send_event", priority: .high) {
            do {
                switch event.type {
                case .videoKeyFrame:
                    try await sendVideoKeyFrameData(data: event.data)
                case .videoDeltaFrame:
                    try await sendVideoDeltaFrameData(data: event.data)
                case .audioFrame:
                    try await sendAudioData(data: event.data)
                default:
                    try await sendControlFrame(event.data)
                    log.debug("[CallNode]  Send Control frame: \(event)", subsystems: .call)
                }
            } catch {
                log.error("[CallNode] Failed to send CallEvent: \(event) with error: \(error)", subsystems: .call)
            }
        }
    }

    public func sendControlFrame(_ data: Data) async throws {
        guard isConnected else {
            throw ClientError.DataStreamNotConnected()
        }
        try await endpoint.sendControlFrame(data: data)
    }

    public func startReceivingData() {
        Task.detached(name: "call_node_receive_data", priority: .medium) {
            while true {
                let data = try await self.endpoint.recv()
                self.dataPublisher.send(data)
            }
        }
    }

    public func close() {
        endpoint.close()
    }

    func sendAudioData(data: Data) async throws {
        guard isConnected else {
            return
        }
//        if !hasBeginGop {
//            hasBeginGop = true
//            try endpoint.beginGopWith(data: data)
//        } else {
            try endpoint.sendAudioFrame(data: data)
//        }
    }

    func sendVideoDeltaFrameData(data: Data) async throws {
        guard isConnected else {
            return
        }
        try endpoint.sendFrame(data: data)
    }

    func sendVideoKeyFrameData(data: Data) async throws {
        guard isConnected else {
            return
        }
        try endpoint.beginGopWith(data: data)
        hasBeginGop = true
    }


    func getConnectionState() -> Bool {
        return endpoint.isConnected()
    }

    func getConnectionStats() -> ConnectionStats {
        return endpoint.getConnectionStats()
    }
}

extension ClientError {
    public final class DataStreamNotConnected: ClientError {}

}
