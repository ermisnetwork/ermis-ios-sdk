//
// Copyright 2025 Ermis Inc.
//

import Foundation

struct ChannelEditDetailPayload: Encodable {
    let id: String?
    var cid: ChannelId?
    let name: String?
    let description: String?
    let imageURL: String?
    let isPublic: Bool?
    let saveMessage: Bool?
    let type: ChannelType
    let members: Set<UserId>
    let invites: Set<UserId>
    let coolDownDuration: Int?
    let filterWords: [String]?

    /// TLS-serialized commit bytes for MLS channel creation.
    var commit: [UInt8]?
    /// TLS-serialized welcome bytes for MLS channel creation.
    var welcome: [UInt8]?
    /// MLS group epoch after the commit.
    var epoch: Int?
    /// TLS-serialized ratchet tree bytes for MLS channel creation.
    var ratchetTree: [UInt8]?
    /// TLS-serialized GroupInfo bytes for MLS channel creation.
    var groupInfo: [UInt8]?
    /// Whether MLS encryption is enabled for this channel.
    var mlsEnabled: Bool?

    init(
        cid: ChannelId,
        name: String?,
        description: String?,
        imageURL: String?,
        isPublic: Bool?,
        saveMessage: Bool?,
        members: Set<UserId>,
        invites: Set<UserId>,
        coolDownDuration: Int?,
        filterWords: [String]?
    ) {
        id = cid.id
        self.cid = cid
        self.name = name
        self.description = description
        self.imageURL = imageURL
        self.isPublic = isPublic
        self.saveMessage = saveMessage
        type = cid.type
        self.members = members
        self.invites = invites
        self.coolDownDuration = coolDownDuration
        self.filterWords = filterWords
    }

    init(
        type: ChannelType,
        name: String? = nil,
        description: String? = nil,
        imageURL: String? = nil,
        isPublic: Bool? = nil,
        saveMessage: Bool? = nil,
        members: Set<UserId> = [],
        invites: Set<UserId> = [],
        coolDownDuration: Int? = nil,
        filterWords: [String]? = nil
    ) {
        id = nil
        self.cid = nil
        self.name = name
        self.description = description
        self.imageURL = imageURL
        self.isPublic = isPublic
        self.saveMessage = saveMessage
        self.type = type
        self.members = members
        self.invites = invites
        self.coolDownDuration = coolDownDuration
        self.filterWords = filterWords
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: ChannelCodingKeys.self)

        var allMembers = members

        if !invites.isEmpty {
            allMembers = allMembers.union(invites)
            try container.encode(invites, forKey: .invites)
        }

        if !allMembers.isEmpty {
            try container.encode(allMembers, forKey: .members)
        }
        try container.encodeIfPresent(cid?.id, forKey: .channelId)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(description, forKey: .cDescription)
        try container.encodeIfPresent(imageURL, forKey: .imageURL)
        try container.encodeIfPresent(saveMessage, forKey: .saveMessage)
        try container.encodeIfPresent(isPublic, forKey: .isPublic)
        try container.encodeIfPresent(coolDownDuration, forKey: .cooldownDuration)
        try container.encodeIfPresent(filterWords, forKey: .filterWords)
        try container.encodeIfPresent(commit, forKey: .commit)
        try container.encodeIfPresent(welcome, forKey: .welcome)
        try container.encodeIfPresent(epoch, forKey: .epoch)
        try container.encodeIfPresent(ratchetTree, forKey: .ratchetTree)
        try container.encodeIfPresent(groupInfo, forKey: .groupInfo)
        try container.encodeIfPresent(mlsEnabled, forKey: .mlsEnabled)
    }
}

extension ChannelEditDetailPayload: APIPathConvertible {
    var apiPath: String {
        guard let id = id else {
            return type.rawValue
        }
        return type.rawValue + "/" + id
    }
}
