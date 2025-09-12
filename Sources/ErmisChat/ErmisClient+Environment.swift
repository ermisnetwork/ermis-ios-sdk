//
// Copyright 2025 Ermis Inc.
//

import Foundation

extension ErmisClient {
    /// An object containing all dependencies of `Client`
    struct Environment {
        var apiClientBuilder: (
            _ sessionConfiguration: URLSessionConfiguration,
            _ requestEncoder: RequestEncoder,
            _ requestDecoder: RequestDecoder,
            _ uploader: Uploader,
            _ downloader: Downloader
        ) -> APIClient = {
            APIClient(
                sessionConfiguration: $0,
                requestEncoder: $1,
                requestDecoder: $2,
                uploader: $3,
                downloader: $4
            )
        }

        var webSocketClientBuilder: ((
            _ sessionConfiguration: URLSessionConfiguration,
            _ rootProjectId: String,
            _ requestEncoder: RequestEncoder,
            _ eventDecoder: AnyEventDecoder,
            _ notificationCenter: EventNotificationCenter
        ) -> WebSocketClient)? = {
            WebSocketClient(
                sessionConfiguration: $0,
                rootProjectId: $1,
                requestEncoder: $2,
                eventDecoder: $3,
                eventNotificationCenter: $4
            )
        }

        var databaseContainerBuilder: (
            _ kind: DatabaseContainer.Kind,
            _ shouldFlushOnStart: Bool,
            _ shouldResetEphemeralValuesOnStart: Bool,
            _ localCachingSettings: ErmisClientConfig.LocalCaching?,
            _ deletedMessageVisibility: ErmisClientConfig.DeletedMessageVisibility?,
            _ shouldShowShadowedMessages: Bool?
        ) -> DatabaseContainer = {
            DatabaseContainer(
                kind: $0,
                shouldFlushOnStart: $1,
                shouldResetEphemeralValuesOnStart: $2,
                localCachingSettings: $3,
                deletedMessagesVisibility: $4,
                shouldShowShadowedMessages: $5
            )
        }

        var extensionLifecycleBuilder = NotificationExtensionLifecycle.init

        var requestEncoderBuilder: (_ baseURL: URL, _ authURL: URL, _ stickerURL: URL, _ apiKey: APIKey) -> RequestEncoder = DefaultRequestEncoder.init
        var requestDecoderBuilder: () -> RequestDecoder = DefaultRequestDecoder.init

        var eventDecoderBuilder: () -> EventDecoder = EventDecoder.init

        var notificationCenterBuilder = EventNotificationCenter.init

        var internetConnection: (_ center: NotificationCenter, _ monitor: InternetConnectionMonitor) -> InternetConnection = {
            InternetConnection(notificationCenter: $0, monitor: $1)
        }

        var internetMonitor: InternetConnectionMonitor {
            if let monitor = monitor {
                return monitor
            } else {
                return InternetConnection.Monitor()
            }
        }

        var monitor: InternetConnectionMonitor?

        var connectionRepositoryBuilder = ConnectionRepository.init

        var backgroundTaskSchedulerBuilder: () -> BackgroundTaskScheduler? = {
            if Bundle.main.isAppExtension {
                // No background task scheduler exists for app extensions.
                return nil
            } else {
                #if os(iOS)
                return IOSBackgroundTaskScheduler()
                #else
                // No need for background schedulers on macOS, app continues running when inactive.
                return nil
                #endif
            }
        }

        var timerType: Timer.Type = DefaultTimer.self

        var tokenExpirationRetryStrategy: RetryStrategy = DefaultRetryStrategy()

        var connectionRecoveryHandlerBuilder: (
            _ webSocketClient: WebSocketClient,
            _ eventNotificationCenter: EventNotificationCenter,
            _ extensionLifecycle: NotificationExtensionLifecycle,
            _ backgroundTaskScheduler: BackgroundTaskScheduler?,
            _ internetConnection: InternetConnection,
            _ keepConnectionAliveInBackground: Bool
        ) -> ConnectionRecoveryHandler = {
            DefaultConnectionRecoveryHandler(
                webSocketClient: $0,
                eventNotificationCenter: $1,
                extensionLifecycle: $2,
                backgroundTaskScheduler: $3,
                internetConnection: $4,
                reconnectionStrategy: DefaultRetryStrategy(),
                reconnectionTimerType: DefaultTimer.self,
                keepConnectionAliveInBackground: $5
            )
        }

        var authenticationRepositoryBuilder = AuthenticationRepository.init

        var syncRepositoryBuilder: (
            _ config: ErmisClientConfig,
            _ offlineRequestsRepository: OfflineRequestsRepository,
            _ database: DatabaseContainer,
            _ apiClient: APIClient
        ) -> SyncRepository = {
            SyncRepository(
                config: $0,
                offlineRequestsRepository: $1,
                database: $2,
                apiClient: $3
            )
        }

        var callRepositoryBuilder: (
            _ apiClient: APIClient
        ) -> CallRepository = {
            CallRepository(apiClient: $0)
        }

        var channelRepositoryBuilder: (
            _ database: DatabaseContainer,
            _ apiClient: APIClient
        ) -> ChannelRepository = {
            ChannelRepository(database: $0, apiClient: $1)
        }

        var messageRepositoryBuilder: (
            _ database: DatabaseContainer,
            _ apiClient: APIClient
        ) -> MessageRepository = {
            MessageRepository(database: $0, apiClient: $1)
        }

        var walletRepositoryBuilder: (
            _ database: DatabaseContainer,
            _ apiClient: APIClient,
            _ apiKey: APIKey
        ) -> WalletRepository = {
            WalletRepository(database: $0,
                             apiClient: $1,
                             apiKey: $2)
        }

        var offlineRequestsRepositoryBuilder: (
            _ messageRepository: MessageRepository,
            _ database: DatabaseContainer,
            _ apiClient: APIClient,
            _ maxHoursThreshold: Int
        ) -> OfflineRequestsRepository = {
            OfflineRequestsRepository(
                messageRepository: $0,
                database: $1,
                apiClient: $2,
                maxHoursThreshold: $3
            )
        }
    }
}
