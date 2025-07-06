//
// Copyright 2025 Ermis Inc.
//

import CoreData
import Foundation

@objc(UserDTO)
class UserDTO: NSManagedObject {
    @NSManaged var id: String
    @NSManaged var projectId: String
    @NSManaged var name: String?
    @NSManaged var imageURL: URL?
    @NSManaged var isBanned: Bool
    @NSManaged var isOnline: Bool
    @NSManaged var lastActivityAt: DBDate?

    @NSManaged var userCreatedAt: DBDate?
    @NSManaged var userRoleRaw: String?
    @NSManaged var userUpdatedAt: DBDate?
    @NSManaged var userDeactivatedAt: DBDate?

    @NSManaged var flaggedBy: CurrentUserDTO?

    @NSManaged var members: Set<MemberDTO>?
    @NSManaged var messages: Set<MessageDTO>?
    @NSManaged var currentUser: CurrentUserDTO?
    @NSManaged var teams: [TeamId]
    @NSManaged var language: String?
    @NSManaged var email: [String]
    @NSManaged var phone: String?

    var userId: String {
        if id.hasSuffix(projectId) {
            return String(id.dropLast(projectId.count))
        }
        return id
    }

    /// Returns a fetch request for the dto with the provided `userId`.
    static func user(withID userId: UserId, projectId: String) -> NSFetchRequest<UserDTO> {
        let request = NSFetchRequest<UserDTO>(entityName: UserDTO.entityName)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \UserDTO.id, ascending: false)]
        request.predicate = NSPredicate(format: "id == %@", userId + projectId)
        return request
    }

    override func willSave() {
        super.willSave()

        // We need to propagate fake changes to other models so that it triggers FRC
        // updates for other entities. We also need to check that these models
        // don't have changes already, otherwise it creates an infinite loop.
        if hasPersistentChangedValues {
            if let currentUser = currentUser, !currentUser.hasChanges {
                let fakeNewUnread = currentUser.unreadChannelsCount
                currentUser.unreadChannelsCount = fakeNewUnread
            }
            for member in members ?? [] {
                if !member.hasChanges && !member.isDeleted {
                    let fakeNewChannelRole = member.channelRoleRaw
                    member.channelRoleRaw = fakeNewChannelRole
                }

                if !member.channel.hasChanges && !member.channel.isDeleted {
                    let fakeNewCid = member.channel.cid
                    member.channel.cid = fakeNewCid
                }
            }

            /// When a user updates, we want to trigger message updates, so that changes
            /// are reflected in the UI and the message authors are updated.
            /// It is important we only do this for name and images changes since this
            /// will trigger an event for every message that this user owns.
            let hasNameChanged = changedValues().keys.contains(#keyPath(UserDTO.name))
            let hasImageUrlChanged = changedValues().keys.contains(#keyPath(UserDTO.imageURL))
            if hasNameChanged || hasImageUrlChanged {
                for message in messages ?? [] {
                    if !message.hasChanges && !message.isDeleted {
                        message.user = self
                    }
                }
            }
        }
    }
}

extension UserDTO: EphemeralValuesContainer {
    func resetEphemeralValues() {
        isOnline = false
    }
}

extension UserDTO {
    /// Fetches and returns `UserDTO` with the given id. Returns `nil` if the entity doesn't exist.
    ///
    /// - Parameters:
    ///   - id: The id of the user to fetch
    ///   - context: The context used to fetch `UserDTO`
    ///
    static func load(id: String, projectId: String, context: NSManagedObjectContext) -> UserDTO? {
        return load(keyPath: "id", equalTo: id + projectId, context: context).first
    }

    /// If a User with the given id exists in the context, fetches and returns it. Otherwise creates a new
    /// `UserDTO` with the given id.
    ///
    /// - Parameters:
    ///   - id: The id of the user to fetch
    ///   - context: The context used to fetch/create `UserDTO`
    ///
    static func loadOrCreate(id: String, projectId: String, context: NSManagedObjectContext, cache: PreWarmedCache?) -> UserDTO {
        if let cachedObject = cache?.model(for: id + projectId , context: context, type: UserDTO.self) {
            return cachedObject
        }

        if let existing = load(id: id, projectId: projectId, context: context) {
            return existing
        }

        let request = fetchRequest(keyPath: "id", equalTo: id + projectId)
        let new = NSEntityDescription.insertNewObject(into: context, for: request)
        new.id = id + projectId
        new.teams = []
        new.isBanned = false
        new.isOnline = false
        return new
    }

    static func loadLastActiveWatchers(cid: ChannelId, context: NSManagedObjectContext) -> [UserDTO] {
        let request = NSFetchRequest<UserDTO>(entityName: UserDTO.entityName)
        request.sortDescriptors = [
            UserListSortingKey.lastActiveSortDescriptor,
            UserListSortingKey.defaultSortDescriptor
        ]
        request.predicate = NSPredicate(format: "ANY watchedChannels.cid == %@", cid.rawValue)
        request.fetchLimit = context.localCachingSettings?.channel.lastActiveWatchersLimit ?? 100
        return load(by: request, context: context)
    }
}

extension NSManagedObjectContext: UserDatabaseSession {
    func user(id: UserId, projectId: String) -> UserDTO? {
        UserDTO.load(id: id, projectId: projectId, context: self)
    }

    func saveUser(
        payload: UserPayload,
        projectId: String,
        query: UserListQuery?,
        cache: PreWarmedCache?
    ) throws -> UserDTO {
        let dto = UserDTO.loadOrCreate(id: payload.id, projectId: projectId, context: self, cache: cache)
        if dto.projectId.isEmpty || !payload.projectId.isEmpty {
            dto.projectId = projectId
        }
        if dto.name.isEmptyOrNil || !payload.name.isEmptyOrNil {
            dto.name = payload.name
        }
        
        if dto.imageURL == nil || payload.imageURL != nil {
            dto.imageURL = payload.imageURL
        }
        
        if let isBanned = payload.isBanned {
            dto.isBanned = isBanned
        }
        
        if let isOnline = payload.isOnline {
            dto.isOnline = isOnline
        }
        
        if let userCreatedAt = payload.createdAt?.bridgeDate {
            dto.userCreatedAt = userCreatedAt
        }
        
        if let userRoleRaw = payload.role?.rawValue {
            dto.userRoleRaw =  userRoleRaw
        }
        
        if let updatedAt = payload.updatedAt?.bridgeDate {
            dto.userUpdatedAt = updatedAt
        }
        
        if let userDeactivatedAt = payload.deactivatedAt?.bridgeDate {
            dto.userDeactivatedAt = userDeactivatedAt
        }
        
        if !payload.language.isEmptyOrNil {
            dto.language = payload.language
        }
        
        if !payload.phone.isEmptyOrNil {
            dto.phone = payload.phone
        }
        
        if let email = payload.email {
            dto.email = email
        }

        dto.teams = payload.teams

        // payloadHash doesn't cover the query
        if let query = query, let queryDTO = try saveQuery(query: query) {
            queryDTO.users.insert(dto)
        }

        if currentUser?.users.first?.userId == dto.userId {
            currentUser?.users.insert(dto)
            dto.currentUser = currentUser
        }
        return dto
    }

    @discardableResult
    func saveUsers(payload: UserListPayload, projectId: String, query: UserListQuery?) -> [UserDTO] {
        let cache = payload.getPayloadToModelIdMappings(context: self)
        return payload.users.compactMapLoggingError {
            try saveUser(payload: $0, projectId: projectId, query: query, cache: cache)
        }
    }
}

extension UserDTO {
    /// Snapshots the current state of `UserDTO` and returns an immutable model object from it.
    func asModel() throws -> ChatUser { try .create(fromDTO: self) }

    /// Snapshots the current state of `UserDTO` and returns its representation for used in API calls.
    func asRequestBody() -> UserRequestBody {

        return .init(id: id, name: name, imageURL: imageURL)
    }
}

extension UserDTO {
    static func userListFetchRequest(query: UserListQuery) -> NSFetchRequest<UserDTO> {
        let request = NSFetchRequest<UserDTO>(entityName: UserDTO.entityName)

        // Fetch results controller requires at least one sorting descriptor.
        let sortDescriptors = query.sort.compactMap { $0.key.sortDescriptor(isAscending: $0.isAscending) }
        request.sortDescriptors = sortDescriptors.isEmpty ? [UserListSortingKey.defaultSortDescriptor] : sortDescriptors

        // If a filter exists, use is for the predicate. Otherwise, `nil` filter matches all users.
        if let filterHash = query.filter?.filterHash {
            request.predicate = NSPredicate(format: "ANY queries.filterHash == %@", filterHash)
        }
        return request
    }

    static func userListFetchRequest(userIds: [UserId], projectId: String) -> NSFetchRequest<UserDTO> {
        let request = NSFetchRequest<UserDTO>(entityName: UserDTO.entityName)
        request.sortDescriptors = [UserListSortingKey.defaultSortDescriptor]
        request.predicate = NSPredicate(format: "id in %@", userIds.map{ $0 + projectId})
        return request
    }

    static var userWithoutQueryFetchRequest: NSFetchRequest<UserDTO> {
        let request = NSFetchRequest<UserDTO>(entityName: UserDTO.entityName)
        request.sortDescriptors = [UserListSortingKey.defaultSortDescriptor]
        request.predicate = NSPredicate(format: "queries.@count == 0")
        return request
    }

    static func watcherFetchRequest(cid: ChannelId) -> NSFetchRequest<UserDTO> {
        let request = NSFetchRequest<UserDTO>(entityName: UserDTO.entityName)
        request.sortDescriptors = [UserListSortingKey.defaultSortDescriptor]
        request.predicate = NSPredicate(format: "ANY watchedChannels.cid == %@", cid.rawValue)
        return request
    }
}

extension ChatUser {
    fileprivate static func create(fromDTO dto: UserDTO) throws -> ChatUser {

        let language: TranslationLanguage? = dto.language.map(TranslationLanguage.init)
        return ChatUser(
            id: dto.userId,
            projectId: dto.projectId,
            name: dto.name,
            imageURL: dto.imageURL,
            phone: dto.phone,
            email: dto.email,
            isOnline: dto.isOnline,
            isBanned: dto.isBanned,
            isFlaggedByCurrentUser: dto.flaggedBy != nil,
            userRole: UserRole(rawValue: dto.userRoleRaw ?? ""),
            createdAt: dto.userCreatedAt?.bridgeDate,
            updatedAt: dto.userUpdatedAt?.bridgeDate,
            deactivatedAt: dto.userDeactivatedAt?.bridgeDate,
            lastActiveAt: dto.lastActivityAt?.bridgeDate,
            teams: Set(dto.teams),
            language: language
        )
    }
}
