//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// A model containing user info that's used to connect to chat's backend
public struct UserInfo {
    /// The id of the user.
    public let id: UserId
    /// The name of the user.
    public let name: String?
    /// The avatar url of the user.
    public let imageURL: URL?
    /// Whether the user wants to share his online status or not.
    public let isInvisible: Bool?
    /// The language of the user. This is required for the auto translation feature.
    public let language: TranslationLanguage?

    public init(
        id: UserId,
        name: String? = nil,
        imageURL: URL? = nil,
        isInvisible: Bool? = nil,
        language: TranslationLanguage? = nil
    ) {
        self.id = id
        self.name = name
        self.imageURL = imageURL
        self.isInvisible = isInvisible
        self.language = language
    }
}
