//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// A factory component to help build all `ErmisClient` dependencies.
class ErmisClientFactory {
    let config: ErmisClientConfig
    // In the future we could remove the `Environment` struct,
    // since it is a bit redundant now that we have a factory.
    let environment: ErmisClient.Environment

    init(config: ErmisClientConfig, environment: ErmisClient.Environment) {
        self.config = config
        self.environment = environment
    }

    func makeUrlSessionConfiguration() -> URLSessionConfiguration {
        let configuration = config.urlSessionConfiguration
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = config.timeoutIntervalForRequest
        return configuration
    }

    func makeApiClientRequestEncoder() -> RequestEncoder {
        environment.requestEncoderBuilder(config.baseURL.restAPIBaseURL,
                                          config.baseURL.authAPIBaseURL,
                                          config.apiKey)
    }

    func makeWebSocketRequestEncoder() -> RequestEncoder {
        environment.requestEncoderBuilder(config.baseURL.webSocketBaseURL,
                                          nil,
                                          config.apiKey)
    }

    func makeApiClient(
        encoder: RequestEncoder,
        urlSessionConfiguration: URLSessionConfiguration
    ) -> APIClient {
        let decoder = environment.requestDecoderBuilder()
        let uploader = config.customUploader ?? ErmisUploader(
            uploadClient: config.customUploadClient ?? ErmisUploadClient(
                encoder: encoder,
                decoder: decoder,
                sessionConfiguration: urlSessionConfiguration
            )
        )

        let downloader = config.customDownloader ?? ErmisDownloader(
            client: config.customDownloadClient ?? ErmisDownloadClient(
                sessionConfiguration: urlSessionConfiguration
            )
        )

        let apiClient = environment.apiClientBuilder(
            urlSessionConfiguration,
            encoder,
            decoder,
            uploader,
            downloader
        )
        return apiClient
    }

    func makeWebSocketClient(
        requestEncoder: RequestEncoder,
        urlSessionConfiguration: URLSessionConfiguration,
        eventNotificationCenter: EventNotificationCenter,
        rootProjectId: String
    ) -> WebSocketClient? {
        environment.webSocketClientBuilder?(
            urlSessionConfiguration,
            rootProjectId,
            requestEncoder,
            EventDecoder(),
            eventNotificationCenter
        )
    }

    func makeDatabaseContainer() -> DatabaseContainer {
        do {
            if config.isLocalStorageEnabled {
                guard let storeURL = config.localStorageFolderURL else {
                    throw ClientError.MissingLocalStorageURL()
                }

                // Create the folder if needed
                try FileManager.default.createDirectory(
                    at: storeURL,
                    withIntermediateDirectories: true,
                    attributes: nil
                )

                let dbFileURL = storeURL.appendingPathComponent(config.apiKey.apiKeyString)
                return environment.databaseContainerBuilder(
                    .onDisk(databaseFileURL: dbFileURL),
                    config.shouldFlushLocalStorageOnStart,
                    config.isClientInActiveMode, // Only reset Ephemeral values in active mode
                    config.localCaching,
                    config.deletedMessagesVisibility,
                    config.shouldShowShadowedMessages
                )
            }

        } catch is ClientError.MissingLocalStorageURL {
            log.assertionFailure("The URL provided in ErmisClientConfig can't be `nil`. Falling back to the in-memory option.")

        } catch {
            log.error("Failed to initialize the local storage with error: \(error). Falling back to the in-memory option.")
        }

        return environment.databaseContainerBuilder(
            .inMemory,
            config.shouldFlushLocalStorageOnStart,
            config.isClientInActiveMode, // Only reset Ephemeral values in active mode
            config.localCaching,
            config.deletedMessagesVisibility,
            config.shouldShowShadowedMessages
        )
    }

    func makeEventNotificationCenter(
        databaseContainer: DatabaseContainer,
        currentUserId: @escaping () -> UserId?
    ) -> EventNotificationCenter {
        let center = environment.notificationCenterBuilder(databaseContainer)
        let middlewares: [EventMiddleware] = [
            EventDataProcessorMiddleware(),
            TypingStartCleanupMiddleware(
                emitEvent: { [weak center] in center?.process($0) }
            ),
            ChannelReadUpdaterMiddleware(
                newProcessedMessageIds: { [weak center] in center?.newMessageIds ?? [] }
            ),
            UserTypingStateUpdaterMiddleware(),
            ChannelTruncatedEventMiddleware(),
            MemberEventMiddleware(),
            UserChannelBanEventsMiddleware(),
            UserWatchingEventMiddleware(),
            UserUpdateMiddleware(),
            ChannelVisibilityEventMiddleware(),
            EventDTOConverterMiddleware()
        ]

        center.add(middlewares: middlewares)

        return center
    }
}
