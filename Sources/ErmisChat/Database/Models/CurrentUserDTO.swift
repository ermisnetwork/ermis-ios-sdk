//
// Copyright 2025 Ermis Inc.
//

import CoreData
import Foundation

@objc(CurrentUserDTO)
class CurrentUserDTO: NSManagedObject {
    @NSManaged var unreadChannelsCount: Int64
    @NSManaged var unreadMessagesCount: Int64

    /// Contains the timestamp when last sync process was finished.
    /// The date later serves as reference date for the last event synced using `/sync` endpoint
    @NSManaged var lastSynchedEventDate: DBDate?

    @NSManaged var flaggedUsers: Set<UserDTO>
    @NSManaged var flaggedMessages: Set<MessageDTO>
    @NSManaged var mutedUsers: Set<UserDTO>
    @NSManaged var users: Set<UserDTO>
    @NSManaged var devices: Set<DeviceDTO>
    @NSManaged var currentDevice: DeviceDTO?
    @NSManaged var isInvisible: Bool

    /// Returns a default fetch request for the current user.
    static var defaultFetchRequest: NSFetchRequest<CurrentUserDTO> {
        let request = NSFetchRequest<CurrentUserDTO>(entityName: CurrentUserDTO.entityName)
        // Sorting doesn't matter here as soon as we have a single current-user in a database.
        // It's here to make the request safe for FRC
        request.sortDescriptors = [.init(keyPath: \CurrentUserDTO.unreadMessagesCount, ascending: true)]
        return request
    }

    func user(of projectId: String) -> UserDTO? {
        return users.first(where: { $0.projectId == projectId })
    }
}

extension CurrentUserDTO {
    /// Returns an existing `CurrentUserDTO`. Returns `nil` of no `CurrentUserDTO` exists in the DB.
    ///
    /// - Parameter context: The context used to fetch `CurrentUserDTO`
    fileprivate static func load(context: NSManagedObjectContext) -> CurrentUserDTO? {
        let request = NSFetchRequest<CurrentUserDTO>(entityName: CurrentUserDTO.entityName)
        let result = load(by: request, context: context)

        log.assert(
            result.count <= 1,
            "The database is corrupted. There is more than 1 entity of the type `CurrentUserDTO` in the DB."
        )

        return result.first
    }

    /// If the `CurrentUserDTO` entity exists in the context, fetches and returns it. Otherwise create a new `CurrentUserDTO`.
    ///
    /// - Parameter context: The context used to fetch/create `CurrentUserDTO`
    fileprivate static func loadOrCreate(context: NSManagedObjectContext) -> CurrentUserDTO {
        let request = NSFetchRequest<CurrentUserDTO>(entityName: CurrentUserDTO.entityName)
        let result = load(by: request, context: context)

        if let existing = result.first {
            return existing
        }

        let new = NSEntityDescription.insertNewObject(into: context, for: request)
        return new
    }
}

extension NSManagedObjectContext: CurrentUserDatabaseSession {
    func saveCurrentUser(payload: CurrentUserPayload, projectId: String) throws -> CurrentUserDTO {
        invalidateCurrentUserCache(projectId: projectId)
        
        let dto = CurrentUserDTO.loadOrCreate(context: self)

        let user = try saveUser(payload: payload, projectId: projectId)
        if user.isOnline == nil {
            user.isOnline = false
        }

        dto.users.insert(user)
        if let isInvisible = payload.isInvisible {
            dto.isInvisible = isInvisible
        }

        let mutedUsers = try payload.mutedUsers.map { try saveUser(payload: $0.mutedUser, projectId: projectId) }
        dto.mutedUsers = Set(mutedUsers)

        if let unreadCount = payload.unreadCount {
            try saveCurrentUserUnreadCount(count: unreadCount, projectId: projectId)
        }

        _ = try saveCurrentUserDevices(payload.devices, projectId: projectId, clearExisting: true)
        return dto
    }

    func saveCurrentUserUnreadCount(count: UnreadCount, projectId: String) throws {
        invalidateCurrentUserCache(projectId: projectId)

        guard let dto = currentUser else {
            throw ClientError.CurrentUserDoesNotExist()
        }

        dto.unreadChannelsCount = Int64(clamping: count.channels)
        dto.unreadMessagesCount = Int64(clamping: count.messages)
    }

    func saveCurrentUserDevices(_ devices: [DevicePayload],
                                projectId: String,
                                clearExisting: Bool) throws -> [DeviceDTO] {
        invalidateCurrentUserCache(projectId: projectId)

        guard let currentUser = currentUser else {
            throw ClientError.CurrentUserDoesNotExist()
        }

        if clearExisting {
            currentUser.devices.removeAll()
            if !devices.contains(where: { $0.id == currentUser.currentDevice?.id }) {
                currentUser.currentDevice = nil
            }
        }

        let deviceDTOs = devices.map { device -> DeviceDTO in
            let dto = DeviceDTO.loadOrCreate(id: device.id, context: self)
            dto.createdAt = device.createdAt?.bridgeDate
            dto.user = currentUser
            return dto
        }

        return deviceDTOs
    }

    func saveCurrentDevice(_ deviceId: String, projectId: String) throws {
        invalidateCurrentUserCache(projectId: projectId)

        guard let currentUser = currentUser else {
            throw ClientError.CurrentUserDoesNotExist()
        }

        let dto = DeviceDTO.loadOrCreate(id: deviceId, context: self)
        dto.user = currentUser
        currentUser.currentDevice = dto
    }

    func deleteDevice(id: String) {
        if let dto = DeviceDTO.load(id: id, context: self) {
            delete(dto)
        }
    }

    private static let currentUserKey = "network.ermis.chat.core.context.current_user_key"

    var currentUser: CurrentUserDTO? {
        // we already have cached value in `userInfo` so all setup is complete
        // so we can just return cached value
        if let currentUser = userInfo[Self.currentUserKey] as? CurrentUserDTO {
            return currentUser
        }

        // we do not have cached value in `userInfo` so we try to load current user from DB
        if let currentUser = CurrentUserDTO.load(context: self) {
            // if we have current user we save it to `userInfo` so we do not have to load it again
            userInfo[Self.currentUserKey] = currentUser
            return currentUser
        }

        // we really don't have current user
        return nil
    }

    func invalidateCurrentUserCache(projectId: String) {
        var currentUserDict = userInfo[Self.currentUserKey] as? [String: CurrentUserDTO] ?? [:]
        currentUserDict[projectId] = nil
        userInfo[Self.currentUserKey] = currentUserDict
    }

    func invalidateCurrentUserCache() {
        userInfo[Self.currentUserKey] = nil
    }
}

extension CurrentUserDTO {
    /// Snapshots the current state of `CurrentUserDTO` and returns an immutable model object from it.
    func asModel(_ projectId: String) throws -> CurrentChatUser { try .create(fromDTO: self, projectId: projectId) }
}

extension CurrentChatUser {
    fileprivate static func create(fromDTO dto: CurrentUserDTO, projectId: String) throws -> CurrentChatUser {
        guard let context = dto.managedObjectContext else { throw InvalidModel(dto) }
        guard let user = dto.users.first(where: { $0.projectId == projectId }) else { throw InvalidModel(dto)}

        let mutedUsers: [ChatUser] = try dto.mutedUsers.map { try $0.asModel() }
        let flaggedUsers: [ChatUser] = try dto.flaggedUsers.map { try $0.asModel() }
        let flaggedMessagesIDs: [MessageId] = dto.flaggedMessages.map(\.id)

        let language: TranslationLanguage? = user.language.map(TranslationLanguage.init)

        return try CurrentChatUser(
            id: user.userId,
            projectId: user.projectId,
            name: user.name,
            imageURL: user.imageURL,
            phone: user.phone,
            email: user.email,
            isOnline: user.isOnline,
            isInvisible: dto.isInvisible,
            isBanned: user.isBanned,
            userRole: UserRole(rawValue: user.userRoleRaw ?? ""),
            createdAt: user.userCreatedAt?.bridgeDate,
            updatedAt: user.userUpdatedAt?.bridgeDate,
            deactivatedAt: user.userDeactivatedAt?.bridgeDate,
            lastActiveAt: user.lastActivityAt?.bridgeDate,
            teams: Set(user.teams),
            language: language,
            devices: dto.devices.map { try $0.asModel() },
            currentDevice: dto.currentDevice?.asModel(),
            mutedUsers: Set(mutedUsers),
            flaggedUsers: Set(flaggedUsers),
            flaggedMessageIDs: Set(flaggedMessagesIDs),
            unreadCount: UnreadCount(
                channels: Int(dto.unreadChannelsCount),
                messages: Int(dto.unreadMessagesCount)
            ),
            underlyingContext: context
        )
    }
}
