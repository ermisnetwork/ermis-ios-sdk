//
// Copyright 2025 Ermis Inc.
//

import Foundation

class URLSessionWebSocketEngine: NSObject, WebSocketEngine {
    /// Keep the task alive for the whole engine lifetime. Relying on URLSession's internal
    /// retention makes the receive loop timing-dependent during login/reconnect.
    private var task: URLSessionWebSocketTask? {
        didSet {
            oldValue?.cancel()
        }
    }

    let request: URLRequest
    private var session: URLSession?
    let delegateOperationQueue: OperationQueue
    let sessionConfiguration: URLSessionConfiguration
    var urlSessionDelegateHandler: URLSessionDelegateHandler?

    var callbackQueue: DispatchQueue { delegateOperationQueue.underlyingQueue! }

    weak var delegate: WebSocketEngineDelegate?

    required init(request: URLRequest, sessionConfiguration: URLSessionConfiguration, callbackQueue: DispatchQueue) {
        self.request = request
        self.sessionConfiguration = sessionConfiguration

        delegateOperationQueue = OperationQueue()
        delegateOperationQueue.underlyingQueue = callbackQueue

        super.init()
    }

    func connect() {
        urlSessionDelegateHandler = makeURLSessionDelegateHandler()

        session = URLSession(
            configuration: sessionConfiguration,
            delegate: urlSessionDelegateHandler,
            delegateQueue: delegateOperationQueue
        )

        // Do not log the full URL, query, or header values here. They contain the bearer token,
        // API key, device id, and user id. Host/path are sufficient to trace the handshake.
        let host = request.url?.host ?? "unknown"
        let path = request.url?.path ?? "/"
        log.info(
            "[WebSocket] state=upgrade_requested host=\(host) path=\(path)",
            subsystems: .webSocket
        )

        task = session?.webSocketTask(with: request)

        // A receive registered while the task is still suspended can fail immediately with
        // "socket is not connected". The old implementation then stopped the read loop, so the
        // initial Bellboy health.check was never observed and connectUser timed out waiting for
        // the connection id. Start the transport first, then arm the recursive receive loop.
        task?.resume()
        log.info(
            "[WebSocket] state=task_resumed host=\(host) path=\(path)",
            subsystems: .webSocket
        )
        doRead()
    }

    func disconnect() {
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()

        session = nil
        task = nil
        urlSessionDelegateHandler = nil
    }

    func sendPing() {
        task?.send(.string(""), completionHandler: { error in
            if let error = error {
                log.error(error.localizedDescription)
            }
        })
    }

    private func doRead() {
        task?.receive { [weak self] result in
            guard let self = self else {
                return
            }

            switch result {
            case let .success(message):
                if case let .string(string) = message {
//                    log.debug("Web Socket receive message: \(message)")
                    self.callbackQueue.async { [weak self] in
                        self?.delegate?.webSocketDidReceiveMessage(string)
                    }
                }
                self.doRead()

            case let .failure(error):
                if error.isSocketNotConnectedError {
                    log.debug("Web Socket got disconnected with error: \(error)", subsystems: .webSocket)
                } else {
                    log.error("Failed receiving Web Socket Message with error: \(error)", subsystems: .webSocket)
                }
            }
        }
    }

    private func makeURLSessionDelegateHandler() -> URLSessionDelegateHandler {
        let urlSessionDelegateHandler = URLSessionDelegateHandler()
        urlSessionDelegateHandler.onOpen = { [weak self] _ in
            log.info("[WebSocket] state=transport_opened", subsystems: .webSocket)
            self?.callbackQueue.async {
                self?.delegate?.webSocketDidConnect()
            }
        }

        urlSessionDelegateHandler.onClose = { [weak self] closeCode, reason in
            log.info(
                "[WebSocket] state=transport_closed code=\(closeCode.rawValue)",
                subsystems: .webSocket
            )
            var error: WebSocketEngineError?
            var reasonString: String?
            // Token expired
            if (closeCode.rawValue == 1005) {
                reasonString = "Token expired"
            }

            if let reasonData = reason, let string = String(data: reasonData,
                                                            encoding: .utf8) {
                reasonString = string
            }

            if let reasonString = reasonString {
                error = WebSocketEngineError(
                    reason: reasonString,
                    code: closeCode.rawValue,
                    engineError: nil
                )
            }

            self?.callbackQueue.async { [weak self] in
                self?.delegate?.webSocketDidDisconnect(error: error)
            }
        }

        urlSessionDelegateHandler.onCompletion = { [weak self] error in
            // If we received this callback because we closed the WS connection
            // intentionally, `error` param will be `nil`.
            // Delegate is already informed with `didCloseWith` callback,
            // so we don't need to call delegate again.
            guard let error = error else { return }

            let nsError = error as NSError
            log.error(
                "[WebSocket] state=transport_completed domain=\(nsError.domain) code=\(nsError.code)",
                subsystems: .webSocket
            )

            self?.callbackQueue.async { [weak self] in
                self?.delegate?.webSocketDidDisconnect(error: WebSocketEngineError(error: error))
            }
        }

        return urlSessionDelegateHandler
    }

    deinit {
        disconnect()
    }
}

class URLSessionDelegateHandler: NSObject, URLSessionDataDelegate, URLSessionWebSocketDelegate {
    var onOpen: ((_ protocol: String?) -> Void)?
    var onClose: ((_ code: URLSessionWebSocketTask.CloseCode, _ reason: Data?) -> Void)?
    var onCompletion: ((Error?) -> Void)?

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        onOpen?(`protocol`)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        onClose?(closeCode, reason)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        onCompletion?(error)
    }
}
