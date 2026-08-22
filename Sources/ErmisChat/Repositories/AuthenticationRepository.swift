//
// Copyright 2025 Ermis Inc.
//

import Foundation
import ErmisShared

public typealias TokenProvider = (@escaping (Result<Token, Error>) -> Void) -> Void

enum EnvironmentState {
    case firstConnection
    case newToken
    case newUser

    init(currentUserId: UserId?, newUserId: UserId) {
        if currentUserId == nil {
            self = .firstConnection
        } else if currentUserId == newUserId {
            self = .newToken
        } else {
            self = .newUser
        }
    }
}

protocol AuthenticationRepositoryDelegate: AnyObject {
    func didFinishSettingUpAuthenticationEnvironment(for state: EnvironmentState)
    func logOutUser(completion: @escaping () -> Void)
}

/// Thread-safe ownership for one token-fetch cycle.
///
/// Every refresh requester joins the active cycle. Exactly one caller is allowed to start the
/// token provider, and exactly one terminal callback drains the joined completions. This avoids
/// racing an asynchronous `isGettingToken` setter against simultaneous expired-token responses.
final class AuthenticationTokenFetchSingleFlight: @unchecked Sendable {
    typealias Completion = (Error?) -> Void

    struct JoinOutcome {
        let cycleId: UUID
        let shouldStart: Bool
    }

    private let lock = NSLock()
    private var activeCycleId: UUID?
    private var completions: [Completion] = []
    private var pendingDeliveryCount = 0

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeCycleId != nil
    }

    /// Returns one stable identifier for every requester joining the same cycle.
    func join(
        _ completion: @escaping Completion,
        onStart: () -> Void = {}
    ) -> JoinOutcome {
        lock.lock()
        completions.append(completion)
        if let activeCycleId {
            lock.unlock()
            return JoinOutcome(cycleId: activeCycleId, shouldStart: false)
        }
        let cycleId = UUID()
        activeCycleId = cycleId
        lock.unlock()

        // The cycle is owned before entering the external mode, but the external callback must
        // never execute while `lock` is held. `enterTokenFetchMode()` may synchronously touch
        // operation state which can re-enter authentication through an expired request.
        onStart()
        return JoinOutcome(cycleId: cycleId, shouldStart: true)
    }

    func isActive(cycleId: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeCycleId == cycleId
    }

    /// Ends the active cycle once and returns all callbacks owned by it.
    /// Passing a cycle identifier prevents a late callback from ending a newer refresh cycle.
    func finish(
        cycleId expectedCycleId: UUID? = nil
    ) -> (wasActive: Bool, completions: [Completion]) {
        lock.lock()
        defer { lock.unlock() }
        guard let currentCycleId = activeCycleId else { return (false, []) }
        if let expectedCycleId, expectedCycleId != currentCycleId {
            return (false, [])
        }
        activeCycleId = nil
        pendingDeliveryCount += 1
        let pending = completions
        completions.removeAll(keepingCapacity: true)
        return (true, pending)
    }

    /// Marks one detached completion delivery as finished. The external token-fetch mode may only
    /// be left when no newer cycle is active and no older/newer completion batch is still pending.
    /// This keeps the API operation queue suspended while refresh callbacks decide whether their
    /// requests should retry or fail.
    @discardableResult
    func completeDelivery(onBecomeIdle: () -> Void = {}) -> Bool {
        lock.lock()
        guard pendingDeliveryCount > 0 else {
            lock.unlock()
            return false
        }
        pendingDeliveryCount -= 1
        let becameIdle = pendingDeliveryCount == 0 && activeCycleId == nil
        lock.unlock()

        guard becameIdle else { return false }
        // As above, operation-queue transitions are external work and must stay outside the lock.
        onBecomeIdle()
        return true
    }
}

/// A token provider is an integration callback and can accidentally invoke its result more than
/// once. Only the first result may advance or retry the authentication state machine.
private final class AuthenticationTokenProviderResultGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didConsumeResult = false

    func consumeIfFirst() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didConsumeResult else { return false }
        didConsumeResult = true
        return true
    }
}

class AuthenticationRepository {
    private enum Constants {
        /// Maximum amount of consecutive token refresh attempts before failing
        static let maximumTokenRefreshAttempts = 3
    }

    private let tokenQueue: DispatchQueue = DispatchQueue(label: "network.ermis.auth-repository", attributes: .concurrent)
    /// Authentication completions are integration callbacks. Delivering them on a dedicated
    /// serial queue prevents a synchronous waiter/connect callback from re-entering the refresh
    /// state machine on the same stack.
    private let callbackQueue = DispatchQueue(label: "network.ermis.auth-repository.callbacks")
    private let tokenFetchSingleFlight = AuthenticationTokenFetchSingleFlight()

    private var _consecutiveRefreshFailures: Int = 0
    private var _currentUserId: UserId?
    private var _currentToken: Token?
    private var _tokenExpirationRetryStrategy: RetryStrategy
    private var _tokenProvider: TokenProvider?
    private var _tokenWaiters: [String: (Result<Token, Error>) -> Void] = [:]
    private var _tokenProviderTimer: TimerControl?
    private var _connectionProviderTimer: TimerControl?

    var isGettingToken: Bool {
        tokenFetchSingleFlight.isActive
    }

    private var consecutiveRefreshFailures: Int {
        tokenQueue.sync { _consecutiveRefreshFailures }
    }

    private(set) var currentUserId: UserId? {
        get { tokenQueue.sync { _currentUserId } }
        set { tokenQueue.async(flags: .barrier) { self._currentUserId = newValue }}
    }

    private(set) var currentToken: Token? {
        get { tokenQueue.sync { _currentToken } }
        set { tokenQueue.async(flags: .barrier) {
            self._currentToken = newValue
            self._currentUserId = newValue?.userId
        }}
    }

    private(set) var tokenProvider: TokenProvider? {
        get { tokenQueue.sync { _tokenProvider } }
        set { tokenQueue.async(flags: .barrier) { self._tokenProvider = newValue }}
    }

    private var tokenProviderTimer: TimerControl? {
        get { tokenQueue.sync { _tokenProviderTimer } }
        set { tokenQueue.async(flags: .barrier) {
            self._tokenProviderTimer = newValue
        }}
    }
    
    private var connectionProviderTimer: TimerControl? {
        get { tokenQueue.sync { _connectionProviderTimer } }
        set { tokenQueue.async(flags: .barrier) {
            self._connectionProviderTimer = newValue
        }}
    }

    weak var delegate: AuthenticationRepositoryDelegate?

    private let apiClient: APIClient
    private let databaseContainer: DatabaseContainer
    private let connectionRepository: ConnectionRepository
    private let timerType: Timer.Type
    public var projectId: String
    private var deviceIdStore = MlsDeviceIdStore(defaults: .standard)

    var currentDeviceId: String {
        guard let userId = currentUserId else { return "" }
        return deviceIdStore.canonicalDeviceId(for: userId) ?? ""
    }

    init(
        apiClient: APIClient,
        databaseContainer: DatabaseContainer,
        connectionRepository: ConnectionRepository,
        tokenExpirationRetryStrategy: RetryStrategy,
        projectId: String,
        timerType: Timer.Type
    ) {
        self.apiClient = apiClient
        self.databaseContainer = databaseContainer
        self.connectionRepository = connectionRepository
        _tokenExpirationRetryStrategy = tokenExpirationRetryStrategy
        self.timerType = timerType
        self.projectId = projectId
        fetchCurrentUser(of: projectId)

        if let currentUserId = currentUserId {
            generateDeviceIdIfNeeded(for: currentUserId)
            connectionRepository.updateWebSocketEndpoint(with: currentUserId, deviceId: currentDeviceId)
        }
    }

    private func generateDeviceIdIfNeeded(for userId: String) {
        _ = deviceIdStore.canonicalDeviceId(for: userId)
    }

    func configureDeviceIdStore(_ store: MlsDeviceIdStore) {
        deviceIdStore = store
        guard let currentUserId else { return }
        generateDeviceIdIfNeeded(for: currentUserId)
        connectionRepository.updateWebSocketEndpoint(with: currentUserId, deviceId: currentDeviceId)
    }

    func update(token: Token, userInfo: UserInfo) {
        if currentUserId == nil {
            currentUserId = token.userId
            connectionRepository.updateWebSocketEndpoint(with: token, userInfo: userInfo, deviceId: currentDeviceId)
            setToken(token: token, completeTokenWaiters: true)
            delegate?.didFinishSettingUpAuthenticationEnvironment(for: .firstConnection)
        }
    }

    /// Fetches the user saved in the database, if exists
    func fetchCurrentUser(of projectId: String) {
        var currentUserId: UserId?

        let context = databaseContainer.viewContext
        if Thread.isMainThread {
            currentUserId = context.currentUser?.users.first?.userId
        } else {
            context.performAndWait {
                currentUserId = context.currentUser?.users.first?.userId
            }
        }
        if self.currentUserId == nil, let currentUserId {
            connectionRepository.updateWebSocketEndpoint(with: currentUserId, deviceId: currentDeviceId)
        }
        self.currentUserId = currentUserId
    }

    /// Sets the user token. This method is only needed to perform API calls without connecting as a user.
    /// You should only use this in special cases like a notification service or other background process
    /// - Parameters:
    ///   - token: The token for the new user
    ///   - completeTokenWaiters: A boolean indicating if the token should be passed to the requests that are awaiting
    func setToken(token: Token, completeTokenWaiters: Bool) {
        updateToken(token: token, notifyTokenWaiters: completeTokenWaiters)
    }

    /// Register new user with email and password
    /// - Parameters:
    ///   - email: The email of user.
    ///   - password: The passwork of account.
    ///   - completion: The completion to call with the results.
    func register(email: String,
                  password: String,
                  apiKey: String,
                  completion: @escaping ((Result<EmptyResponse, Error>) -> Void)) {
        let endpoint = Endpoint<RegisterPayload>.register(email: email,
                                                          password: password,
                                                          apiKey: apiKey)
        apiClient.request(endpoint: endpoint,
                                   completion: completion)
    }

    /// Login  with email and password
    /// - Parameters:
    ///   - email: The email of user.
    ///   - password: The passwork of account.
    ///   - completion: The completion to call with the results.
    func login(with email: String,
               password: String,
               apiKey: String,
               completion: @escaping ((Result<AuthenticationPayload, Error>) -> Void)) {
        let endpoint = Endpoint<AuthenticationPayload>.loginWithEmail(email: email, password: password, apiKey: apiKey)
        apiClient.unmanagedRequest(endpoint: endpoint, completion: completion)
    }

    /// Get otp to sign in or delete account:
    /// - Parameters:
    ///   - body: The `GetOtpRequestBody` instance .
    ///   - completion: The completion to call with the results.
    func getOTP(body: GetOtpRequestBody, completion: @escaping ((Result<EmptyResponse, Error>) -> Void)) {
        let endpoint = Endpoint<EmptyResponse>.getOTP(body: body)
        apiClient.request(endpoint: endpoint, completion: completion)
    }

    /// Login with otp:
    /// - Parameters:
    ///   - body: The `OtpLoginRequestBody` instance .
    ///   - completion: The completion to call with the results.
    func login(with body: OtpRequestBody,
               completion: @escaping ((Result<AuthenticationPayload, Error>) -> Void)) {
        let endpoint = Endpoint<AuthenticationPayload>.loginWithOTP(body: body)
        apiClient.unmanagedRequest(endpoint: endpoint, completion: completion)
    }

    /// Login with google token:
    /// - Parameters:
    ///   - googleIdToken: The google token string.
    ///   - apiKey: App apiKey string.
    ///   - completion: The completion to call with the results.
    func loginGoogle(with googleIdToken: String,
               apiKey: String,
               completion: @escaping ((Result<AuthenticationPayload, Error>) -> Void)) {
        let endpoint = Endpoint<AuthenticationPayload>.loginWithGoogle(token: googleIdToken, apiKey: apiKey)
        apiClient.unmanagedRequest(endpoint: endpoint, completion: completion)
    }

    /// Login with apple token:
    /// - Parameters:
    ///   - googleIdToken: The apple token string.
    ///   - apiKey: App apiKey string.
    ///   - completion: The completion to call with the results.
    func loginApple(with googleIdToken: String,
                    apiKey: String,
                    completion: @escaping ((Result<AuthenticationPayload, Error>) -> Void)) {
        let endpoint = Endpoint<AuthenticationPayload>.loginWithApple(token: googleIdToken, apiKey: apiKey)
        apiClient.unmanagedRequest(endpoint: endpoint, completion: completion)
    }

    /// Establishes a connection for a non anonymous user.
    /// - Parameters:
    ///   - userInfo:       The user information that will be created OR updated if it exists.
    ///   - tokenProvider:  The block to be used to get a token.
    func connectUser(userInfo: UserInfo, tokenProvider: @escaping TokenProvider, completion: @escaping (Error?) -> Void) {
        generateDeviceIdIfNeeded(for: userInfo.id)

        var logOutFirst: Bool {
            if let currentUserId = currentUserId, currentUserId.isGuest {
                return true
            }

            let state = EnvironmentState(currentUserId: currentUserId, newUserId: userInfo.id)
            return state == .newUser
        }

        executeTokenFetch(logOutFirst: logOutFirst, userInfo: userInfo, tokenProvider: tokenProvider, completion: completion)
    }

    private func executeTokenFetch(logOutFirst: Bool, userInfo: UserInfo?, tokenProvider: @escaping TokenProvider, completion: @escaping (Error?) -> Void) {
        log.assert(delegate != nil, "Delegate should not be nil at this point")

        let handleTokenFetch = { [weak self] in
            self?.tokenProvider = tokenProvider
            self?.scheduleTokenFetch(isRetry: false, userInfo: userInfo, tokenProvider: tokenProvider, completion: completion)
        }

        guard logOutFirst else {
            handleTokenFetch()
            return
        }

        if let delegate = delegate {
            delegate.logOutUser(completion: handleTokenFetch)
        } else {
            handleTokenFetch()
        }
    }

    func clearTokenProvider() {
        tokenProvider = nil
        finishTokenFetch(error: ClientError.MissingTokenProvider())
    }

    func cancelTimers() {
        connectionProviderTimer?.cancel()
        tokenProviderTimer?.cancel()
    }

    func logOutUser() {
        log.debug("Logging out user", subsystems: .authentication)
        clearTokenProvider()
        currentToken = nil
        currentUserId = nil
    }

    func refreshToken(completion: @escaping (Error?) -> Void) {
        guard let tokenProvider = tokenProvider else {
            let error = ClientError.MissingTokenProvider()
            log.assertionFailure(error.localizedDescription)
            callbackQueue.async {
                completion(error)
            }
            return
        }

        scheduleTokenFetch(isRetry: false, userInfo: nil, tokenProvider: tokenProvider, completion: completion)
    }

    func prepareEnvironment(
        userInfo: UserInfo?,
        newToken: Token
    ) {
        let state = EnvironmentState(currentUserId: currentUserId, newUserId: newToken.userId)

        log.assert(delegate != nil, "Delegate should not be nil at this point")

        if let userInfo = userInfo, !newToken.userId.isGuest {
            log.assert(
                userInfo.id == newToken.userId,
                "The id of the retrieved token should match the user information passed to connect"
            )
        }

        switch state {
        case .firstConnection, .newToken:
            connectionRepository.updateWebSocketEndpoint(with: newToken, userInfo: userInfo, deviceId: currentDeviceId)
            setToken(token: newToken, completeTokenWaiters: true)
            delegate?.didFinishSettingUpAuthenticationEnvironment(for: state)

        case .newUser:
            completeTokenWaiters(token: nil)
            connectionRepository.updateWebSocketEndpoint(with: newToken, userInfo: userInfo, deviceId: currentDeviceId)
            setToken(token: newToken, completeTokenWaiters: false)
            delegate?.didFinishSettingUpAuthenticationEnvironment(for: state)
        }
    }

    func provideToken(timeout: TimeInterval = 10, completion: @escaping (Result<Token, Error>) -> Void) {
        let waiterToken = String.newUniqueId
        let immediateToken: Token? = tokenQueue.sync(flags: .barrier) {
            if let token = _currentToken {
                return token
            }
            _tokenWaiters[waiterToken] = completion
            return nil
        }

        if let token = immediateToken {
            // `RequestEncoder` has a synchronous compatibility path which waits for this
            // completion. The caller can already be executing on `callbackQueue` (for example,
            // the initial authentication completion starts the WebSocket connection). Enqueuing
            // the already-available token back onto that same serial queue deadlocks until the
            // encoder/waiter timeout. We have left `tokenQueue`'s barrier at this point, so an
            // immediate synchronous delivery is safe and is required by that compatibility path.
            completion(.success(token))
            return
        }

        connectionProviderTimer = timerType.schedule(timeInterval: timeout, queue: callbackQueue) { [weak self] in
            guard let self = self else { return }
            let timedOutCompletion = self.tokenQueue.sync(flags: .barrier) {
                self._tokenWaiters.removeValue(forKey: waiterToken)
            }
            timedOutCompletion?(.failure(ClientError.WaiterTimeout()))
        }
    }

    func completeTokenWaiters(token: Token?) {
        updateToken(token: token, notifyTokenWaiters: true)
    }

    private func updateToken(token: Token?, notifyTokenWaiters: Bool) {
        let waiters: [String: (Result<Token, Error>) -> Void] = tokenQueue.sync(flags: .barrier) {
            _currentToken = token
            _currentUserId = token?.userId
            guard notifyTokenWaiters else { return [:] }
            let waiters = _tokenWaiters
            _tokenWaiters = [:]
            return waiters
        }

        guard !waiters.isEmpty else { return }
        callbackQueue.async {
            waiters.forEach { waiter in
                if let token = token {
                    waiter.value(.success(token))
                } else {
                    waiter.value(.failure(ClientError.MissingToken()))
                }
            }
        }
    }

    private func scheduleTokenFetch(
        isRetry: Bool,
        tokenFetchCycleId: UUID? = nil,
        userInfo: UserInfo?,
        tokenProvider: @escaping TokenProvider,
        completion: @escaping (Error?) -> Void
    ) {
        let cycleId: UUID
        if !isRetry {
            let outcome = tokenFetchSingleFlight.join(
                completion,
                onStart: { apiClient.enterTokenFetchMode() }
            )
            guard outcome.shouldStart else {
                log.debug("[AuthRefresh] implementation=single_flight_v2 state=joined", subsystems: .authentication)
                return
            }
            log.info("[AuthRefresh] implementation=single_flight_v2 state=started", subsystems: .authentication)
            cycleId = outcome.cycleId
        } else {
            // Retry is owned by the existing cycle and must never create a second one.
            guard let existingCycleId = tokenFetchCycleId,
                  tokenFetchSingleFlight.isActive(cycleId: existingCycleId) else { return }
            cycleId = existingCycleId
        }

        let interval = tokenQueue.sync(flags: .barrier) {
            _tokenExpirationRetryStrategy.getDelayAfterTheFailure()
        }
        tokenProviderTimer = timerType.schedule(
            timeInterval: interval,
            queue: callbackQueue
        ) { [weak self] in
            log.debug("[AuthRefresh] implementation=single_flight_v2 state=provider_timer_fired", subsystems: .authentication)
            self?.getToken(cycleId: cycleId, userInfo: userInfo, tokenProvider: tokenProvider)
        }
    }

    private func getToken(cycleId: UUID, userInfo: UserInfo?, tokenProvider: @escaping TokenProvider) {
        // A timer can fire after logout/cancellation. It must not resurrect a completed cycle or
        // invoke a stale token provider.
        guard tokenFetchSingleFlight.isActive(cycleId: cycleId) else {
            log.debug("Ignoring token timer after refresh cycle finished", subsystems: .authentication)
            return
        }

        let onCompletion: (Error?) -> Void = { [weak self] error in
            guard let self = self else { return }
            guard self.tokenFetchSingleFlight.isActive(cycleId: cycleId) else {
                log.debug("Ignoring stale token refresh completion", subsystems: .authentication)
                return
            }
            if let error = error {
                log.error(
                    "[AUTH] state=token_fetch_failed \(PrivacySafeLogMetadata.errorFields(error))",
                    subsystems: .authentication
                )
            } else {
                log.debug("Successfully retrieved token", subsystems: .authentication)
            }

            self.tokenQueue.sync(flags: .barrier) {
                self._consecutiveRefreshFailures = 0
            }
            self.finishTokenFetch(cycleId: cycleId, error: error)
        }

        guard consecutiveRefreshFailures < Constants.maximumTokenRefreshAttempts else {
            onCompletion(ClientError.TooManyFailedTokenRefreshAttempts())
            return
        }

        let onTokenReceived: (Token) -> Void = { [weak self, weak connectionRepository] token in
            guard self?.tokenFetchSingleFlight.isActive(cycleId: cycleId) == true else {
                log.debug("Ignoring token from stale refresh cycle", subsystems: .authentication)
                return
            }
            self?.prepareEnvironment(userInfo: userInfo, newToken: token)
            // We manually change the `connectionStatus` for passive client
            // to `disconnected` when environment was prepared correctly
            // (e.g. current user session is successfully restored).
            connectionRepository?.forceConnectionStatusForInactiveModeIfNeeded()
            connectionRepository?.connect(completion: onCompletion)
        }

        let retryFetchIfPossible: (Error?) -> Void = { [weak self] error in
            guard let self = self else { return }
            self.tokenQueue.async(flags: .barrier) {
                self._consecutiveRefreshFailures += 1
            }
            guard self.consecutiveRefreshFailures < Constants.maximumTokenRefreshAttempts else {
                onCompletion(error ?? ClientError.TooManyFailedTokenRefreshAttempts())
                return
            }

            // We don't need to pass the completion again, as it is already present in `tokenRequestCompletions`
            self.scheduleTokenFetch(
                isRetry: true,
                tokenFetchCycleId: cycleId,
                userInfo: userInfo,
                tokenProvider: tokenProvider,
                completion: { _ in }
            )
        }

        log.debug("Requesting a new token", subsystems: .authentication)
        let resultGate = AuthenticationTokenProviderResultGate()
        tokenProvider { [weak self] result in
            guard resultGate.consumeIfFirst() else {
                log.warning("Token provider called its completion more than once", subsystems: .authentication)
                return
            }
            guard self?.tokenFetchSingleFlight.isActive(cycleId: cycleId) == true else {
                log.debug("Ignoring result from stale token provider", subsystems: .authentication)
                return
            }
            switch result {
            case let .success(newToken):
                onTokenReceived(newToken)
                self?.tokenQueue.sync(flags: .barrier) {
                    self?._tokenExpirationRetryStrategy.resetConsecutiveFailures()
                }
            case let .failure(error):
                log.info("[AUTH] state=token_provider_failed \(PrivacySafeLogMetadata.errorFields(error))")
                retryFetchIfPossible(error)
            }
        }
    }

    private func finishTokenFetch(cycleId: UUID? = nil, error: Error?) {
        let finished = tokenFetchSingleFlight.finish(cycleId: cycleId)
        guard finished.wasActive else { return }

        // Connection completion may be synchronous when the socket already has a connection id.
        // Always detach the joined completions from that stack before requests are allowed to
        // retry. This is deliberately not the main queue: refresh callbacks are SDK plumbing and
        // a reconnect burst must not consume the UI stack/thread.
        callbackQueue.async { [self] in
            finished.completions.forEach { $0(error) }
            tokenFetchSingleFlight.completeDelivery {
                apiClient.exitTokenFetchMode()
                log.info("[AuthRefresh] implementation=single_flight_v2 state=idle", subsystems: .authentication)
            }
        }
    }
}

extension ClientError {
    public class TooManyFailedTokenRefreshAttempts: ClientError {
        override public var localizedDescription: String {
            """
                Token fetch has failed more than 10 times.
                Please make sure that your `tokenProvider` is correctly functioning.
            """
        }
    }
}

private extension UserId {
    var isGuest: Bool {
        hasPrefix(UserRole.guest.rawValue)
    }
}
