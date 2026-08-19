//
// Copyright 2025 Ermis Inc.
//

import CoreData
import CryptoKit
import Foundation
import ErmisShared

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
        environment.requestEncoderBuilder(config.endpointEnviroment.baseURL,
                                          config.endpointEnviroment.authURL,
                                          config.endpointEnviroment.stickerURL,
                                          config.apiKey)
    }

    func makeWebSocketRequestEncoder() -> RequestEncoder {
        environment.requestEncoderBuilder(config.endpointEnviroment.webSocketURL,
                                          config.endpointEnviroment.authURL,
                                          config.endpointEnviroment.stickerURL,
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
                sessionConfiguration: urlSessionConfiguration,
                isStandardPresignedUploadEnabled: config.isStandardPresignedUploadEnabled,
                allowsLegacyStandardUploadFallback: config.allowsLegacyStandardUploadFallback
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
            if config.isLocalStorageEnabled, config.localStorageScope != .inMemory {
                guard let storeURL = config.localStorageFolderURL else {
                    throw ClientError.MissingLocalStorageURL()
                }

                // Create the folder if needed
                try FileManager.default.createDirectory(
                    at: storeURL,
                    withIntermediateDirectories: true,
                    attributes: nil
                )

                let dbFileURL: URL
                switch config.localStorageScope {
                case .automatic:
                    // Internal/test initializers can still reach this branch. Preserve the legacy
                    // API-key path; the public initializer always resolves `.automatic` first.
                    dbFileURL = storeURL.appendingPathComponent(config.apiKey.apiKeyString)
                case .inMemory:
                    preconditionFailure("The in-memory scope must not create an on-disk store.")
                case .user(let userId):
                    let userFolder = storeURL
                        .appendingPathComponent("users", isDirectory: true)
                        .appendingPathComponent(Self.storageNamespace(apiKey: config.apiKey.apiKeyString, userId: userId), isDirectory: true)
                    try FileManager.default.createDirectory(
                        at: userFolder,
                        withIntermediateDirectories: true,
                        attributes: nil
                    )
                    dbFileURL = userFolder.appendingPathComponent("ermis.sqlite")
                    try migrateLegacyStoreIfOwned(
                        legacyURL: storeURL.appendingPathComponent(config.apiKey.apiKeyString),
                        destinationURL: dbFileURL,
                        userId: userId
                    )
                }
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

    static func storageNamespace(apiKey: String, userId: UserId) -> String {
        SHA256.hash(data: Data("\(apiKey)\u{0}\(userId)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Moves the old API-key-only Core Data store only when its CurrentUserDTO proves that it
    /// belongs to `userId`. A mismatch is deliberately quarantined at the legacy path.
    private func migrateLegacyStoreIfOwned(
        legacyURL: URL,
        destinationURL: URL,
        userId: UserId
    ) throws {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: destinationURL.path),
              fileManager.fileExists(atPath: legacyURL.path) else { return }

        let markerKey = "ermis_user_store_migration_v1_\(Self.storageNamespace(apiKey: config.apiKey.apiKeyString, userId: userId))"
        guard UserDefaults.standard.object(forKey: markerKey) == nil else { return }

        guard let modelURL = Bundle.ermisChat.url(forResource: "ErmisChatModel", withExtension: "momd"),
              let model = NSManagedObjectModel(contentsOf: modelURL) else {
            throw ClientError("Unable to load the Core Data model for legacy-store migration.")
        }

        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let options: [AnyHashable: Any] = [
            NSMigratePersistentStoresAutomaticallyOption: true,
            NSInferMappingModelAutomaticallyOption: true
        ]
        let store = try coordinator.addPersistentStore(
            ofType: NSSQLiteStoreType,
            configurationName: nil,
            at: legacyURL,
            options: options
        )
        defer { try? coordinator.remove(store) }

        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        var ownerMatches = false
        var inspectionError: Error?
        context.performAndWait {
            do {
                let request = NSFetchRequest<NSManagedObject>(entityName: "CurrentUserDTO")
                request.fetchLimit = 1
                guard let currentUser = try context.fetch(request).first,
                      let users = currentUser.value(forKey: "users") as? NSSet else { return }
                ownerMatches = users.compactMap { $0 as? NSManagedObject }
                    .contains { ($0.value(forKey: "userId") as? String) == userId }
            } catch {
                inspectionError = error
            }
        }
        if let inspectionError { throw inspectionError }
        guard ownerMatches else {
            UserDefaults.standard.set("quarantined", forKey: markerKey)
            log.warning("Legacy Core Data store owner did not match the authenticated user; leaving it quarantined.", subsystems: .database)
            return
        }

        _ = try coordinator.migratePersistentStore(
            store,
            to: destinationURL,
            options: options,
            withType: NSSQLiteStoreType
        )
        UserDefaults.standard.set("migrated", forKey: markerKey)
        log.info("Migrated the legacy Core Data store into a user-scoped namespace.", subsystems: .database)
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
            ChannelTopicEventMiddleware (),
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
