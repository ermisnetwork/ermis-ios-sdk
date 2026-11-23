//
// Copyright 2025 Ermis Inc.
//

import Foundation
import Combine
import EventSource
import ErmisShared

/// Owns only one scoped request completion/task. Encoding and auth waits share the absolute budget.
private final class MlsRequestCompletion<Response> {
    private let lock = NSLock()
    private let deadline: Date
    private let timeoutReason: String
    private var callback: ((Result<Response, Error>) -> Void)?
    private var timer: DispatchSourceTimer?
    private var task: URLSessionTask?
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return callback == nil }
    init(deadline: Date, timeoutReason: String, completion: @escaping (Result<Response, Error>) -> Void) {
        self.deadline = deadline; self.timeoutReason = timeoutReason; callback = completion
        let timer = DispatchSource.makeTimerSource(queue: .global())
        self.timer = timer
        timer.schedule(deadline: .now() + max(0, deadline.timeIntervalSinceNow))
        timer.setEventHandler { [weak self] in self?.finish(.failure(ClientError.Unexpected(timeoutReason))) }
        timer.resume()
    }
    func attach(_ task: URLSessionTask) {
        lock.lock()
        let closed = callback == nil
        if !closed { self.task = task }
        lock.unlock()
        if closed { task.cancel() }
    }
    func finish(_ result: Result<Response, Error>) {
        lock.lock()
        let completion = callback, timer = self.timer, task = self.task, expired = Date() >= deadline
        callback = nil; self.timer = nil; self.task = nil
        lock.unlock()
        timer?.cancel()
        if expired { task?.cancel() }
        completion?(expired ? .failure(ClientError.Unexpected(timeoutReason)) : result)
    }
}

/// An object which making api request to Ermis Chat servers.
class APIClient {
    /// The URL session used for all requests.
    let session: URLSession
    private let sessionNetworkBudget = SessionNetworkBudget()
    private let channelMetadataRequests = SessionRequestCoalescer<ChannelListPayload>()
    
    /// The object which encode `Endpoint` objects into `URLRequest`s.
    let encoder: RequestEncoder
    
    /// The object which decode the results of network requests.
    let decoder: RequestDecoder
    
    /// The closure which getting new token when token is expire.
    var tokenRefresher: ((@escaping (Error?) -> Void) -> Void)?

    /// Used to queue requests that happen while we are offline
    var queueOfflineRequest: QueueOfflineRequestBlock?
    
    /// The uploader.
    let uploader: Uploader

    /// The downloader.
    let downloader: Downloader

    /// Event source for SSE request.
    lazy var eventSource = EventSource(mode: .default, timeoutIntervalForRequest: 60, timeoutIntervalForResource: 60)

    /// The `OperationQueue` which handling incoming requests
    private let operationQueue: OperationQueue = {
        let operationQueue = OperationQueue()
        operationQueue.name = "network.ermis.api-client"
        return operationQueue
    }()

    /// The `OperationQueue` which handling incoming SSE requests.
    private let sseOperationQueue: OperationQueue = {
        let operationQueue = OperationQueue()
        operationQueue.name = "network.ermis.sse.api-client"
        return operationQueue
    }()

    /// The `OperationQueue` which handling refresh token requests.
    private let refreshTokenOP: OperationQueue = {
        let operationQueue = OperationQueue()
        operationQueue.name = "network.ermis.refreshToken"
        operationQueue.maxConcurrentOperationCount = 1
        return operationQueue
    }()

    /// The `OperationQueue` which handling recovery related requests.
    private let recoveryQueue: OperationQueue = {
        let operationQueue = OperationQueue()
        operationQueue.name = "network.ermis.api-client.recovery"
        operationQueue.maxConcurrentOperationCount = 1
        return operationQueue
    }()
    
    /// The flag to check whether the APIClient is in recovery mode or not. If in recovery period `APIClient` will limit the concurrent operations to 1, and only allow recovery related requests to be run.
    @Atomic private var isInRecoveryMode: Bool = false
    
    /// The flag to check whether the token is being refreshed at the moment.
    @Atomic private var isRefreshingToken: Bool = false
    
    /// Maximum amount of times a request can be retried.
    private let maximumRequestRetries = 3

    deinit {
        sessionNetworkBudget.invalidate()
        operationQueue.cancelAllOperations()
        recoveryQueue.cancelAllOperations()
        refreshTokenOP.cancelAllOperations()
    }
    
    /// Creates a new `APIClient`.
    init(
        sessionConfiguration: URLSessionConfiguration,
        requestEncoder: RequestEncoder,
        requestDecoder: RequestDecoder,
        uploader: Uploader,
        downloader: Downloader
    ) {
        encoder = requestEncoder
        decoder = requestDecoder
        session = URLSession(configuration: sessionConfiguration)
        self.uploader = uploader
        self.downloader = downloader
    }
    
    /// Performs a server sent event request
    ///
    /// - Parameters:
    ///   - endpoint: The `Endpoint` used to create the SSE request.
    ///   - completion: Called when the request receive event or changed connection state.
    func sseRequest<Response: Decodable>(endpoint: Endpoint<Response>, completion: @escaping (Response?, Error?) -> Void) {
        let requestOperation = sseOperation(endpoint: endpoint, isRecoveryOperation: false, completion: completion)
        sseOperationQueue.addOperation(requestOperation)
    }

    private func sseOperation<Response: Decodable>(
        endpoint: Endpoint<Response>,
        isRecoveryOperation: Bool,
        completion: @escaping (Response?, Error?) -> Void
    ) -> SSEAsyncOperation {
        SSEAsyncOperation(maxRetries: maximumRequestRetries) { [weak self] operation, done in
            guard let self = self else {
                done(.continue)
                return
            }

            guard !self.isRefreshingToken else {
                // Requeue request
                self.sseRequest(endpoint: endpoint, completion: completion)
                done(.continue)
                return
            }
            
            self.executeSSERequest(endpoint: endpoint) { [weak self] value, error in
                guard error == nil else {
                    if let error = error as? ClientError.RefreshingToken {
                        self?.sseRequest(endpoint: endpoint, completion: completion)
                        done(.continue)
                    } else if let error = error as? ClientError.TokenRefreshed {
                        if operation.canRetry {
                            done(.retry)
                        } else {
                            completion(nil, ClientError.TokenRefreshRetryLimitExceeded())
                            done(.continue)
                        }
                    } else if let error = error as? ClientError.RefreshTokenExpired {
                        completion(nil, error)
                        done(.continue)
                    } else if let error = error as? ClientError.WaiterTimeout {
                        if operation.canRetry {
                            done(.retry)
                        } else {
                            completion(nil, error)
                            done(.continue)
                        }
                    } else {
                        if operation.canRetry {
                            done(.retry)
                        } else {
                            completion(nil, error)
                            done(.continue)
                        }
                    }
                    return
                }
                completion(nil, error)
            }
        }
    }

    func executeSSERequest<Response: Decodable>(endpoint: Endpoint<Response>, completion: @escaping (Response?, Error?) -> Void) {
        encoder.encodeRequest(for: endpoint) { [weak self] result in
            Task {  [weak self] in
                guard let self = self else {
                    completion(nil, nil)
                    return
                }
                do {
                    let request = try encoder.encodeRequest(for: endpoint)
                    let dataTask = await eventSource.dataTask(for: request)
                    for await event in await dataTask.events() {
                        switch event {
                        case .open:
                            log.debug("[SSE] state=opened", subsystems: .httpRequests)
                        case .error(let error):
                            log.debug(
                                "[SSE] state=failed \(PrivacySafeLogMetadata.errorFields(error))",
                                subsystems: .httpRequests
                            )
                            completion(nil, error)
                        case .event(let event):
                            log.debug("[SSE] state=event_received has_data=\(event.data != nil)", subsystems: .httpRequests)
                            if let response: Response = try? decoder.decodeSSEMessage(message: event.data) {
                                completion(response, nil)
                            }
                        case .closed:
                            log.debug("[SSE] state=closed", subsystems: .httpRequests)
                        }
                    }
                } catch {
                    log.debug(
                        "[SSE] state=stream_failed \(PrivacySafeLogMetadata.errorFields(error))",
                        subsystems: .httpRequests
                    )
                }
            }
        }
    }

    /// Performs a api request and retries in case of network failures
    ///
    /// - Parameters:
    ///   - endpoint: The `Endpoint` used to create the network request.
    func captureSessionNetworkOwner() -> () throws -> Void { sessionNetworkBudget.captureOwner() }

    func requestChannelMetadata(query: ChannelListQuery, isRecovery: Bool = false, completion: @escaping (Result<ChannelListPayload, Error>) -> Void) {
        guard query.messagesLimit <= 1 || query.shouldLoadAllChannels else {
            if isRecovery { recoveryRequest(endpoint: .channels(query: query), completion: completion) }
            else { request(endpoint: .channels(query: query), completion: completion) }
            return
        }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            var key = try encoder.encode(query)
            key.append(query.shouldLoadAllChannels ? 1 : 0)
            key.append(isRecovery ? 1 : 0)
            let owner = sessionNetworkBudget.captureOwner(); try owner()
            let guarded: (Result<ChannelListPayload, Error>) -> Void = { result in
                do { try owner(); var payload = try result.get(); payload.sessionOwner = owner; completion(.success(payload)) }
                catch { completion(.failure(error)) }
            }
            channelMetadataRequests.request(key: key, owner: owner, completion: guarded) { callback in
                if query.shouldLoadAllChannels && query.pagination.offset == 0 && query.pagination.cursor == nil {
                    self.requestAllChannelMetadata(query: query, isRecovery: isRecovery, owner: owner, offset: 0, channels: [], seen: [], completion: callback)
                } else if isRecovery {
                    self.recoveryRequest(endpoint: .channels(query: query), completion: callback)
                } else {
                    self.request(endpoint: .channels(query: query), completion: callback)
                }
            }
        } catch { completion(.failure(error)) }
    }

    private func requestAllChannelMetadata(
        query: ChannelListQuery, isRecovery: Bool, owner: @escaping () throws -> Void, offset: Int,
        channels: [ChannelPayload], seen: Set<ChannelId>,
        completion: @escaping (Result<ChannelListPayload, Error>) -> Void
    ) {
        do { try owner() } catch { completion(.failure(error)); return }
        var page = query
        page.pagination = Pagination(pageSize: query.pagination.pageSize, offset: offset)
        let receive: (Result<ChannelListPayload, Error>) -> Void = { result in
            do {
                try owner()
                let payload = try result.get()
                guard payload.metadataComplete else {
                    throw NSError(domain: "ChannelListPagination", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Channel metadata could not be completely decoded"])
                }
                let additions = payload.channels.filter { !seen.contains($0.channel.cid) }
                let accumulated = channels + additions
                if payload.channels.count < page.pagination.pageSize {
                    completion(.success(ChannelListPayload(channels: accumulated)))
                } else if additions.isEmpty {
                    completion(.failure(NSError(domain: "ChannelListPagination", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Channel list page made no progress"])))
                } else {
                    self.requestAllChannelMetadata(query: query, isRecovery: isRecovery, owner: owner,
                        offset: offset + payload.channels.count, channels: accumulated,
                        seen: seen.union(additions.map { $0.channel.cid }), completion: completion)
                }
            } catch { completion(.failure(error)) }
        }
        if isRecovery { recoveryRequest(endpoint: .channels(query: page), completion: receive) }
        else { request(endpoint: .channels(query: page), completion: receive) }
    }

    func request<Response: Decodable>(endpoint: Endpoint<Response>) async throws -> Response {
        return try await withCheckedThrowingContinuation { [weak self] continuation in
            self?.request(endpoint: endpoint) { result in
                continuation.resume(with: result)
            }
        }
    }

    /// Performs a api request and retries in case of network failures
    ///
    /// - Parameters:
    ///   - endpoint: The `Endpoint` used to create the network request.
    ///   - completion: Called when the networking request is finished.
    func request<Response: Decodable>(
        endpoint: Endpoint<Response>,
        completion: @escaping (Result<Response, Error>) -> Void
    ) {
        // A suspended auth queue must not outlive this operation's original deadline.
        let budget = endpoint.localMlsDeadline.map { MlsRequestCompletion<Response>(deadline: $0, timeoutReason: endpoint.localMlsTimeoutReason, completion: completion) }
        let requestOperation = operation(endpoint: endpoint, isRecoveryOperation: false) { result in
            if let budget { budget.finish(result) } else { completion(result) }
        }
        operationQueue.addOperation(requestOperation)
    }

    /// Performs a refresh token request and retries in case of network failures
    ///
    /// - Parameters:
    ///   - endpoint: The `Endpoint` used to create the network request.
    ///   - completion: Called when the networking request is finished.
    func refreshTokenRequest<Response: Decodable>(
        endpoint: Endpoint<Response>,
        completion: @escaping (Result<Response, Error>) -> Void
    ) {
        let requestOperation = operation(endpoint: endpoint, isRecoveryOperation: false, completion: completion)
        // Refresh must not run on `OperationQueue.main`. During reconnect many failed requests can
        // join the same refresh cycle; executing the refresh operation on main lets synchronous
        // connection/token callbacks recursively grow the main-thread stack. A dedicated serial
        // queue also guarantees that two refresh HTTP requests cannot race each other.
        refreshTokenOP.addOperation(requestOperation)
    }
    /// Performs a recovery request and retries in case of network failures
    ///
    /// - Parameters:
    ///   - endpoint: The `Endpoint` used to create the network request.
    ///   - completion: Called when the networking request is finished.
    func recoveryRequest<Response: Decodable>(
        endpoint: Endpoint<Response>,
        completion: @escaping (Result<Response, Error>) -> Void
    ) {
        if !isInRecoveryMode {
            log.assertionFailure("We should not call this method if not in recovery mode")
        }
        
        let requestOperation = operation(endpoint: endpoint, isRecoveryOperation: true, completion: completion)
        recoveryQueue.addOperation(requestOperation)
    }
    
    /// Performs a api request and retries in case of network failures. The network operation
    /// won't be managed by the `APIClient` instance. Instead it will be added on the `OperationQueue.main`
    ///
    /// - Parameters:
    ///   - endpoint: The `Endpoint` used to create the network request.
    ///   - completion: Called when the networking request is finished.
    func unmanagedRequest<Response: Decodable>(
        endpoint: Endpoint<Response>,
        completion: @escaping (Result<Response, Error>) -> Void
    ) {
        OperationQueue.main.addOperation(
            unmanagedOperation(endpoint: endpoint, completion: completion)
        )
    }
    
    private func operation<Response: Decodable>(
        endpoint: Endpoint<Response>,
        isRecoveryOperation: Bool,
        completion: @escaping (Result<Response, Error>) -> Void
    ) -> AsyncOperation {
        // Share the refreshed credential with HTTP and socket consumers. Auth gets
        // one retry independently of the existing bounded transport retry budget.
        var didRefreshAuthentication = false
        var endpoint = endpoint
        var didRetainBody = false
        return AsyncOperation(maxRetries: endpoint.localMlsGuard == nil ? maximumRequestRetries : 1) { [weak self] operation, done in
            guard let self = self else {
                done(.continue)
                return
            }

            do {
                try endpoint.localMlsGuard?()
                if let deadline = endpoint.localMlsDeadline, deadline <= Date() { throw ClientError.Unexpected(endpoint.localMlsTimeoutReason) }
                if !didRetainBody && endpoint.method != .get {
                    if let data = endpoint.body as? Data {
                        endpoint.localRetainedRequestBody = try E2eeLegacyRequestBodyNormalizer.normalizeIfNeeded(data, path: endpoint.path)
                    } else {
                        endpoint.localRetainedRequestBody = try JSONEncoder.ermis.encode(AnyEncodable(endpoint.body ?? EmptyBody()))
                    }
                    didRetainBody = true
                }
            } catch { completion(.failure(error)); done(.continue); return }

            log.debug(
                "[API_REQUEST] state=queued refreshing_token=\(self.isRefreshingToken) queue_suspended=\(self.operationQueue.isSuspended)",
                subsystems: .httpRequests
            )
            
            guard !self.isRefreshingToken || endpoint.path.isRefreshToken else {
                // Requeue request
                log.debug("[API_REQUEST] state=requeued reason=token_refresh", subsystems: .httpRequests)
                self.request(endpoint: endpoint, completion: completion)
                done(.continue)
                return
            }
            
            self.executeRequest(endpoint: endpoint, allowAuthRefresh: !didRefreshAuthentication && (endpoint.localMlsGuard == nil || operation.canRetry)) { [weak self] result in
                switch result {
                case .failure(_ as ClientError.RefreshingToken):
                    // Requeue request
                    self?.request(endpoint: endpoint, completion: completion)
                    done(.continue)
                case .failure(_ as ClientError.TokenRefreshed):
                    didRefreshAuthentication = true
                    // A server can reject a locally-valid JWT (revocation, environment mismatch,
                    // or claim policy). Keep this retry finite instead of resetting the budget and
                    // entering an unbounded refresh -> retry callback loop.
                    if operation.canRetry {
                        done(.retry)
                    } else {
                        completion(.failure(ClientError.TokenRefreshRetryLimitExceeded()))
                        done(.continue)
                    }
                case .failure(_ as ClientError.RefreshTokenExpired):
                    completion(result)
                    done(.continue)
                case .failure(_ as ClientError.WaiterTimeout):
                    // When waiters timeout, chances are that we are still connecting. We are going to retry until we reach max retries
                    if endpoint.localMlsGuard == nil && operation.canRetry {
                        done(.retry)
                    } else {
                        completion(result)
                        done(.continue)
                        return
                    }
                case let .failure(error) where self?.isConnectionError(error) == true:
                    // If a non recovery request comes in while we are in recovery mode, we want to queue if still has
                    // retries left
                    let inRecoveryMode = self?.isInRecoveryMode == true
                    if endpoint.localMlsGuard == nil && inRecoveryMode && !isRecoveryOperation && operation.canRetry {
                        self?.request(endpoint: endpoint, completion: completion)
                        done(.continue)
                        return
                    }
                    
                    // Do not retry unless its a connection problem and we still have retries left
                    if endpoint.localMlsGuard == nil && operation.canRetry {
                        done(.retry)
                        return
                    }
                    
                    if inRecoveryMode {
                        completion(.failure(ClientError.ConnectionError()))
                    } else {
                        // Offline Queuing
                        if endpoint.localMlsGuard == nil { self?.queueOfflineRequest?(endpoint.withDataResponse) }
                        completion(result)
                    }
                    
                    done(.continue)
                    return
                case .success, .failure:
                    log.debug("[API_REQUEST] state=operation_completed", subsystems: .offlineSupport)
                    completion(result)
                    done(.continue)
                    return
                }
            }
        }
    }
    
    private func unmanagedOperation<Response: Decodable>(
        endpoint: Endpoint<Response>,
        completion: @escaping (Result<Response, Error>) -> Void
    ) -> AsyncOperation {
        AsyncOperation(maxRetries: maximumRequestRetries) { [weak self] operation, done in
            self?.executeRequest(endpoint: endpoint) { [weak self] result in
                switch result {
                case let .failure(error) where self?.isConnectionError(error) == true:
                    // Do not retry unless its a connection problem and we still have retries left
                    if operation.canRetry {
                        done(.retry)
                        return
                    }
                    
                    completion(result)
                    done(.continue)
                case .success, .failure:
                    log.debug("[API_REQUEST] state=unmanaged_operation_completed", subsystems: .offlineSupport)
                    completion(result)
                    done(.continue)
                }
            }
        }
    }
    
    /// Performs a api request.
    ///
    /// - Parameters:
    ///   - endpoint: The `Endpoint` used to create the network request.
    ///   - completion: Called when the networking request is finished.
    private func executeRequest<Response: Decodable>(
        endpoint: Endpoint<Response>,
        allowAuthRefresh: Bool = true,
        completion: @escaping (Result<Response, Error>) -> Void
    ) {
        let listRequestId = UUID().uuidString.lowercased()
        let listRequestStarted = ProcessInfo.processInfo.systemUptime
        let isListRequest: Bool = { if case .channels = endpoint.path { return true }; return false }()
        let isProfileRequest: Bool = { if case .userBatch = endpoint.path { return true }; return false }()
        // Closed categories only: never log paths, headers, users or request/response bodies.
        let costCategory: String? = {
            if isListRequest { return "metadata" }; if isProfileRequest { return "profile" }
            switch endpoint.path {
            case .e2eSync, .e2eChannelSync: return "sync"
            case .mlsGeneration: return "generation"
            case .externalJoin: return "join_submit"
            case .getGroupInfo, .getGroupInfoRefresh, .uploadGroupInfo, .claimGroupInfoRefresh, .reportGroupInfoFailure: return "group_info"
            case .mlsControl(let path): return path.contains("/external_join/operations/") ? "join_receipt" : "control"
            default: return endpoint.path.value.contains("key_packages") ? "keypackage" : nil
            }
        }()
        func traceListHttp(_ stage: String, status: Int = 0, bytes: Int = 0) {
            guard costCategory != nil else { return }
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - listRequestStarted) * 1000)
            if isListRequest || isProfileRequest {
                let marker = isListRequest ? "channel_list_http" : "user_profile_http"
                log.info("\(marker) stage=\(stage) request_id=\(listRequestId) status=\(status) bytes=\(bytes) elapsed_ms=\(elapsed)", subsystems: .mls)
            }
            if let costCategory, ["network_queued", "network_admitted", "response_received", "network_failed", "decode_succeeded", "decode_failed"].contains(stage) {
                log.info("session_http category=\(costCategory) stage=\(stage) request_id=\(listRequestId) status=\(status) bytes=\(bytes) elapsed_ms=\(elapsed)", subsystems: .mls)
            }
        }
        traceListHttp("encoding_started")
        let assertNetworkOwner = sessionNetworkBudget.captureOwner()
        // This gate also releases AsyncOperation when encoding/registration/refresh never calls back.
        let budget = endpoint.localMlsDeadline.map { MlsRequestCompletion<Response>(deadline: $0, timeoutReason: endpoint.localMlsTimeoutReason, completion: completion) }
        let complete: (Result<Response, Error>) -> Void = { result in
            if let budget { budget.finish(result) } else { completion(result) }
        }
        if let deadline = endpoint.localMlsDeadline, deadline <= Date() {
            complete(.failure(ClientError.Unexpected(endpoint.localMlsTimeoutReason))); return
        }
        encoder.encodeRequest(for: endpoint) { [weak self] (requestResult) in
            if budget?.isFinished == true { return }
            var urlRequest: URLRequest
            do {
                try assertNetworkOwner(); try endpoint.localMlsGuard?()
                if let deadline = endpoint.localMlsDeadline, deadline <= Date() {
                    throw ClientError.Unexpected(endpoint.localMlsTimeoutReason)
                }
                urlRequest = try requestResult.get()
                if let deadline = endpoint.localMlsDeadline {
                    guard deadline > Date() else { throw ClientError.Unexpected(endpoint.localMlsTimeoutReason) }
                    urlRequest.timeoutInterval = min(5, deadline.timeIntervalSinceNow)
                }
            } catch {
                traceListHttp("encoding_failed")
                log.error("[API_REQUEST] state=encoding_failed", subsystems: .httpRequests)
                // Proof registration happens during encoding and can receive the same bare
                // HTTP401 as the final request. Join the existing refresh queue in that case.
                if error is ClientError.ExpiredToken, let self {
                    guard allowAuthRefresh else { complete(.failure(ClientError.TokenRefreshRetryLimitExceeded())); return }
                    if case .refreshToken = endpoint.path { complete(.failure(error)); return }
                    self.refreshToken { complete(.failure($0)) }
                } else {
                    complete(.failure(error))
                }
                return
            }

            traceListHttp("encoding_finished")
            log.debug(
                urlRequest.privacySafeDiagnosticSummary(state: .started),
                subsystems: .httpRequests
            )

            guard let self = self else {
                log.warning("Callback called while self is nil", subsystems: .httpRequests)
                complete(.failure(ClientError("APIClient was deallocated")))
                return
            }
            
            traceListHttp("network_queued")
            self.sessionNetworkBudget.submit({ permit in
            traceListHttp("network_admitted")
            do {
                try assertNetworkOwner(); try endpoint.localMlsGuard?()
                if budget?.isFinished == true { permit.release(); return }
                if let deadline = endpoint.localMlsDeadline, deadline <= Date() { throw ClientError.Unexpected(endpoint.localMlsTimeoutReason) }
            } catch { permit.release(); complete(.failure(error)); return }
            let task = self.session.dataTask(with: urlRequest) { [decoder = self.decoder] (data, response, error) in
                traceListHttp(error == nil ? "response_received" : "network_failed",
                              status: (response as? HTTPURLResponse)?.statusCode ?? 0, bytes: data?.count ?? 0)
                permit.release()
                if budget?.isFinished == true { return }
                do { try assertNetworkOwner() } catch { complete(.failure(error)); return }
                let path = urlRequest.url?.path ?? ""
                if path == "/uss/v1/auth/google_login" {
                    print(ErmisAuthenticationDiagnostics.googleResponseMarker(data: data, response: response, error: error))
                }
                if path.hasPrefix("/v1/e2ee/channels/"),
                   path.hasSuffix("/external_join") || path.contains("/external_join/operations/") {
                    let stage = path.hasSuffix("/external_join") ? "commit" : "receipt"
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    let result = error == nil ? "response" : "transport_error"
                    log.warning("mls_join_http stage=\(stage) result=\(result) status=\(status)", subsystems: .mls)
                }
                do {
                    try endpoint.localMlsGuard?()
                    let decodedResponse: Response = try decoder.decodeRequestResponse(
                        data: data,
                        response: response,
                        error: error
                    )
                    log.debug(
                        urlRequest.privacySafeDiagnosticSummary(state: .succeeded),
                        subsystems: .httpRequests
                    )
                    traceListHttp("decode_succeeded", status: (response as? HTTPURLResponse)?.statusCode ?? 0, bytes: data?.count ?? 0)
                    complete(.success(decodedResponse))
                } catch {
                    traceListHttp("decode_failed", status: (response as? HTTPURLResponse)?.statusCode ?? 0, bytes: data?.count ?? 0)
                    log.debug(
                        urlRequest.privacySafeDiagnosticSummary(state: .failed),
                        subsystems: .httpRequests
                    )
                    
                    if error is ClientError.ExpiredToken == false {
                        complete(.failure(error))
                        return
                    }
                    guard allowAuthRefresh else { complete(.failure(ClientError.TokenRefreshRetryLimitExceeded())); return }

                    // If Refresh Token is expired, don't continue refresh
                    if case .refreshToken = endpoint.path {
                        complete(.failure(error))
                        return
                    }

                    /// If the error is ExpiredToken, we need to refresh it. There are 2 possibilities here:
                    /// 1. The token is not being refreshed, so we start the refresh, and we wait until it is completed. Then the request will be retried.
                    /// 2. The token is already being refreshed, so we just put back the request to the queue (Cannot happen when running the queue in serial)
                    ///
                    /// This is done leveraging 2 error types. When ClientError.RefreshingToken is returned, we put back the request on the queue.
                    /// But when ClientError.TokenRefreshed is returned, just retry the execution.
                    /// This is done because we want to make sure that when the queue is running serial, there order is kept.
                    self.refreshToken { refreshResult in
                        complete(.failure(refreshResult))
                    }
                }
            }
            log.debug(
                urlRequest.privacySafeDiagnosticSummary(state: .resumed),
                subsystems: .httpRequests
            )
            permit.attachCancellation { task.cancel() }
            budget?.attach(task)
            do {
                try assertNetworkOwner(); try endpoint.localMlsGuard?()
                if let deadline = endpoint.localMlsDeadline, deadline <= Date() { throw ClientError.Unexpected(endpoint.localMlsTimeoutReason) }
                if budget?.isFinished != true {
                    traceListHttp("network_resumed")
                    task.resume()
                } else { task.cancel(); permit.release() }
            } catch { task.cancel(); permit.release(); complete(.failure(error)) }
            }, priority: isListRequest ? .metadata : .normal,
               reject: { complete(.failure(ClientError.Unexpected("network_queue_retired_or_full"))) })
        }
    }
    
    private func refreshToken(completion: @escaping (ClientError) -> Void) {
        guard !isRefreshingToken else {
            completion(ClientError.RefreshingToken())
            return
        }

        // AuthenticationRepository owns token-fetch mode for the full single-flight cycle. It
        // keeps this queue suspended until every joined completion has chosen retry/failure.
        // Entering/exiting here as well can resume the queue in the middle of completion delivery.
        guard let tokenRefresher else {
            completion(ClientError.MissingTokenProvider())
            return
        }
        tokenRefresher { error in
            if let error = error as? ClientError {
                completion(error)
            } else if let error {
                completion(ClientError(with: error))
            } else {
                completion(ClientError.TokenRefreshed())
            }
        }
    }
    
    private func isConnectionError(_ error: Error) -> Bool {
        // We only retry transient errors like connectivity stuff or HTTP 5xx errors
        ClientError.isEphemeral(error: error)
    }
    
    func uploadAttachment(
        _ attachment: AnyMessageAttachment,
        progress: ((Double) -> Void)?,
        completion: @escaping (Result<UploadedAttachment, Error>) -> Void
    ) {
        let uploadOperation = AsyncOperation(maxRetries: maximumRequestRetries) { [weak self] operation, done in
            self?.uploader.upload(attachment, progress: progress) { result in
                switch result {
                case let .failure(error) where self?.isConnectionError(error) == true:
                    // Do not retry unless its a connection problem and we still have retries left
                    if operation.canRetry {
                        done(.retry)
                    } else {
                        completion(result)
                        done(.continue)
                    }
                case .success, .failure:
                    completion(result)
                    done(.continue)
                }
            }
        }
        operationQueue.addOperation(uploadOperation)
    }
    
    func uploadVideoThumbnail(
        attachment: AnyMessageAttachment,
        progress: ((Double) -> Void)? = nil,
        completion: @escaping (Result<UploadedAttachment, Error>) -> Void
    ) {
        let uploadOperation = AsyncOperation(maxRetries: 0) { [weak self] operation, done in
            self?.uploader.upload(attachment, progress: progress) { result in
                switch result {
                case let .failure(error) where self?.isConnectionError(error) == true:
                    // Do not retry unless its a connection problem and we stil     l have retries left
                    if operation.canRetry {
                        done(.retry)
                    } else {
                        completion(result)
                        done(.continue)
                    }
                case .success, .failure:
                    completion(result)
                    done(.continue)
                }
            }
        }
        operationQueue.addOperation(uploadOperation)
    }
    
    func uploadUserAvatar(_ avatarData: Data, completion: @escaping (Result<AvatarUploadPayload, Error>) -> Void) {
        self.uploader.uploadUserAvatar(avatarData, progress: nil, completion: completion)
    }

    func downloadChannelAttachment(_ attachment: ChannelAttachmentPayload,
                                   progress: ((Double) -> Void)?,
                                   completion: @escaping(Result<DownloadedAttachment, Error>) -> Void) {
        let downloadOperation = AsyncOperation(maxRetries: 1) { [weak self] operation, done in
            self?.downloader.downloadChannelAttachment(attachment, progress: progress, completion: { result in
                switch result {
                case let .failure(error) where self?.isConnectionError(error) == true:
                    // Do not retry unless its a connection problem and we still have retries left
                    if operation.canRetry {
                        done(.retry)
                    } else {
                        completion(result)
                        done(.continue)
                    }
                case .success, .failure:
                    completion(result)
                    done(.continue)
                }
            })
        }

        operationQueue.addOperation(downloadOperation)
    }

    func downloadMessageAttachments(_ attachments: [AnyMessageAttachment],
                                   progress: ((Double) -> Void)?,
                                    completion: @escaping(AttachmentsDownloadResult) -> Void) {
        var attachmentsDownloadResult = AttachmentsDownloadResult(with: attachments)

        for attachment in attachments {
            let downloadOperation = AsyncOperation(maxRetries: 1) { [weak self] operation, done in
                self?.downloader.downloadMessageAttachment(attachment, progress: progress, completion: { result in
                    switch result {
                    case let .failure(error) where self?.isConnectionError(error) == true:
                        // Do not retry unless its a connection problem and we still have retries left
                        if operation.canRetry {
                            done(.retry)
                        } else {
                            attachmentsDownloadResult.results.append(result)
                            done(.continue)
                        }
                    case .success, .failure:
                        attachmentsDownloadResult.results.append(result)
                        done(.continue)
                    }
                    if attachmentsDownloadResult.isFinished {
                        completion(attachmentsDownloadResult)
                    }
                })
            }

            operationQueue.addOperation(downloadOperation)
        }


    }

//    func downloadAttachments(
//        _ attachment: [AnyMessageAttachment],
//        progress: ((Double) -> Void)?,
//        completion: @escaping (AttachmentDownloadResult) -> Void
//    ) {
//        downloader.download(attachments: attachment, completion: completion)
//    }

    func flushRequestsQueue() {
        sessionNetworkBudget.invalidate()
        operationQueue.cancelAllOperations()
    }
    
    func enterRecoveryMode() {
        // Pauses all the regular requests until recovery is completed.
        log.debug("Entering recovery mode", subsystems: .offlineSupport)
        isInRecoveryMode = true
        operationQueue.isSuspended = true
    }
    
    func exitRecoveryMode() {
        // Once recovery is done, regular requests can go through again.
        log.debug("Leaving recovery mode", subsystems: .offlineSupport)
        isInRecoveryMode = false
        operationQueue.isSuspended = false
    }
    
    func enterTokenFetchMode() {
        // We stop the queue so no more operations are triggered during the refresh
        isRefreshingToken = true
        operationQueue.isSuspended = true
    }
    
    func exitTokenFetchMode() {
        // We restart the queue now that token refresh is completed
        isRefreshingToken = false
        operationQueue.isSuspended = false
    }
}

extension URLRequest {
    var queryItems: [URLQueryItem] {
        if let url = url,
           let urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let queryItems = urlComponents.queryItems {
            return queryItems
        }
        return []
    }
}
