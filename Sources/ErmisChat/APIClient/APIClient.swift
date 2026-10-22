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
    private var callback: ((Result<Response, Error>) -> Void)?
    private var timer: DispatchSourceTimer?
    private var task: URLSessionTask?
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return callback == nil }
    init(deadline: Date, completion: @escaping (Result<Response, Error>) -> Void) {
        self.deadline = deadline; callback = completion
        let timer = DispatchSource.makeTimerSource(queue: .global())
        self.timer = timer
        timer.schedule(deadline: .now() + max(0, deadline.timeIntervalSinceNow))
        timer.setEventHandler { [weak self] in self?.finish(.failure(ClientError.Unexpected("key_package_operation_expired"))) }
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
        completion?(expired ? .failure(ClientError.Unexpected("key_package_operation_expired")) : result)
    }
}

/// An object which making api request to Ermis Chat servers.
class APIClient {
    /// The URL session used for all requests.
    let session: URLSession
    
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
        let budget = endpoint.localMlsDeadline.map { MlsRequestCompletion<Response>(deadline: $0, completion: completion) }
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
        // Scoped MLS retries only one authentication refresh, never ambiguous transport.
        AsyncOperation(maxRetries: endpoint.localMlsGuard == nil ? maximumRequestRetries : 1) { [weak self] operation, done in
            guard let self = self else {
                done(.continue)
                return
            }

            do {
                try endpoint.localMlsGuard?()
                if let deadline = endpoint.localMlsDeadline, deadline <= Date() { throw ClientError.Unexpected("key_package_operation_expired") }
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
            
            self.executeRequest(endpoint: endpoint, allowAuthRefresh: endpoint.localMlsGuard == nil || operation.canRetry) { [weak self] result in
                switch result {
                case .failure(_ as ClientError.RefreshingToken):
                    // Requeue request
                    self?.request(endpoint: endpoint, completion: completion)
                    done(.continue)
                case .failure(_ as ClientError.TokenRefreshed):
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
        // This gate also releases AsyncOperation when encoding/registration/refresh never calls back.
        let budget = endpoint.localMlsDeadline.map { MlsRequestCompletion<Response>(deadline: $0, completion: completion) }
        let complete: (Result<Response, Error>) -> Void = { result in
            if let budget { budget.finish(result) } else { completion(result) }
        }
        if let deadline = endpoint.localMlsDeadline, deadline <= Date() {
            complete(.failure(ClientError.Unexpected("key_package_operation_expired"))); return
        }
        encoder.encodeRequest(for: endpoint) { [weak self] (requestResult) in
            if budget?.isFinished == true { return }
            var urlRequest: URLRequest
            do {
                try endpoint.localMlsGuard?()
                if let deadline = endpoint.localMlsDeadline, deadline <= Date() {
                    throw ClientError.Unexpected("key_package_operation_expired")
                }
                urlRequest = try requestResult.get()
                if let deadline = endpoint.localMlsDeadline {
                    guard deadline > Date() else { throw ClientError.Unexpected("key_package_operation_expired") }
                    urlRequest.timeoutInterval = min(5, deadline.timeIntervalSinceNow)
                }
            } catch {
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

            log.debug(
                urlRequest.privacySafeDiagnosticSummary(state: .started),
                subsystems: .httpRequests
            )

            guard let self = self else {
                log.warning("Callback called while self is nil", subsystems: .httpRequests)
                complete(.failure(ClientError("APIClient was deallocated")))
                return
            }
            
            let task = self.session.dataTask(with: urlRequest) { [decoder = self.decoder] (data, response, error) in
                if budget?.isFinished == true { return }
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
                    complete(.success(decodedResponse))
                } catch {
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
            budget?.attach(task)
            do {
                try endpoint.localMlsGuard?()
                if let deadline = endpoint.localMlsDeadline, deadline <= Date() { throw ClientError.Unexpected("key_package_operation_expired") }
                if budget?.isFinished != true { task.resume() }
            } catch { task.cancel(); complete(.failure(error)) }
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
