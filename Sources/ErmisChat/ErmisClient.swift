//
// Copyright 2025 Ermis Inc.
//

import AVFoundation
import CoreData
import Foundation
import ErmisShared

/// Controls whether logout preserves or destroys the authenticated user's local cache.
public enum LogoutLocalDataPolicy: Equatable {
    /// Clear authentication/runtime state while retaining user-scoped messages, cursors and MLS state.
    case preserve
    /// Explicitly destroy the current user's Core Data cache, MLS provider, device ID and cursors.
    case purgeCurrentUser
}

/// The root object representing a Ermis Chat.
///
/// Typically, an app contains just one instance of `ErmisClient`. However, it's possible to have multiple instances if your use
/// case requires it.
public class ErmisClient {
    /// The `UserId` of the currently logged in user.
    public var currentUserId: UserId? {
        authenticationRepository.currentUserId
    }

    /// The token of the current user.
    var currentToken: Token? {
        authenticationRepository.currentToken
    }

    public var chainId: Int?
    public var clientId: String?
    public private(set) var projectId: String

    var rootProjectid: String

    /// The current connection status of the client.
    ///
    /// To observe changes in the connection status, create an instance of `ConnectionController`, and use it to receive
    /// callbacks when the connection status changes.
    ///
    public var connectionStatus: ConnectionStatus {
        connectionRepository.connectionStatus
    }

    /// The config object of the `ErmisClient` instance.
    ///
    /// This value can't be mutated and can only be set when initializing a new `ErmisClient` instance.
    ///
    public let config: ErmisClientConfig

    /// A `Worker` represents a single atomic piece of functionality.
    ///
    /// `ErmisClient` initializes a set of background workers that keep observing the current state of the system and perform
    /// work if needed (i.e. when a new message pending sent appears in the database, a worker tries to send it.)
    private(set) var backgroundWorkers: [Worker] = []

    /// Keeps a weak reference to the active channel list controllers to ensure a proper recovery when coming back online
    private(set) var activeChannelListControllers = ThreadSafeWeakCollection<ChannelListController>()
    private(set) var activeChannelControllers = ThreadSafeWeakCollection<ChannelController>()

    /// Background worker that takes care about client connection recovery when the Internet comes back OR app transitions from background to foreground.
    private(set) var connectionRecoveryHandler: ConnectionRecoveryHandler?

    /// The notification center used to send and receive notifications about incoming events.
    private(set) var eventNotificationCenter: EventNotificationCenter

    var notificationTokenProvider: NotificationTokenProviding

    /// The registry that contains all the attachment payloads associated with their attachment types.
    /// For the meantime this is a static property to avoid breaking changes. On v5, this can be changed.
    private(set) static var attachmentTypesRegistry: [AttachmentType: AttachmentPayload.Type] = [
        .image: ImageAttachmentPayload.self,
        .video: VideoAttachmentPayload.self,
        .audio: AudioAttachmentPayload.self,
        .file: FileAttachmentPayload.self,
        .voiceRecording: VoiceRecordingAttachmentPayload.self
    ]

    let connectionRepository: ConnectionRepository

    let authenticationRepository: AuthenticationRepository

    let messageRepository: MessageRepository

    let offlineRequestsRepository: OfflineRequestsRepository

    let syncRepository: SyncRepository

    let callRepository: CallRepository

    let channelRepository: ChannelRepository

    let walletRepository: WalletRepository

    let e2eRepository: E2eRepository

    let mlsClient: MlsClient

    /// One SDK-owned background transfer session for this app/environment. It is intentionally
    /// shared across accounts; durable opaque task mappings preserve account isolation.
    let e2eeAttachmentTransferCoordinator: E2eeBackgroundTransferCoordinator?

    /// User-initiated full-download fallback for E2EE originals. It is separate from the upload
    /// worker and never holds the MLS mutation executor while performing network or file I/O.
    private lazy var e2eeAttachmentOriginalDownloadCoordinator =
        E2eeAttachmentOriginalDownloadCoordinator(
            apiClient: apiClient,
            database: databaseContainer,
            ciphertextDirectory: config.e2eeAttachmentStorageFolderURL?
                .appendingPathComponent("OriginalDownloads", isDirectory: true),
            durableCiphertextProvider: { [weak self] input in
                guard let self,
                      let accountId = self.currentUserId,
                      let transferCoordinator = self.e2eeAttachmentTransferCoordinator else {
                    throw E2eeAttachmentOriginalDownloadError.backgroundTransferUnavailable
                }

                let lease = try await transferCoordinator.acquireVerifiedBackgroundCiphertext(
                    accountId: accountId,
                    cid: input.cid.rawValue,
                    attachmentId: input.attachmentId,
                    assetId: input.assetId,
                    expectedCiphertextSize: Int64(clamping: input.expectedCiphertextBytes),
                    expectedCiphertextSha256: input.expectedCiphertextSha256,
                    requestProvider: { [weak self] in
                        guard let self else {
                            throw E2eeAttachmentOriginalDownloadError.backgroundTransferUnavailable
                        }
                        let grant = try await self.apiClient.e2eeAttachmentDownloadGrant(
                            cid: input.cid,
                            attachmentId: input.attachmentId,
                            assetId: input.assetId
                        )
                        var request = URLRequest(url: grant.downloadURL)
                        request.httpMethod = "GET"
                        return request
                    },
                    progress: { completed, total in
                        input.progress(.init(
                            phase: .downloading,
                            completedCiphertextBytes: UInt64(clamping: completed),
                            totalCiphertextBytes: UInt64(clamping: total)
                        ))
                    }
                )
                return .init(localURL: lease.localURL) {
                    await lease.consume()
                }
            }
        )

    func makeMessagesPaginationStateHandler() -> MessagesPaginationStateHandling {
        MessagesPaginationStateHandler()
    }

    /// The `APIClient` instance `Client` uses to communicate with Ermis REST API.
    let apiClient: APIClient

    /// The `WebSocketClient` instance `Client` uses to communicate with Ermis WS servers.
    let webSocketClient: WebSocketClient?

    /// The `DatabaseContainer` instance `Client` uses to store and cache data.
    let databaseContainer: DatabaseContainer

    /// Used as a bridge to communicate between the host app and the notification extension. Holds the state for the app lifecycle.
    let extensionLifecycle: NotificationExtensionLifecycle

    /// The environment object containing all dependencies of this `Client` instance.
    private let environment: Environment

    /// The default configuration of URLSession to be used for both the `APIClient` and `WebSocketClient`. It contains all
    /// required header auth parameters to make a successful request.
    private var urlSessionConfiguration: URLSessionConfiguration

    /// Creates a new instance of `ErmisClient`.
    /// - Parameter config: The config object for the `Client`. See `ErmisClientConfig` for all configuration options.
    public convenience init(
        config: ErmisClientConfig,
        token: Token?,
        notificationTokenProvider: NotificationTokenProviding?
    ) {
        var resolvedConfig = config
        if resolvedConfig.localStorageScope == .automatic {
            resolvedConfig.localStorageScope = token.map { .user($0.userId) } ?? .inMemory
        }
        var environment = Environment()

        if !resolvedConfig.isClientInActiveMode {
            environment.webSocketClientBuilder = nil
        }

        self.init(
            config: resolvedConfig,
            clientId: token?.clientId,
            projectId: token?.projectId ?? "",
            rootProjectId: token?.projectId ?? "",
            chainId: token?.chainId,
            environment: environment,
            notificationTokenProvider: notificationTokenProvider ?? DefaultNotificationTokenProvider(),
            factory: .init(config: resolvedConfig, environment: environment)
        )

        if let token {
            authenticationRepository.setToken(token: token, completeTokenWaiters: true)
        }
    }

    /// Creates a new instance `ErmisClient`.
    ///
    /// - Parameters:
    ///   - config: The config object for the `ErmisClient`.
    ///   - environment: An object with all external dependencies the new `ErmisClient` instance should use.
    ///   - factory: A factory component to help creating all `ErmisClient` dependencies.
    init(
        config: ErmisClientConfig,
        clientId: String?,
        projectId: String,
        rootProjectId: String,
        chainId: Int?,
        environment: Environment,
        notificationTokenProvider: NotificationTokenProviding,
        factory: ErmisClientFactory
    ) {
        self.config = config
        self.clientId = clientId
        self.projectId = projectId
        self.rootProjectid = rootProjectId
        self.chainId = chainId
        self.environment = environment
        if !Bundle.main.isAppExtension {
            // Playback plaintext belongs to a process-local gallery session. A previous process
            // cannot still own it, so remove stale files eagerly even if this launch never opens
            // an attachment. The cleanup helper is safe when multiple clients share a process.
            try? E2eeAttachmentOriginalDownloadCoordinator.cleanupStalePlaintextAtMainAppLaunch()
        }
        let deviceIdStore = MlsDeviceIdStore(applicationGroupIdentifier: config.applicationGroupIdentifier)
        let mlsClient = MlsClient(
            storageFolderURL: config.mlsStorageFolderURL,
            legacyStorageFolderURLs: [config.localStorageFolderURL].compactMap { $0 },
            applicationGroupIdentifier: config.applicationGroupIdentifier,
            deviceIdStore: deviceIdStore
        )
        let e2eeAttachmentTransferCoordinator: E2eeBackgroundTransferCoordinator?
        if !Bundle.main.isAppExtension,
           let transferRootURL = config.e2eeAttachmentStorageFolderURL {
            let descriptor = E2eeBackgroundSessionDescriptor(
                bundleIdentifier: Bundle.main.bundleIdentifier ?? "network.ermis.host",
                endpoint: config.endpointEnviroment.baseURL,
                applicationGroupIdentifier: config.applicationGroupIdentifier
            )
            e2eeAttachmentTransferCoordinator = E2eeBackgroundTransferCoordinatorRegistry.coordinator(
                descriptor: descriptor,
                rootURL: transferRootURL,
                applicationGroupIdentifier: config.applicationGroupIdentifier
            )
        } else {
            e2eeAttachmentTransferCoordinator = nil
        }

        urlSessionConfiguration = factory.makeUrlSessionConfiguration()
        var apiClientEncoder = factory.makeApiClientRequestEncoder()
        var webSocketEncoder = factory.makeWebSocketRequestEncoder()
        apiClientEncoder.deviceIdStore = deviceIdStore
        webSocketEncoder.deviceIdStore = deviceIdStore
        let databaseContainer = factory.makeDatabaseContainer()
        let apiClient = factory.makeApiClient(
            encoder: apiClientEncoder,
            urlSessionConfiguration: urlSessionConfiguration
        )
        let eventNotificationCenter = factory.makeEventNotificationCenter(
            databaseContainer: databaseContainer,
            currentUserId: {
                nil
            }
        )

        let e2eRepository = environment.e2eRepositoryBuilder(
            databaseContainer,
            eventNotificationCenter,
            mlsClient,
            apiClient
        )
        
        let messageRepository = environment.messageRepositoryBuilder(
            databaseContainer,
            apiClient,
            e2eRepository
        )
        let offlineRequestsRepository = environment.offlineRequestsRepositoryBuilder(
            messageRepository,
            databaseContainer,
            apiClient,
            config.queuedActionsMaxHoursThreshold
        )
        let syncRepository = environment.syncRepositoryBuilder(
            config,
            offlineRequestsRepository,
            databaseContainer,
            apiClient
        )
        let webSocketClient = factory.makeWebSocketClient(
            requestEncoder: webSocketEncoder,
            urlSessionConfiguration: urlSessionConfiguration,
            eventNotificationCenter: eventNotificationCenter,
            rootProjectId: rootProjectId
        )

        let connectionRepository = environment.connectionRepositoryBuilder(
            config.isClientInActiveMode,
            webSocketClient,
            apiClient,
            environment.timerType,
            config.apiKey.apiKeyString
        )
        let authRepository = environment.authenticationRepositoryBuilder(
            apiClient,
            databaseContainer,
            connectionRepository,
            environment.tokenExpirationRetryStrategy,
            projectId,
            environment.timerType
        )
        authRepository.configureDeviceIdStore(deviceIdStore)

        let walletRepository = environment.walletRepositoryBuilder(
            databaseContainer,
            apiClient,
            config.apiKey
        )

        self.databaseContainer = databaseContainer
        self.apiClient = apiClient
        self.webSocketClient = webSocketClient
        self.eventNotificationCenter = eventNotificationCenter
        self.offlineRequestsRepository = offlineRequestsRepository
        self.connectionRepository = connectionRepository
        self.messageRepository = messageRepository
        self.syncRepository = syncRepository
        self.walletRepository = walletRepository
        self.e2eRepository = e2eRepository
        self.notificationTokenProvider = notificationTokenProvider
        self.mlsClient = mlsClient
        self.e2eeAttachmentTransferCoordinator = e2eeAttachmentTransferCoordinator
        authenticationRepository = authRepository
        extensionLifecycle = environment.extensionLifecycleBuilder(config.applicationGroupIdentifier)
        callRepository = environment.callRepositoryBuilder(apiClient)
        channelRepository = environment.channelRepositoryBuilder(
            databaseContainer,
            apiClient
        )

        authRepository.delegate = self
        apiClientEncoder.connectionProviderDelegate = self
        webSocketEncoder.connectionProviderDelegate = self
        webSocketClient?.connectionStateDelegate = self

        setupTokenRefresher()
        setupOfflineRequestQueue()
        setupConnectionRecoveryHandler(with: environment)
        e2eeAttachmentTransferCoordinator?.configureCompletionClient(
            apiClient,
            messageBinding: messageRepository
        )
        e2eeAttachmentTransferCoordinator?.start()

        if let userId = currentUserId {
            do {
                try mlsClient.setup(with: userId)
            } catch {
                log.error("Failed to initialize MLS: \(error)")
            }
        }
    }

    deinit {
        completeConnectionIdWaiters(connectionId: nil)
        completeTokenWaiters(token: nil)
    }

    func setupTokenRefresher() {
        log.info("[AuthRefresh] implementation=single_flight_v2 state=installed", subsystems: .authentication)
        apiClient.tokenRefresher = { [weak repository = authenticationRepository] completion in
            guard let repository else {
                completion(ClientError.MissingTokenProvider())
                return
            }
            repository.refreshToken(completion: completion)
        }
    }

    func setupOfflineRequestQueue() {
        apiClient.queueOfflineRequest = { [weak self] endpoint in
            self?.syncRepository.queueOfflineRequest(endpoint: endpoint)
        }
    }

    func setupConnectionRecoveryHandler(with environment: Environment) {
        guard let webSocketClient = webSocketClient else {
            return
        }

        connectionRecoveryHandler = nil
        connectionRecoveryHandler = environment.connectionRecoveryHandlerBuilder(
            webSocketClient,
            eventNotificationCenter,
            extensionLifecycle,
            environment.backgroundTaskSchedulerBuilder(),
            environment.internetConnection(eventNotificationCenter, environment.internetMonitor),
            config.continueConnectSocketInBackground
        )
    }

    /// Register a custom attachment payload.
    ///
    /// Example:
    /// ```
    /// registerAttachment(CustomAttachmentPayload.self)
    /// ```
    ///
    /// - Parameter payloadType: The payload type of the attachment.
    public func registerAttachment<Payload: AttachmentPayload>(_ payloadType: Payload.Type) {
        Self.attachmentTypesRegistry[Payload.type] = payloadType
    }

    public func updateToken(_ token: Token, userInfo: UserInfo) {
        self.clientId = token.clientId
        self.setRootProjectId(token.projectId)
        self.chainId = token.chainId
        self.setProjecId(token.projectId)
        authenticationRepository.update(token: token, userInfo: userInfo)
            do {
                try mlsClient.setup(with: token.userId)
            } catch {
                log.error("Failed to initialize MLS: \(error)")
            }
    }

    public func setProjecId(_ projectId: String) {
        self.projectId = projectId
        authenticationRepository.projectId = projectId
    }

    public func setRootProjectId(_ rootProjectId: String) {
        self.rootProjectid = rootProjectId
        authenticationRepository.projectId = rootProjectId
    }

    /// Connects the client with the given user.
    ///
    /// - Parameters:
    ///   - userInfo: The user info passed to `connect` endpoint.
    ///   - refreshTokenHelper: The object handle refresh token.
    ///   - completion: The completion that will be called once the **first** user session for the given token is setup.
    ///
    /// - Note: Connect endpoint uses an upsert mechanism. If the user does not exist, it will be created with the given `userInfo`. If user already exists, it will get updated with non-nil fields from the `userInfo`.
    public func connectUser(
        userInfo: UserInfo,
        refreshTokenHelper: ErmisRefreshTokenHelper,
        completion: ((Error?) -> Void)? = nil
    ) {
        updateToken(refreshTokenHelper.token, userInfo: userInfo)

        guard let tokenProvider = getTokenProvider(refreshTokenHelper) else {
            let error = ClientError("Unknow Error")
            completion?(error)
            return
        }

        authenticationRepository.connectUser(
            userInfo: userInfo,
            tokenProvider: tokenProvider,
            completion: { completion?($0) }
        )
    }

    public func register(email: String, password: String, apiKey: String, completion: @escaping ((Result<EmptyResponse, Error>) -> Void)) {
        authenticationRepository.register(email: email,
                                          password: password,
                                          apiKey: apiKey,
                                          completion: completion)
    }

    public func login(with email: String, password: String, apiKey: String, completion: @escaping ((Result<AuthenticationPayload, Error>) -> Void)) {
        authenticationRepository.login(with: email, password: password, apiKey: apiKey, completion: completion)
    }

    public func getOtp(with body: GetOtpRequestBody,
                       completion: @escaping ((Result<EmptyResponse, Error>) -> Void)) {
        authenticationRepository.getOTP(body: body,                                        completion: completion)
    }

    public func login(with identifier: String,
                      method: OtpMethod,
                      otp: String,
                      apiKey: String,
                      completion: @escaping ((Result<AuthenticationPayload, Error>) -> Void)) {
        authenticationRepository.login(with: .init(identifier: identifier,
                                                   otp: otp,
                                                   method: method,
                                                   apiKey: apiKey),
                                       completion: completion)
    }

    public func loginGoogle(with googleIdToken: String,
                      apiKey: String,
                      completion: @escaping ((Result<AuthenticationPayload, Error>) -> Void)) {
        authenticationRepository.loginGoogle(with: googleIdToken, apiKey: apiKey, completion: completion)
    }

    public func loginApple(with token: String,
                           apiKey: String,
                           completion: @escaping ((Result<AuthenticationPayload, Error>) -> Void)) {
        authenticationRepository.loginApple(with: token, apiKey: apiKey, completion: completion)
    }
    /// Disconnects the chat client from the chat servers. No further updates from the servers
    /// are received.
    public func disconnect(completion: @escaping () -> Void) {
        connectionRepository.disconnect(source: .userInitiated) {
            log.info("The `ErmisClient` has been disconnected.", subsystems: .webSocket)
            completion()
        }
        authenticationRepository.clearTokenProvider()
        authenticationRepository.cancelTimers()
    }

    /// Disconnects the chat client while preserving the current user's local data.
    public func logout(completion: @escaping () -> Void) {
        logout(localDataPolicy: .preserve, completion: completion)
    }

    /// Disconnects the chat client and applies the requested local-data policy.
    public func logout(
        localDataPolicy: LogoutLocalDataPolicy,
        completion: @escaping () -> Void
    ) {
        let transferAccountId = currentUserId
        // Full originals are foreground-only plaintext files. They are never part of the
        // durable upload store, so tear them down independently from account-scoped background
        // transfer cancellation before this client can be reused by another authenticated user.
        Task { [weak self] in
            await self?.e2eeAttachmentOriginalDownloadCoordinator.shutdown()
        }
        authenticationRepository.logOutUser()
        // Stop tracking active components
        activeChannelControllers.removeAllObjects()
        activeChannelListControllers.removeAllObjects()

        // Disconnect first so no WebSocket event can enqueue MLS work after runtime teardown.
        disconnect { [weak self] in
            guard let self else {
                DispatchQueue.main.async(execute: completion)
                return
            }
            let finish = {
                log.debug("Logged out user with local data policy \(localDataPolicy).", subsystems: .all)
                DispatchQueue.main.async(execute: completion)
            }
            let applyLocalDataPolicy = {
                switch localDataPolicy {
                case .preserve:
                    self.e2eRepository.reset()
                    finish()
                case .purgeCurrentUser:
                    do {
                        try self.e2eRepository.purgeCurrentUserState()
                    } catch {
                        log.error("Purging current user's MLS state failed with error \(error)", subsystems: .mls)
                    }
                    self.databaseContainer.removeAllData { error in
                        if let error {
                            log.error("Purging current user's local database failed with error \(error)", subsystems: .database)
                        }
                        finish()
                    }
                }
            }
            guard let transferAccountId,
                  let coordinator = self.e2eeAttachmentTransferCoordinator else {
                applyLocalDataPolicy()
                return
            }
            coordinator.cancelTasks(accountId: transferAccountId) { _ in
                applyLocalDataPolicy()
            }
        }
    }

    /// Forward this method from
    /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    /// The SDK owns the handler exactly once and invokes it only after opaque callback events have
    /// been persisted, drained into the durable transfer store, and reconciled with URLSession.
    @discardableResult
    public func handleE2eeBackgroundURLSessionEvents(
        identifier: String,
        completionHandler: @escaping () -> Void
    ) -> E2eeBackgroundSessionEventHandlingResult {
        guard let coordinator = e2eeAttachmentTransferCoordinator else {
            return .unsupportedSessionIdentifier
        }
        return coordinator.handleEventsForBackgroundURLSession(
            identifier: identifier,
            completionHandler: completionHandler
        )
    }

    public func downloadAttachments(attachments: [AnyMessageAttachment], completion: @escaping([DownloadedAttachment], Error?) -> Void) {
        apiClient.downloadMessageAttachments(attachments, progress: nil, completion: { [weak self] result in
            let downloadedAttachments = result.results.compactMap(\.value)
            let error = result.results.first(where: { $0.error != nil})?.error
            completion(downloadedAttachments, error)
        })
    }

    /// Returns a playable local URL for an E2EE attachment original.
    ///
    /// Standard attachments are returned unchanged. E2EE originals are downloaded only on this
    /// explicit user action, globally hash-verified, frame-decrypted to a protected temporary file,
    /// and then returned to the media viewer. Range streaming is intentionally not used here.
    public func prepareAttachmentForViewing(_ attachment: AnyMessageAttachment) async throws -> URL {
        try await prepareAttachmentForViewing(attachment, progress: { _ in })
    }

    /// Resolves an attachment for an explicit viewer action and reports non-sensitive transfer
    /// progress for that individual original. The byte count is ciphertext received from storage;
    /// callers must keep the UI in a processing state while the phase is verifying/decrypting.
    public func prepareAttachmentForViewing(
        _ attachment: AnyMessageAttachment,
        progress: @escaping @Sendable (E2eeAttachmentOriginalDownloadProgress) -> Void
    ) async throws -> URL {
        try await e2eeAttachmentOriginalDownloadCoordinator.localOriginalURL(
            for: attachment,
            progress: progress
        )
    }

    /// Acquires explicit ownership of a playable attachment original.
    ///
    /// SDK viewers should retain this lease for as long as they read `localURL` and release it on
    /// close, reuse, export completion, or error. Different consumers can safely share the same
    /// verified plaintext without invalidating one another.
    public func acquireAttachmentForViewing(
        _ attachment: AnyMessageAttachment,
        progress: @escaping @Sendable (E2eeAttachmentOriginalDownloadProgress) -> Void = { _ in }
    ) async throws -> E2eeAttachmentOriginalLease {
        try await e2eeAttachmentOriginalDownloadCoordinator.localOriginalLease(
            for: attachment,
            progress: progress
        )
    }

    /// Acquires a lease-owned local source suitable for a fresh forwarded upload.
    ///
    /// E2EE opaque originals keep their verified decrypt/download lane. Pending local files are
    /// reused while present. Standard and legacy HTTP(S) attachments are streamed to protected
    /// temporary storage because upload payloads must never be initialized with a remote URL.
    public func acquireAttachmentForForwarding(
        _ attachment: AnyMessageAttachment
    ) async throws -> E2eeAttachmentOriginalLease {
        if let localURL = attachment.uploadingState?.localFileURL,
           localURL.isFileURL,
           FileManager.default.fileExists(atPath: localURL.path) {
            return E2eeAttachmentOriginalLease(localURL: localURL, releaseHandler: {})
        }
        guard let sourceURL = attachment.remoteURL else {
            throw ForwardAttachmentSourceMaterializationError.invalidRemoteURL
        }
        if sourceURL.isFileURL {
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                throw ForwardAttachmentSourceMaterializationError.downloadedFileUnavailable
            }
            return E2eeAttachmentOriginalLease(localURL: sourceURL, releaseHandler: {})
        }
        if E2eeAttachmentOriginalDownloadCoordinator.isOpaqueE2eeAttachment(attachment) {
            return try await acquireAttachmentForViewing(attachment)
        }

        log.info(
            "[ATTACHMENT_FORWARD] stage=source_materialization state=remote_download_started"
        )
        let lease = try await ForwardAttachmentRemoteSourceMaterializer(
            maximumBytes: config.maxAttachmentSize
        ).materialize(
            remoteURL: sourceURL,
            preferredFileExtension: ForwardAttachmentRemoteSourceMaterializer
                .preferredFileExtension(for: attachment)
        )
        log.info(
            "[ATTACHMENT_FORWARD] stage=source_materialization state=remote_download_completed"
        )
        return lease
    }

    /// Returns an AVAsset-backed playback lease. Every E2EE opaque video uses authenticated
    /// plaintext ranges by default, independently of file size or duration. The verified
    /// local-original lane remains available for explicit rollback, non-E2EE assets, and
    /// transparent fallback when range transport fails.
    public func acquireVideoAttachmentForPlayback(
        _ attachment: AnyMessageAttachment,
        progress: @escaping @Sendable (E2eeAttachmentOriginalDownloadProgress) -> Void = { _ in }
    ) async throws -> E2eeAttachmentPlaybackLease {
        let isOpaqueE2eeVideo = E2eeAttachmentOriginalDownloadCoordinator
            .isOpaqueE2eeAttachment(attachment)
        let usesRangeStreaming = E2eeVideoPlaybackPolicy.usesRangeStreaming(
            isOpaqueE2eeVideo: isOpaqueE2eeVideo,
            clientEnabled: config.isE2eeRangeStreamingEnabled,
            processEnabled: E2eeRangeStreamingFeatureFlag.isEnabled
        )
        guard usesRangeStreaming else {
            if isOpaqueE2eeVideo {
                log.info("[E2EE_VIDEO_PLAYBACK] transport=full_download reason=rollback_disabled")
            } else {
                log.info("[E2EE_VIDEO_PLAYBACK] transport=full_download reason=non_opaque")
            }
            let original = try await acquireAttachmentForViewing(attachment, progress: progress)
            return E2eeAttachmentPlaybackLease(
                asset: AVURLAsset(url: original.localURL),
                releaseHandler: { original.release() }
            )
        }

        log.info("[E2EE_VIDEO_PLAYBACK] transport=range")
        let descriptor = try await e2eeAttachmentOriginalDownloadCoordinator
            .rangeStreamingDescriptor(for: attachment)
        let loader = try E2eeRangeStreamingResourceLoader(
            asset: descriptor.asset,
            grantProvider: { [weak self] assetId in
                guard let self else { throw URLError(.cancelled) }
                let issuedAt = Date()
                guard let cid = try? ChannelId(cid: descriptor.cid) else {
                    throw E2eeAttachmentOriginalDownloadError.invalidOpaqueURL
                }
                let response = try await self.apiClient.e2eeAttachmentDownloadGrant(
                    cid: cid,
                    attachmentId: descriptor.attachmentId,
                    assetId: assetId
                )
                guard let expiresAt = DateFormatter.Ermis.rfc3339Date(from: response.expiresAt) else {
                    throw E2eeAttachmentAPIContractError.invalidExpiry
                }
#if DEBUG
                let debugExpiry = E2eeRangeStreamingDebugGrantExpiry.resolve(
                    serverExpiresAt: expiresAt,
                    issuedAt: issuedAt
                )
                if debugExpiry.wasShortened {
                    log.info("[E2EE_RANGE_PLAYBACK] state=debug_grant_ttl_shortened")
                }
                let effectiveExpiresAt = debugExpiry.expiresAt
#else
                let effectiveExpiresAt = expiresAt
#endif
                return E2eeRangeStreamingGrant(
                    assetId: assetId,
                    grantURL: response.downloadURL,
                    expiresAt: effectiveExpiresAt,
                    issuedAt: issuedAt
                )
            },
            fallbackProvider: { [weak self] in
                guard let self else { throw URLError(.cancelled) }
                return try await self.acquireAttachmentForViewing(attachment, progress: progress)
            },
            attachmentMimeType: attachment.mimetype,
            attachmentFileName: attachment.title
        )
        let asset = loader.makeAsset()
        asset.resourceLoader.setDelegate(
            loader,
            queue: DispatchQueue(label: "network.ermis.e2ee.range-loader")
        )
        return E2eeAttachmentPlaybackLease(asset: asset) {
            loader.invalidate()
        }
    }

    /// Explicitly cancels the durable background GET for one E2EE original.
    ///
    /// Releasing or closing a viewer intentionally does not call this API: it only detaches that
    /// consumer so the transfer can survive navigation and app relaunch. Use this method only for
    /// a user-visible Cancel action. Other attachments and accounts are not affected.
    public func cancelAttachmentOriginalDownload(
        _ attachment: AnyMessageAttachment,
        in cid: ChannelId
    ) async throws {
        guard let accountId = currentUserId,
              let transferCoordinator = e2eeAttachmentTransferCoordinator else {
            throw E2eeAttachmentOriginalDownloadError.backgroundTransferUnavailable
        }
        let reference = try E2eeAttachmentOriginalDownloadCoordinator.opaqueAssetReference(
            for: attachment
        )
        try await withCheckedThrowingContinuation { continuation in
            transferCoordinator.cancelBackgroundDownload(
                accountId: accountId,
                cid: cid.rawValue,
                attachmentId: reference.attachmentId,
                assetId: reference.assetId
            ) { result in
                continuation.resume(with: result)
            }
        }
    }

    /// Returns whether the attachment URL is an opaque E2EE reference that must never be passed
    /// directly to a generic downloader, media library, document picker, or share sheet.
    public func requiresVerifiedE2eeOriginal(_ attachment: AnyMessageAttachment) -> Bool {
        E2eeAttachmentOriginalDownloadCoordinator.isOpaqueE2eeAttachment(attachment)
    }

    /// Backwards-compatible video-specific spelling. Image and video viewers now share the same
    /// authenticated original resolver.
    public func prepareAttachmentForPlayback(_ attachment: AnyMessageAttachment) async throws -> URL {
        try await prepareAttachmentForViewing(attachment)
    }

    /// Returns the readiness of the MLS group effectively used by `cid`.
    public func e2eeReadiness(for cid: ChannelId) -> E2eeChannelReadiness {
        e2eRepository.readiness(for: cid)
    }

    /// Runs the Welcome-first bootstrap flow and completes when the channel reaches a terminal state.
    public func ensureE2eeReady(
        for cid: ChannelId,
        completion: @escaping (E2eeChannelReadiness) -> Void
    ) {
        e2eRepository.ensureE2eeReady(for: cid, completion: completion)
    }

    func createBackgroundWorkers() {
        guard config.isClientInActiveMode else { return }

        // All production workers
        backgroundWorkers = [
            MessageSender(
                messageRepository: messageRepository,
                eventsNotificationCenter: eventNotificationCenter,
                database: databaseContainer,
                apiClient: apiClient
            ),
            NewUserQueryUpdater(database: databaseContainer, apiClient: apiClient),
            MessageEditor(messageRepository: messageRepository, e2eRepository: e2eRepository, database: databaseContainer, apiClient: apiClient),
            AttachmentQueueUploader(
                database: databaseContainer,
                apiClient: apiClient,
                attachmentPostProcessor: config.uploadedAttachmentPostProcessor,
                e2eePreparationCoordinator: e2eeAttachmentTransferCoordinator.map {
                    E2eeAttachmentPreparationCoordinator(
                        transferCoordinator: $0,
                        initializingClient: apiClient
                    )
                },
                currentUserId: { [weak self] in self?.currentUserId }
            )
        ]
    }

    func trackChannelController(_ channelController: ChannelController) {
        activeChannelControllers.add(channelController)
    }

    func trackChannelListController(_ channelListController: ChannelListController) {
        activeChannelListControllers.add(channelListController)
    }

    func completeConnectionIdWaiters(connectionId: String?) {
        connectionRepository.completeConnectionIdWaiters(connectionId: connectionId)
    }

    func completeTokenWaiters(token: Token?) {
        authenticationRepository.completeTokenWaiters(token: token)
    }

    /// Sets the user token to the client, this method is only needed to perform API calls
    /// without connecting as a user.
    /// You should only use this in special cases like a notification service or other background process
    public func setToken(token: Token) {
        authenticationRepository.setToken(token: token, completeTokenWaiters: true)
    }

    public func subscribe() {
        syncRepository.subscribe()
    }

    public func syncStickers() {
        syncRepository.syncStickers()
    }

    /// Fetch all users infomation
    ///  - Parameters completion: A block to be executed when the process is completed. Contains an error if something went wrong

    public func fetchUsers(completion: @escaping (Error?) -> Void) {
        apiClient.request(endpoint: .users(query: .search(term: "", projectId: projectId))) { [weak self] result in
            switch result {
            case .success(let userListPayload):
                self?.databaseContainer.write { [weak self] session in
                    session.saveUsers(payload: userListPayload,
                                      projectId: self?.projectId ?? "",
                                      query: .search(term: "",
                                                     projectId: self?.projectId ?? ""))
                }
                completion(nil)
            case .failure(let error):
                completion(error)
            }
        }
    }

    /// Fetch user infomation from ids list.
    ///
    /// - Parameters:
    ///   - ids: The list of userId of user.
    ///   - projectId: The current projectId.
    ///   - completion: A block to be executed when the process is completed. Contains Result of `ChatUser` list or `Error`
    public func fetchUsers(with ids: [String],
                           completion: @escaping (Result<[ChatUser], Error>) -> Void) {
        apiClient.request(endpoint: .users(with: ids, projectId: projectId)) { [weak self] result in
            switch result {
            case .success(let userListPayload):
                self?.databaseContainer.write { session in
                    let users = session.saveUsers(payload: userListPayload,
                                                  projectId: self?.projectId ?? "",
                                                  query: nil)
                    completion(.success(users.compactMap({ try? $0.asModel() })))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    public func ermisRefreshToken(_ token: Token, refreshToken: String, completion: @escaping ((Result<AuthenticationPayload, Error>) -> Void)) {
        apiClient.refreshTokenRequest(endpoint: .refreshToken(token, refresToken: refreshToken), completion: completion)
    }

    /// Fetch channel attachment of given `ChannelAttachmentFilterType`.
    ///
    /// - Parameters:
    ///   - cid: The id of channel.
    ///   - attachmentTypes: The list of `ChannelAttachmentFilterType` to filter.
    ///   - completion: A block to be executed when the process is completed.
    ///   Contains Result of `ChannelAttachmentListPayload` list or `Error`
    public func getAttachments(in cid: ChannelId,
                               attachmentTypes: [ChannelAttachmentType],
                               completion: @escaping (Result<[ChannelAttachmentPayload], Error>) -> Void) {
        apiClient.request(endpoint: .channelAttachment(cid: cid,
                                                       body: .init(attachmentTypes: attachmentTypes)),
                          completion: { [weak self] result in
            switch result {
            case .success(let channelAttachmentList):
                let channelAttachments = channelAttachmentList.attachments.map({
                    var channelAttachment = $0
                    channelAttachment.user = self?.getUser(with: channelAttachment.userId)
                    return channelAttachment
                })
                completion(.success(channelAttachments))
            case .failure(let error):
                completion(.failure(error))
            }
        })
    }

    func getTokenProvider(_ refreshTokenHelper: ErmisRefreshTokenHelper) -> TokenProvider? {
        { [weak self] completion in
            guard let self else {
                completion(.failure(ClientError.ClientHasBeenDeallocated()))
                return
            }
            if let initialToken = refreshTokenHelper.consumeInitialTokenIfValid() {
                completion(.success(initialToken))
                return
            }

            guard let refreshToken = refreshTokenHelper.refreshToken else {
                let error = ClientError("Token refresh failed with error: Can't not find refresh token")
                completion(.failure(error))
                return
            }

            self.ermisRefreshToken(refreshTokenHelper.token, refreshToken: refreshToken) { [weak self] result in
                switch result {
                case .success(let authResponse):
                    if let token = try? Token(rawValue: authResponse.token) {
                        refreshTokenHelper.update(
                            token: token,
                            refreshToken: authResponse.refreshToken
                        )
                        refreshTokenHelper.onAuthorizationChanged?(authResponse)
                        completion(.success(token))
                    } else {
                        let error = ClientError("Can't refresh token")
                        completion(.failure(error))
                    }
                case .failure(let error):
                    if error is ClientError.ExpiredToken {
                        refreshTokenHelper.onRefreshTokenExpired?()
                        completion(.failure(ClientError.RefreshTokenExpired()))
                    } else {
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    // MARK: - Signal
    public func sendSignal(body: CallSignalRequestBody) async throws -> CallSignalRequestPayload {
        try await callRepository.sendSignal(body: body)
    }

    // TODO: - Break wallet to another target
    // MARK: - Wallet

    // create challange message to sign wallet.
    public func startAuth(with address: String) async throws -> SignWalletPayload {
        try await walletRepository.startAuth(with: address)
    }

    // Get token
    public func walletAuthenticate(with signature: String,
                                   address: String,
                                   nonce: String) async throws -> AuthenticationPayload {
        let authenticationPayload = try await walletRepository.walletAuthenticate(with: signature,
                                                                                  address: address,
                                                                                  nonce: nonce)
        if let token = try? Token(rawValue: authenticationPayload.token) {
            self.projectId = token.projectId
            self.clientId = token.clientId
            self.chainId = token.chainId
        }
        return authenticationPayload
    }

    public func getChains() async throws -> ChainListPayload {
        try await walletRepository.getChains()
    }

    public func getChains(completion: @escaping (Result<ChainListPayload, Error>) -> Void) {
        walletRepository.getChains(completion: completion)
    }

    public func getClients(on chain: String) async throws -> [ErmisClientPayload] {
        try await walletRepository.getClients(on: chain)
    }

    public func getProjects(of client: String, on chain: String) async throws -> [ErmisProjectPayload] {
        try await walletRepository.getProjects(of: client, on: chain)
    }

    public func joinProject(_ projectId: String, completion: @escaping (Result<ChainListPayload, Error>) -> Void) {
        walletRepository.joinProject(projectId, completion: completion)
    }

    public func getDeleteUserChallange() async throws -> SignWalletPayload {
        try await apiClient.request(endpoint: .getDeleteUserChallange())
    }

    public func deleteUser(signature: String) async throws {
        try await apiClient.request(endpoint: .deleteUser(signature: signature))
    }

    public func getDeleteUserOtp(completion: @escaping ((Result<EmptyResponse, Error>) -> Void)) {
        apiClient.request(endpoint: .getDeleteUserOtp(), completion: completion)
    }

    public func deleteUser(identifier: String,
                           otp: String,
                           method: OtpMethod,
                           apikey: String,
                           completion: @escaping ((Result<EmptyResponse, Error>) -> Void)) {
        apiClient.request(endpoint: .deleteUser(body: .init(identifier: identifier, otp: otp, method: method, apiKey: apikey)), completion: completion)
    }

    public func getUnreadChannelList(channelListQuery: ChannelListQuery,
                                     completion: @escaping (Result<UnreadProjectListPayload, Error>) -> Void) {
        apiClient.request(endpoint: .channels(query: channelListQuery), completion: { [weak self] result in
            switch result {
            case .success(let channeListPayload):
                let unreadProjectList = UnreadProjectListPayload(projects: [])
                for channel in channeListPayload.channels {
                    let projectId = channel.channel.cid.projectId
                    if !unreadProjectList.projects.contains(where: { $0.projectId == projectId }) {
                        unreadProjectList.projects.append(UnreadProjectPayload(projectId: projectId,
                                                                               unreadCount: 0))
                    }
                    if let index = unreadProjectList.projects
                        .firstIndex(where: { $0.projectId == projectId }) {
                        unreadProjectList.projects[index].unreadCount =
                        channel.channelReads
                            .filter { $0.user.userId == self?.currentUserId }
                            .reduce(into: unreadProjectList.projects[index].unreadCount, { partialResult, channelRead in
                                partialResult += channelRead.unreadMessagesCount
                            })
                    }
                }
                completion(.success(unreadProjectList))
            case .failure(let error):
                completion(.failure(error))
            }
        })
    }

    public func getUser(with id: String) -> ChatUser? {
        var result: ChatUser?
        databaseContainer.viewContext.performAndWait {
            let userDTO = databaseContainer.viewContext.user(id: id, projectId: projectId)
            result = try? userDTO?.asModel()
        }
        return result
    }
    // MARK: - Invite
    public func acceptInvite(cid: ChannelId, completion: @escaping ((Error?) -> Void)) {
        apiClient.request(endpoint: .acceptInvite(cid: cid)) { [weak self] result in
            guard let self else {
                completion(result.error)
                return
            }
            guard result.error == nil else {
                completion(result.error)
                return
            }
            // After accepting, check if the channel is MLS-enabled.
            // If so, perform an external join so the device can decrypt messages,
            // then trigger an E2E sync for that channel.
            var isMlsEnabled = false
            self.databaseContainer.viewContext.performAndWait {
                if let dto = ChannelDTO.load(cid: cid, context: self.databaseContainer.viewContext) {
                    isMlsEnabled = dto.mlsEnabled
                }
            }
            guard isMlsEnabled else {
                completion(nil)
                return
            }
            self.e2eRepository.performE2eChannelSync(cid: cid)
            completion(result.error)
        }
    }

    public func skipInvite(cid: ChannelId, completion: @escaping ((Error?) -> Void)) {
        apiClient.request(endpoint: .skipInvite(cid: cid)) { result in
            completion(result.error)
        }
    }

    public func rejectInvite(cid: ChannelId, completion: @escaping ((Error?) -> Void)) {
        apiClient.request(endpoint: .rejectInvite(cid: cid)) { result in
            completion(result.error)
        }
    }
    // MARK: - E2E
    // MARK: - Call
    @discardableResult
    package
    func sendSignal(for callId: String?,
                    sessionId: String?,
                    cid: ChannelId,
                    action: CallAction,
                    isVideo: Bool,
                    sdp: String? = nil,
                    metadata: Metadata?) async throws -> CallSignalRequestPayload {
        let body = CallSignalRequestBody(sessionId: sessionId ?? "",
                                         callId: callId,
                                         cid: cid,
                                         action: action,
                                         isVideo: isVideo,
                                         metadata: metadata)
        return try await self.callRepository.sendSignal(body: body)
    }

    public func handelPushKitPayload(_ payload: [AnyHashable: Any]) throws -> CallSignalEvent {
        guard let dataPayload = payload["data"] as? String,
              let data = try? dataPayload.data(using: .utf8),
              let callSignalEventDTO = try? EventDecoder().decode(from: data) as? CallSignalEventDTO else {
            throw ClientError.Unexpected("Precondition failed")
        }

        // backgroundReadOnlyContext is a private-queue context. All Core Data
        // access must happen on its queue via performAndWait to avoid crashes.
//        var channel: Channel?
//        databaseContainer.viewContext.performAndWait {
//            channel = try? databaseContainer.backgroundReadOnlyContext.channel(cid: callSignalEventDTO.cid)?.asModel()
//        }

        guard let channel = try? databaseContainer.viewContext.channel(cid: callSignalEventDTO.cid)?.asModel() else {
            throw ClientError.ChannelDoesNotExist(cid: callSignalEventDTO.cid)
        }

        let callSignalEvent = CallSignalEvent(userId: callSignalEventDTO.userId,
                                              sessionId: callSignalEventDTO.sessionId,
                                              callId: callSignalEventDTO.callId,
                                              channel: channel,
                                              callAction: callSignalEventDTO.callAction,
                                              isVideo: callSignalEventDTO.isVideo,
                                              createdAt: callSignalEventDTO.createdAt,
                                              metadata: callSignalEventDTO.metadata)
        return callSignalEvent
    }
}

extension ErmisClient: AuthenticationRepositoryDelegate {
    func logOutUser(completion: @escaping () -> Void) {
        logout(completion: completion)
    }

    func didFinishSettingUpAuthenticationEnvironment(for state: EnvironmentState) {
        switch state {
        case .firstConnection, .newUser:
            e2eRepository.loginTime = Date()
            createBackgroundWorkers()
        case .newToken:
            // After reinstall UserDefaults is cleared but Keychain token persists,
            // so the state is .newToken with a nil loginTime. Restore it here.
            if e2eRepository.loginTime == nil {
                e2eRepository.loginTime = Date()
            }
            if backgroundWorkers.isEmpty {
                createBackgroundWorkers()
            }
        }
    }
}

extension ErmisClient: ConnectionStateDelegate {
    func webSocketClient(_ client: WebSocketClient, didUpdateConnectionState state: WebSocketConnectionState) {
        connectionRepository.handleConnectionUpdate(
            state: state,
            onExpiredToken: { [weak repository = authenticationRepository] in
                repository?.refreshToken { _ in
                    // The connection recovery path observes the resulting connection state.
                    // It does not need to forward this completion through `ErmisClient`.
                }
            }
        )
        connectionRecoveryHandler?.webSocketClient(client, didUpdateConnectionState: state)
    }
}

/// `Client` provides connection infomations for the `RequestEncoder`s it creates.
extension ErmisClient: ConnectionProviderDelegate {
    func provideToken(timeout: TimeInterval = 10, completion: @escaping (Result<Token, Error>) -> Void) {
        authenticationRepository.provideToken(timeout: timeout, completion: completion)
    }

    func provideConnectionId(timeout: TimeInterval = 10, completion: @escaping (Result<ConnectionId, Error>) -> Void) {
        connectionRepository.provideConnectionId(timeout: timeout, completion: completion)
    }
}

extension ClientError {
    public class MissingLocalStorageURL: ClientError {
        override public var localizedDescription: String { "The URL provided in ErmisClientConfig is `nil`." }
    }

    public class ConnectionNotSuccessful: ClientError {
        override public var localizedDescription: String {
            """
            Connection to the API has failed.
            \n
            API Error: \(String(describing: errorDescription))
            """
        }
    }

    public class MissingToken: ClientError {}
    class WaiterTimeout: ClientError {}

    public class ClientIsNotInActiveMode: ClientError {
        override public var localizedDescription: String {
            """
                ErmisClient is in connectionless mode, it cannot connect to websocket.
                Please check `ErmisClientConfig.isClientInActiveMode` for additional info.
            """
        }
    }

    public class ConnectionWasNotInitiated: ClientError {
        override public var localizedDescription: String {
            """
                Before performing any other actions on chat client it's required to connect by using \
                one of the available `connect` methods e.g. `connectUser`.
            """
        }
    }
    
    public class ClientHasBeenDeallocated: ClientError {
        override public var localizedDescription: String {
            "ErmisClient has been deallocated, make sure to keep at least one strong reference to it."
        }
    }

    public class MissingTokenProvider: ClientError {
        override public var localizedDescription: String {
            """
                Missing token refresh provider to get a new token
                When using expiring tokens you need to provide a way to refresh it by passing `tokenProvider` when \
                calling `ErmisClient.connectUser()`.
            """
        }
    }
}
