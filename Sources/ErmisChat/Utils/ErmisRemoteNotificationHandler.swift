//
// Copyright 2025 Ermis Inc.
//

import CoreData
import Foundation
import UserNotifications

public class MessageNotificationContent {
    public let message: ChatMessage
    public let channel: Channel?

    public init(message: ChatMessage, channel: Channel?) {
        self.message = message
        self.channel = channel
    }
}

public class ReactionNewNotificationContent {
    public let user: ChatUser
    public let reactionType: MessageReactionType

    init(user: ChatUser, reactionType: MessageReactionType) {
        self.user = user
        self.reactionType = reactionType
    }
}

public class UnknownNotificationContent {
    public let content: UNNotificationContent

    public init(content: UNNotificationContent) {
        self.content = content
    }
}

public struct PushNotificationContent {
    public let type: PushNotificationContentType
    public var cid: ChannelId?
    public var message: ChatMessage?
    public var channel: Channel?
    public var user: ChatUser?
    public var reactionType: MessageReactionType?
    public var event: Event?
    public var content: UNNotificationContent

    public init(type: PushNotificationContentType = .addedToChannel, cid: ChannelId? = nil, message: ChatMessage? = nil, channel: Channel? = nil, user: ChatUser? = nil, reactionType: MessageReactionType? = nil, event: Event? = nil, content: UNNotificationContent) {
        self.type = type
        self.cid = cid
        self.message = message
        self.channel = channel
        self.user = user
        self.reactionType = reactionType
        self.event = event
        self.content = content
    }
}

public enum PushNotificationContentType {
    case message
    case addedToChannel
    case channelDelete
    case reactionNew
    case memberPromoted
    case memberDemoted
    case memberBanned
    case memberUnBanned
    case userAcceptInvitation
    case editMessage
    case callSignal
    case unknown
}

enum PushNotificationError: Error {
    case invalidUserInfo(String)
}

public class PushNotificationInfo {
    public let cid: ChannelId?
    public let parentCid: ChannelId?
    public let messageId: MessageId?
    public let eventType: EventType?
    public let custom: [String: String]?

    public init(content: UNNotificationContent) throws {
        guard let stringPayload = content.userInfo["data"] as? String,
              let data = stringPayload.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PushNotificationError.invalidUserInfo("missing data")
        }

        guard let type = payload["type"] as? String else {
            throw PushNotificationError.invalidUserInfo("missing type key")
        }

        eventType = EventType(rawValue: type)

        if let cid = payload["cid"] as? String {
            self.cid = try? ChannelId(cid: cid)
        } else {
            cid = nil
        }

        if let parentCid = payload["parent_cid"] as? String {
            self.parentCid = try? ChannelId(cid: parentCid)
        } else {
            parentCid = nil
        }

        if EventType.messageNew.rawValue == type,
           let id = payload["id"] as? String {
            messageId = MessageId(id)
        } else {
            messageId = nil
        }

        custom = payload.removingValues(forKeys: ["cid", "type", "id"]) as? [String: String]
    }
}

public class RemoteNotificationHandler {
    var client: ErmisClient
    var content: UNNotificationContent
    let chatCategoryIdentifiers: Set<String> = ["ermis.chat", "MESSAGE_NEW"]
    let database: DatabaseContainer
    let messageRepository: MessageRepository
    let extensionLifecycle: NotificationExtensionLifecycle
    let eventDecoder: AnyEventDecoder

    public init(client: ErmisClient, eventDecoder: AnyEventDecoder, content: UNNotificationContent) {
        self.client = client
        self.content = content
        self.eventDecoder = eventDecoder
        database = client.databaseContainer
        messageRepository = client.messageRepository
        extensionLifecycle = client.extensionLifecycle
    }

    public func handleNotification() async -> PushNotificationContent {
        await withCheckedContinuation { continuation in
            handleNotification { content in
                continuation.resume(returning: content)
            }
        }
    }

    public func handleNotification(completion: @escaping (PushNotificationContent) -> Void) -> Bool {
        getContent(completion: completion)
        return true
    }

    private func getContent(completion: @escaping (PushNotificationContent) -> Void) {
        guard let payload = content.userInfo["data"] as? String else {
            completion(PushNotificationContent(type: .unknown, content: content))
            return
        }
        getContent(from: payload, completion: completion)
    }

    private func getContent(from payload: String, completion: @escaping (PushNotificationContent) -> Void) {
        guard let jsonData = payload.data(using: .utf8),
              let event = try? eventDecoder.decode(from: jsonData) else {
            completion(PushNotificationContent(type: .unknown, content: content))
            return
        }

        client.eventNotificationCenter.process(event) {
            getContent(from: event, completion: completion)
        }

        func getContent(from event: Event, completion: @escaping (PushNotificationContent) -> Void) {
            switch event {
            case let event as MessageNewEventDTO:
                // Get user'name first
                getUserInfo(userId: event.user.userId, projectId: event.cid.projectId) { user in
                    self.database.write { session in

                        guard let message = try? session.message(id: event.message.id)?.asModel(),
                              let channel = try? session.channel(cid: event.cid)?.asModel() else {
                            return
                        }
                        completion(PushNotificationContent(type: .message,
                                                           cid: event.cid,
                                                           message: message,
                                                           channel: channel,
                                                           user: user,
                                                           event: event,
                                                           content: self.content))
                    }
                }
            case let event as NotificationChannelCreatedEventDTO:
                let channel = getChannel(with: event.channel.cid)
                completion(.init(type: .addedToChannel,
                                 cid: event.channel.cid,
                                 channel: channel,
                                 event: event,
                                 content: self.content))
            case let event as NotificationChannelDeletedEventDTO:
                let channel = getChannel(with: event.channel.cid)

                completion(.init(type: .channelDelete,
                                 cid: event.cid,
                                 channel: channel,
                                 event: event,
                                 content: self.content))
            case let event as ReactionNewEventDTO:
                getUserInfo(userId: event.user.userId, projectId: event.cid.projectId) { user in
                    guard let user else {
                        completion(PushNotificationContent(type: .unknown,
                                                           cid: event.cid,
                                                           event: event,
                                                           content: self.content))
                        return
                    }
                    let reactionType = event.reaction.type
                    completion(.init(type: .reactionNew,
                                     cid: event.cid,
                                     user: user, reactionType: reactionType,
                                     event: event,
                                     content: self.content))
                }
            case let event as MemberUpdatedEventDTO:
                let channel = getChannel(with: event.cid)
                if event.member.role == .member {
                    completion(.init(type: .memberDemoted,
                                     cid: event.cid,
                                     channel: channel,
                                     event: event,
                                     content: content))
                } else if event.member.role == .moderator {
                    completion(.init(type: .memberPromoted,
                                     cid: event.cid,
                                     channel: channel,
                                     event: event,
                                     content: content))
                }
            case let event as MemberBannedEventDTO:
                let channel = getChannel(with: event.cid)
                completion(.init(type: .memberBanned,
                                 cid: event.cid,
                                 channel: channel,
                                 event: event,
                                 content: content))
            case let event as MemberUnbannedEventDTO:
                let channel = getChannel(with: event.cid)
                completion(.init(type: .memberUnBanned,
                                 cid: event.cid,
                                 channel: channel,
                                 event: event,
                                 content: content))
            case let event as NotificationInviteAcceptedEventDTO:
                getUserInfo(userId: event.member.userId, projectId: event.cid.projectId) { [weak self] user in
                    guard let self else {
                        return
                    }
                    guard let user else {
                        completion(PushNotificationContent(type: .unknown,
                                                           cid: event.cid,
                                                           event: event,
                                                           content: self.content))
                        return
                    }
                    let channel = self.getChannel(with: event.cid)
                    completion(.init(type: .userAcceptInvitation,
                                     cid: event.cid,
                                     channel: channel,
                                     user: user,
                                     event: event,
                                     content: content))
                }
            case let event as MessageUpdatedEventDTO:
                // Get user'name first
                getUserInfo(userId: event.user.userId, projectId: event.cid.projectId) { user in
                    self.database.write { session in

                        guard let message = try? session.saveMessage(payload: event.message,
                                                                     for: event.cid,
                                                                     syncOwnReactions: false,
                                                                     cache: nil).asModel() else {
                            completion(PushNotificationContent(type: .unknown, event: event, content: self.content))
                            return
                        }

                        let channel = try? session.channel(cid: event.cid)?.asModel()
                        completion(.init(type: .message,
                                         cid: event.cid,
                                         channel: channel,
                                         user: user,
                                         event: event,
                                         content: self.content))
                    }
                }
            case let event as CallSignalEventDTO:
                let channel = self.getChannel(with: event.cid)
                completion(.init(type: .callSignal,
                                 cid: event.cid,
                                 channel: channel,
                                 event: event,
                                 content: self.content))
            default:
                completion(PushNotificationContent(type: .unknown,
                                                   event: event,
                                                   content: self.content))
            }
        }
    }

    private func getChannel(with cid: ChannelId) -> Channel? {
        let channel = try? ChannelDTO.load(cid: cid, context: database.backgroundReadOnlyContext)?.asModel()
        return channel
    }

    private func getUserInfo(userId: String, projectId: String, completion: @escaping (ChatUser?) -> Void) {
        if let user = database.backgroundReadOnlyContext.user(id: userId, projectId: projectId) {
            if !user.name.isEmptyOrNil {
                completion(try? user.asModel())
                return
            }
        }
        // Get user name if don't have in db
        client.apiClient.request(endpoint: .getUserInfo(id: userId, projectId: projectId)) { result in
            switch result {
            case .success(let user):
                self.database.write { session in
                    let userDto = try? session.saveUser(payload: user, projectId: projectId)
                    let user = try? userDto?.asModel()
                    completion(user)
                }
            case .failure(let failure):
                completion(nil)
            }
        }
    }
}
