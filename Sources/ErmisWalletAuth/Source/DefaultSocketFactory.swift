//
// Copyright 2025 Ermis Inc.
//

import Foundation
import WalletConnectRelay
import Starscream

extension WebSocket: WebSocketConnecting {

}

struct DefaultSocketFactory: WebSocketFactory {
    func create(with url: URL) -> any WebSocketConnecting {
        let socket = WebSocket(request: URLRequest(url: url))
        let queue = DispatchQueue(label: "network.ermis.sdk.sockets", attributes: .concurrent)
        socket.callbackQueue = queue
        return socket
    }
}

