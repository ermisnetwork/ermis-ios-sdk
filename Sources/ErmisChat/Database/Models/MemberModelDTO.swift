//
// Copyright 2025 Ermis Inc.
//

import CoreData

@objc(MemberDTO)
class MemberDTO: NSManagedObject {
    // Because we need to have a unique identifier of a member in the db, we use the combination of the related
    // user' id and the channel the member belongs to.
    @NSManaged fileprivate(set) var id: String

    // This value is optional only temprorary until this is fixed https://Ermis.slack.com/archives/CE5N802GP/p1592925726015900
    @NSManaged var channelRoleRaw: String?
    @NSManaged var memberCreatedAt: DBDate?
    @NSManaged var memberUpdatedAt: DBDate?

    @NSManaged var banExpiresAt: DBDate?
    @NSManaged var isBanned: Bool
    @NSManaged var isBlocked: Bool
    @NSManaged var isShadowBanned: Bool
    @NSManaged var muted: DBDate?

    @NSManaged var inviteAcceptedAt: DBDate?
    @NSManaged var inviteRejectedAt: DBDate?
//    @NSManaged var isInvited: Bool

    // MARK: - Relationships

    @NSManaged var user: UserDTO
    @NSManaged var queries: Set<ChannelMemberListQueryDTO>
    @NSManaged var channel: ChannelDTO

    private static func createId(userId: String, channeldId: ChannelId) -> String {
        channeldId.rawValue + userId
    }

    /// A boolean value that returns whether the user has enable notification for this channel or not.
    var notificationEnable: Bool {
        guard let muted else {
            return true
        }
        return Date() > muted.bridgeDate
    }
    
    var isJoined: Bool {
        switch channelRoleRaw {
        case MemberRole.owner.rawValue, MemberRole.admin.rawValue, MemberRole.moderator.rawValue, MemberRole.member.rawValue:
            return true
        default:
            return false
        }
    }
}

// MARK: - Fetch requests

extension MemberDTO {
    /// Returns a fetch request for the dto with the provided `userId`.
    static func member(_ userId: UserId, in cid: ChannelId) -> NSFetchRequest<MemberDTO> {
        let request = NSFetchRequest<MemberDTO>(entityName: MemberDTO.entityName)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \MemberDTO.memberCreatedAt, ascending: false)]
        request.predicate = NSPredicate(format: "id == %@", Self.createId(userId: userId, channeldId: cid))
        return request
    }

    /// Returns a fetch request for the DTOs matching the provided `query`.
    static func members(matching query: ChannelMemberListQuery) -> NSFetchRequest<MemberDTO> {
        let request = NSFetchRequest<MemberDTO>(entityName: MemberDTO.entityName)
        request.predicate = NSPredicate(format: "ANY queries.queryHash == %@", query.queryHash)
        request.sortDescriptors = query.sortDescriptors
        return request
    }
}

extension MemberDTO {
    static func load(userId: String, channelId: ChannelId, context: NSManagedObjectContext) -> MemberDTO? {
        let memberId = MemberDTO.createId(userId: userId, channeldId: channelId)
        return load(memberId: memberId, context: context)
    }

    static func load(memberId: String, context: NSManagedObjectContext) -> MemberDTO? {
        load(by: memberId, context: context).first
    }

    /// If a User with the given id exists in the context, fetches and returns it. Otherwise create a new
    /// `UserDTO` with the given id.
    ///
    /// - Parameters:
    ///   - id: The id of the user to fetch
    ///   - context: The context used to fetch/create `UserDTO`
    ///
    static func loadOrCreate(
        userId: String,
        channelId: ChannelId,
        context: NSManagedObjectContext,
        cache: PreWarmedCache?
    ) -> MemberDTO {
        let memberId = MemberDTO.createId(userId: userId, channeldId: channelId)
        if let cachedObject = cache?.model(for: memberId, context: context, type: MemberDTO.self) {
            return cachedObject
        }

        if let existing = load(memberId: memberId, context: context) {
            return existing
        }

        let request = fetchRequest(id: memberId)
        let new = NSEntityDescription.insertNewObject(into: context, for: request)
        new.id = memberId
        return new
    }

    static func loadLastActiveMembers(cid: ChannelId, context: NSManagedObjectContext) -> [MemberDTO] {
        let request = NSFetchRequest<MemberDTO>(entityName: MemberDTO.entityName)
        request.predicate = NSPredicate(format: "channel.cid == %@", cid.rawValue)
        request.sortDescriptors = [
            ChannelMemberListSortingKey.idSortDescriptor,
//            ChannelMemberListSortingKey.defaultSortDescriptor
        ]
        request.fetchLimit = context.localCachingSettings?.channel.lastActiveMembersLimit ?? 100
        return load(by: request, context: context)
    }
}

extension NSManagedObjectContext {
    func saveMember(
        payload: MemberPayload,
        channelId: ChannelId,
        query: ChannelMemberListQuery?,
        cache: PreWarmedCache?
    ) throws -> MemberDTO {
        let dto = MemberDTO.loadOrCreate(userId: payload.userId, channelId: channelId, context: self, cache: cache)

        // Save user-part of member first
        if let userPayload = payload.user {
            dto.user = try saveUser(payload: userPayload, projectId: channelId.projectId)
        }

        // Save member specific data
        if let role = payload.role {
            dto.channelRoleRaw = role.rawValue
        }

        dto.memberCreatedAt = payload.createdAt?.bridgeDate
        dto.memberUpdatedAt = payload.updatedAt?.bridgeDate
        
        if let isBanned = payload.isBanned {
            dto.isBanned = isBanned
        }

        if let isBlocked = payload.isBlocked {
            dto.isBlocked = isBlocked
        }

        if let isShadowBanned = payload.isShadowBanned {
            dto.isShadowBanned = isShadowBanned
        }
        dto.banExpiresAt = payload.banExpiresAt?.bridgeDate
//        dto.isInvited = payload.isInvited ?? false
        dto.inviteAcceptedAt = payload.inviteAcceptedAt?.bridgeDate
        dto.inviteRejectedAt = payload.inviteRejectedAt?.bridgeDate
        dto.muted = payload.muted?.bridgeDate

        if let query = query {
            let queryDTO = try saveQuery(query)
            queryDTO.members.insert(dto)
        }

        return dto
    }

    func member(userId: UserId, cid: ChannelId) -> MemberDTO? {
        MemberDTO.load(userId: userId, channelId: cid, context: self)
    }

    func saveMembers(payload: ChannelMemberListPayload, channelId: ChannelId, query: ChannelMemberListQuery?) -> [MemberDTO] {
        // If it is the first page of the members list, make sure to clear the members from local cache
        // which are not in the remote response anymore.
        let isFirstPage = query?.pagination.offset == 0
        if let queryHash = query?.queryHash, isFirstPage {
            let queryDTO = ChannelMemberListQueryDTO.load(queryHash: queryHash, context: self)
            queryDTO?.members = []
        }

        let cache = payload.getPayloadToModelIdMappings(context: self)
        return payload.members.compactMapLoggingError {
            try saveMember(payload: $0, channelId: channelId, query: query, cache: cache)
        }
    }
}

extension MemberDTO {
    func asModel() throws -> ChannelMember { try .create(fromDTO: self) }
}

extension ChannelMember {
    fileprivate static func create(fromDTO dto: MemberDTO) throws -> ChannelMember {

        let role = dto.channelRoleRaw.flatMap { MemberRole(rawValue: $0) } ?? .member
        let language: TranslationLanguage? = dto.user.language.map(TranslationLanguage.init)
        return ChannelMember(
            id: dto.user.id,
            projectId: dto.user.projectId,
            name: dto.user.name,
            imageURL: dto.user.imageURL,
            phone: dto.user.phone,
            email: dto.user.email,
            isOnline: dto.user.isOnline,
            isBanned: dto.user.isBanned,
            isFlaggedByCurrentUser: dto.user.flaggedBy != nil,
            userRole: UserRole(rawValue: dto.user.userRoleRaw ?? ""),
            userCreatedAt: dto.user.userCreatedAt?.bridgeDate,
            userUpdatedAt: dto.user.userUpdatedAt?.bridgeDate,
            deactivatedAt: dto.user.userDeactivatedAt?.bridgeDate,
            lastActiveAt: dto.user.lastActivityAt?.bridgeDate,
            teams: Set(dto.user.teams),
            language: language,
            memberRole: role,
            memberCreatedAt: dto.memberCreatedAt?.bridgeDate,
            memberUpdatedAt: dto.memberUpdatedAt?.bridgeDate,
//            isInvited: dto.isInvited,
            inviteAcceptedAt: dto.inviteAcceptedAt?.bridgeDate,
            inviteRejectedAt: dto.inviteRejectedAt?.bridgeDate,
            isBannedFromChannel: dto.isBanned,
            isBlockedFromChannel: dto.isBlocked,
            banExpiresAt: dto.banExpiresAt?.bridgeDate,
            isShadowBannedFromChannel: dto.isShadowBanned,
            muted: dto.muted?.bridgeDate
        )
    }
}

extension ChannelMemberListQuery {
    var sortDescriptors: [NSSortDescriptor] {
        let sortDescriptors = sort.compactMap { $0.key.sortDescriptor(isAscending: $0.isAscending) }
//        return sortDescriptors.isEmpty ? [ChannelMemberListSortingKey.defaultSortDescriptor] : sortDescriptors
        return sortDescriptors
    }
}
