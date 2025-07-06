//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// A configuration object used to configure a `ErmisClient` instance.
///
/// The default configuration can be changed the following way:
///   ```
///     var config = ErmisClientConfig()
///     config.isLocalStorageEnabled = false
///     config.channel.keystrokeEventTimeout = 15
///   ```
///
public struct ErmisClientConfig {
    /// The `APIKey` unique for your chat app.
    public let apiKey: APIKey
    public var isErmis: Bool = false

    public var applicationGroupIdentifier: String? {
        didSet {
            localStorageFolderURL = Self.initLocalStorageFolderURL(groupIdentifier: applicationGroupIdentifier)
        }
    }

    /// The folder `ErmisClient` uses to store its local cache files.
    public var localStorageFolderURL: URL? = {
        Self.initLocalStorageFolderURL(groupIdentifier: nil)
    }()

    static func initLocalStorageFolderURL(groupIdentifier: String?) -> URL? {
        #if os(macOS)
        let urls = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        return urls.first.map { $0.appendingPathComponent("network.ermis.ermisChat") }
        #else
        if let groupIdentifier = groupIdentifier {
            if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier) {
                return url
            }
            log
                .error(
                    "Chat is configured to use the App Group: \(groupIdentifier) but the target seems to be not configured correctly"
                )
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        #endif
    }

    /// The datacenter `ErmisClient` uses for connecting.
    public var baseURL: BaseURL = .product

    /// Determines whether `ErmisClient` caches the data locally. This makes it possible to browse the existing chat data also
    /// when the internet connection is not available.
    public var isLocalStorageEnabled: Bool = true

    /// If set to `true`, `ErmisClient` resets the local cache on the start.
    ///
    /// You should set `shouldFlushLocalStorageOnStart = true` every time the changes in your code makes the local cache invalid.
    ///
    ///
    public var shouldFlushLocalStorageOnStart: Bool = false

    /// Advanced settings for the local caching and model serialization.
    public var localCaching = LocalCaching()

    /// Flag for setting a ErmisClient instance in connection-less mode.
    /// A connection-less client is not able to connect to websocket and will not
    /// receive websocket events. It can still observe and mutate database.
    /// This flag is automatically set to `false` for app extensions
    /// **Warning**: There should be at max 1 active client at the same time, else it can lead to undefined behavior.
    public var isClientInActiveMode: Bool

    /// If set to `true`, the `ErmisClient` will try to stay connected while app is backgrounded.
    /// If set to `false`, websocket disconnects immediately when app is backgrounded.
    ///
    /// This flag aims to reduce unnecessary reconnections while quick app switches,
    /// like when a user just checks a notification or another app.
    /// `ErmisClient` starts a background task to keep the connection alive,
    /// and disconnects when background task expires.
    /// `ErmisClient` tries to stay connected while in background up to 5 minutes.
    /// Usually, disconnection occurs around 2-3 minutes.
    ///
    /// - Important: If you're using manual connection flow (`shouldConnectAutomatically` set to `false`), this flag is ineffective.
    /// You should handle connection manually when sending app to background
    /// or opening app from background.
    ///
    /// Default value is `true`
    public var continueConnectSocketInBackground = true

    /// Creates a new instance of `ErmisClientConfig`.
    ///
    /// - Parameter apiKey: The API key of the chat app the `ErmisClient` connects to.
    ///

    /// Allows to inject a custom API client for uploading attachments, if not specified, `ErmisUploadClient` is used.
    /// If a custom `Uploader` is provided, the custom `UploadClient` won't be used. You should use 1 of them only.
    public var customUploadClient: UploadClient?

    /// Allows to inject a custom attachment uploader. It can be used to have more
    /// control than `UploadClient` to allow changing the attachment payload.
    /// This overrides the custom `UploadClient`. You should use 1 of them only.
    public var customUploader: Uploader?

    /// Returns max possible attachment size in bytes.
    public var maxAttachmentSize: Int64 {
        return 104_857_600 // 100 * 1024 * 1024
    }

    /// Allows to inject a custom API client for downloading attachments, if not specified, `ErmisDownloadClient` is used.
    /// If a custom `Downloader` is provided, the custom `DownloadClient` won't be used. You should use 1 of them only.
    public var customDownloadClient: DownloadClient?

    /// Allows to inject a custom attachment downloader. It can be used to have more
    /// control than `DownloadClient` to allow changing the attachment payload.
    /// This overrides the custom `DownloadClient`. You should use 1 of them only.
    public var customDownloader: Downloader?

    /// A component that can be used to change an attachment which was successfully uploaded.
    public var uploadedAttachmentPostProcessor: UploadedAttachmentPostProcessor?

    /// Specifies the visibility of deleted messages.
    public enum DeletedMessageVisibility: String, CustomStringConvertible, CustomDebugStringConvertible {
        /// All deleted messages are always hidden.
        case alwaysHidden
        /// Deleted message by current user are visible, other deleted messages are hidden.
        case visibleForCurrentUser
        /// Deleted messages are always visible.
        case alwaysVisible

        public var description: String {
            rawValue
        }

        public var debugDescription: String {
            rawValue
        }
    }

    /// Specifies the visibility of deleted messages.
    /// By default, all deleted messages are visible with their content hidden.
    public var deletedMessagesVisibility: DeletedMessageVisibility = .alwaysVisible

    /// Specifies whether `shadowed` messages should be shown in Message list.
    public var shouldShowShadowedMessages = false

    /// The timeout interval determines the network request timeout interval for all tasks within sessions based on this configuration.
    /// It controls how long (in seconds) a network task should wait for additional data to arrive before giving up
    public var timeoutIntervalForRequest: TimeInterval = 30

    /// Enable/Disable local filtering for Channel lists. When enabled,
    /// whenever a new channel is created,/updated the SDK will try to
    /// match the channel list filter automatically.
    public var isChannelAutomaticFilteringEnabled: Bool = true
    
    /// The `URLSessionConfiguration` being used as default configuration for the `APIClient` and
    /// `WebSocketClient`
    public var urlSessionConfiguration: URLSessionConfiguration = .default
    
    /// How many hours the unsent actions should be queued for sending when the internet connection is available.
    public var queuedActionsMaxHoursThreshold: Int = 12

    public init(
        apiKey: APIKey,
        isErmis: Bool,
        baseURL: BaseURL
    ) {
        self.apiKey = apiKey
        self.isErmis = isErmis
        self.baseURL = baseURL
        isClientInActiveMode = !Bundle.main.isAppExtension
    }
}

extension ErmisClientConfig {
    /// Creates a new instance of `ErmisClientConfig`.
    ///
    /// - Warning: ⚠️ The provided `apiKeyString` must not empty, otherwise an assertion failure is triggered.
    ///
    /// - Parameter apiKeyString: The string with API key of the chat app the `ErmisClient` connects to.
    /// - Parameter baseURL: The baseURL of the chat app the `ErmisClient`.
    /// - Parameter isErmis: The flag to check current app is Ermis App or other App.
    public init(apiKeyString: String,
                baseURL: BaseURL = .product,
                isErmis: Bool = false) {
        self.init(apiKey: APIKey(apiKeyString), isErmis: isErmis, baseURL: baseURL)
    }
}

extension ErmisClientConfig {
    /// Advanced settings for the local caching and model serialization.
    public struct LocalCaching: Equatable {
        /// `Channel` specific local caching and model serialization settings.
        public var channel = Channel()
    }

    /// `Channel` specific local caching and model serialization settings.
    public struct Channel: Equatable {
        /// Limit the max number of watchers included in `Channel.lastActiveWatchers`.
        public var lastActiveWatchersLimit = 1000
        /// Limit the max number of members included in `Channel.lastActiveMembers`.
        public var lastActiveMembersLimit = 1000
        /// Limit the max number of messages included in `Channel.latestMessages`.
        public var latestMessagesLimit = 5
    }
}

/// A struct representing an API key of the chat app.
///
public struct APIKey: Equatable {
    /// The string representation of the API key
    public let apiKeyString: String

    /// Creates a new `APIKey` from the provided string. Fails, if the string is empty.
    ///
    /// - Warning: The `apiKeyString` must not empty, otherwise an assertion failure is raised.
    ///
    public init(_ apiKeyString: String) {
        log.assert(apiKeyString.isEmpty == false, "APIKey can't be initialize with an empty string.")
        self.apiKeyString = apiKeyString
    }
}
