//
// Copyright 2025 Ermis Inc.
//

import CoreData

extension NSManagedObjectContext {
    private static let localCachingKey = "network.ermis.ermisChat.local_caching_key"

    /// Provides the defaults for local caching and model serialization for this context.
    var localCachingSettings: ErmisClientConfig.LocalCaching? {
        get { userInfo[Self.localCachingKey] as? ErmisClientConfig.LocalCaching }
        set { userInfo[Self.localCachingKey] = newValue }
    }

    private static let deletedMessagesVisibilityKey = "network.ermis.ermisChat.deletedMessagesVisibility_key"

    private static let shouldShowShadowedMessagesKey = "network.ermis.ermisChat.shouldShowShadowedMessages_key"

    /// Provides the info about deleted messages behavior
    var deletedMessagesVisibility: ErmisClientConfig.DeletedMessageVisibility? {
        get { userInfo[Self.deletedMessagesVisibilityKey] as? ErmisClientConfig.DeletedMessageVisibility }
        set { userInfo[Self.deletedMessagesVisibilityKey] = newValue }
    }

    /// Provides the info about shadowed messages behavior
    var shouldShowShadowedMessages: Bool? {
        get { userInfo[Self.shouldShowShadowedMessagesKey] as? Bool }
        set { userInfo[Self.shouldShowShadowedMessagesKey] = newValue }
    }
}
