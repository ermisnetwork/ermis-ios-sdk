//
// Copyright 2025 Ermis Inc.
//

import Foundation

enum EndpointPath: Codable {
    case connect
    case sync
    case friendContacts
    case users
    case usersSearch
    case userBatch
    case getUser(String)
    case getUserInfo(String)
    case getDeleteUserChallange
    case getDeleteUserOtp
    case deleteUser
    case invite(cid: ChannelId, type: String)
    case updateUsers
    case uploadUserAvatar
    case guest
    case members
    case search
    case devices(String)
    case og

    case threads
    case thread(messageId: String)

    case channels
    case createChannel(String)
    case updateChannel(String)
    case deleteChannel(String)
    case truncatedChannel(channelId: ChannelId)
    case channelUpdate(String)
    case joinChannel(channelType: String)
    case channelSearch
    case channelPublicSearch
    case muteChannel(channelId: ChannelId)
    case pinChannel(channelId: ChannelId)
    case unPinChannel(channelId: ChannelId)
    case showChannel(String, Bool)
    case markChannelRead(String, String?)
    case markChannelUnread(String)
    case markAllChannelsRead
    case channelEvent(String)
    case stopWatchingChannel(String)
    case pinnedMessages(String)
    case uploadAttachment(channelId: ChannelId, type: String)
    case channelDetailUpdate(cid: ChannelId)
    case getAttachments(cid: ChannelId)
    case enableTopics(channelId: ChannelId)
    case disableTopics(channelId: ChannelId)
    case createTopic(String)
    case editTopic(String)
    case closeTopic(channelId: ChannelId)
    case reopenTopic(channelId: ChannelId)

    case sendMessage(ChannelId)
    case message(MessageId)
    case editMessage(MessageId, ChannelId)
    case deleteMessage(MessageId, ChannelId)
    case pinMessage(MessageId, ChannelId)
    case unPinMessage(MessageId, ChannelId)
    case replies(MessageId)
    case reactions(MessageId)
    case addReaction(cid: ChannelId,
                     messageId: MessageId,
                     reactionType: MessageReactionType)
    case deleteReaction(cid: ChannelId,
                        messageId: MessageId,
                        reactionType: MessageReactionType)
    case messageAction(MessageId)
    case translateMessage(MessageId)

    case banMember
    case muteUser(Bool)
    
    case deleteFile(String)
    case deleteImage(String)

    case stickerPacks(packName: String?)
    case sticker(path: String)

    case getOtp
    case register
    case loginWithOTP
    case loginWithGoogle
    case loginWithApple

    case subscribe
    case unread

    case signWallet
    case walletAuthenticate
    case refreshToken(Token)
    case getChains
    case getUserClients
    case getUserProjects
    case joinProject
    // Call
    case signal

    var value: String {
        switch self {
        case .connect: 
            return "connect"
        case .sync:
            return "sync"
        case .friendContacts:
            return "contacts/list"
        case .users:
            return "uss/v1/users"
        case .usersSearch:
            return "uss/v1/users/search"
        case .userBatch:
            return "uss/v1/users/batch"
        case .getUser(let id):
            return "uss/v1/users/\(id)"
        case .updateUsers:
            return "uss/v1/users/update"
        case .uploadUserAvatar:
            return "uss/v1/users/upload"
        case .getUserInfo(let id):
            return "uss/v1/users/get-info/\(id)"
        case .getDeleteUserChallange:
            return "uss/v1/users/challenge"
        case .getDeleteUserOtp:
            return "uss/v1/users/get_delete_otp"
        case .deleteUser:
            return "uss/v1/users/delete_user_with_otp"
        case .invite(cid: let cid,
                     type: let type):
            return "invites/\(cid.type.rawValue)/\(cid.id)/\(type)"
        case .channelDetailUpdate(cid: let cid):
            return "channels/\(cid.apiPath)"
        case .joinChannel(let channelType):
            return "uss/v1/token_gate/join_channel/\(channelType)"
        case .channelSearch:
            return "channels/search"
        case .channelPublicSearch:
            return "channels/public/search"
        case .getAttachments(let cid):
            return "channels/\(cid.apiPath)/attachment"
        case .guest:
            return "guest"
        case .members:
            return "members"
        case .search:
            return "search"
        case .devices(let path):
            return "devices/\(path)"
        case .og:
            return "og"

        case .threads: 
            return "threads"
        case .thread(let messageId):
            return "threads/\(messageId)"

        case .channels: 
            return "channels"
        case .createChannel(let queryString):
            return "channels/\(queryString)/query"
        case .updateChannel(let queryString):
            return "channels/\(queryString)/query"
        case .deleteChannel(let payloadPath):
            return "channels/\(payloadPath)"
        case .truncatedChannel(channelId: let channelId):
            return "channels/\(channelId.apiPath)/truncate"
        case .channelUpdate(let payloadPath):
            return "channels/\(payloadPath)"
        case .muteChannel(let channelId):
            return "channels/\(channelId.apiPath)/muted"
        case .pinChannel(let channelId):
            return "channels/\(channelId.apiPath)/pin"
        case .unPinChannel(let channelId):
            return "channels/\(channelId.apiPath)/unpin"
        case .showChannel(let (channelId, show)):
            return "channels/\(channelId)/\(show ? "show" : "hide")"
        case .unread:
            return "unread"
        case .markChannelRead(let (channelId, messageId)):
            if let messageId {
                return "channels/\(channelId)/\(messageId)/read"
            } else {
                return "channels/\(channelId)/read"
            }
        case .markChannelUnread(let channelId):
            return "channels/\(channelId)/unread"
        case .markAllChannelsRead:
            return "channels/read"
        case .channelEvent(let channelId):
            return "channels/\(channelId)/event"
        case .stopWatchingChannel(let channelId):
            return "channels/\(channelId)/stop-watching"
        case .pinnedMessages(let channelId):
            return "channels/\(channelId)/pinned_messages"
        case .uploadAttachment(let (channelId, type)):
            return "channels/\(channelId.apiPath)/\(type)"
        case .sendMessage(let channelId):
            return "channels/\(channelId.apiPath)/message"
        case .message(let messageId):
            return "messages/\(messageId)"
        case .editMessage(let (messageId, cid)):
            return "messages/\(cid.apiPath)/\(messageId)"
        case .deleteMessage(let (messageId, cid)):
            return "messages/\(cid.apiPath)/\(messageId)"
        case .pinMessage(let (messageId, cid)):
            return "messages/\(cid.apiPath)/\(messageId)/pin"
        case .unPinMessage(let (messageId, cid)):
            return "messages/\(cid.apiPath)/\(messageId)/unpin"
        case .replies(let messageId):
            return "messages/\(messageId)/replies"
        case .reactions(let messageId):
            return "messages/\(messageId)/reactions"
        case .addReaction(let cid,
                          let messageId,
                          let reactionType):
            return "messages/\(cid.apiPath)/\(messageId)/reaction/\(reactionType.rawValue)"
        case .deleteReaction(let (cid, messageId, reaction)):
            return "messages/\(cid.apiPath)/\(messageId)/reaction/\(reaction.rawValue)"
        case .messageAction(let messageId):
            return "messages/\(messageId)/action"
        case .translateMessage(let messageId):
            return "messages/\(messageId)/translate"

        case .banMember: 
            return "moderation/ban"
        case .muteUser(let mute):
            return "moderation/\(mute ? "mute" : "unmute")"
        case .deleteFile(let channelId):
            return "channels/\(channelId)/file"
        case .deleteImage(let channelId):
            return "channels/\(channelId)/image"
        case .stickerPacks(packName: let packName):
            if let packName {
                return "/packs/\(packName)"
            } else {
                return "/packs/index.json"
            }
        case .sticker(path: let path):
            return path
        case .getOtp:
            return "uss/v1/auth/get_otp_new"
        case .register:
            return "uss/v1/auth/register"
        case .loginWithOTP:
            return "uss/v1/auth/otp_login"
        case .loginWithGoogle:
            return "uss/v1/auth/google_login"
        case .loginWithApple:
            return "uss/v1/auth/apple_login"
        case .subscribe:
            return "uss/v1/sse/subscribe"
        case .refreshToken:
            return "uss/v1/refresh_token"
        case .signWallet:
            return "uss/v1/auth/get_challenge"
        case .walletAuthenticate:
            return "uss/v1/auth/verify_signature"
        case .getChains:
            return "uss/v1/users/chains"
        case .getUserClients:
            return "uss/v1/users/clients"
        case .getUserProjects:
            return "uss/v1/users/projects"
        case .joinProject:
            return "uss/v1/users/join"
        case .signal:
            return "signal"
        case .enableTopics(let channelId):
            return "channels/\(channelId.apiPath)/topics/enable"
        case .disableTopics(let channelId):
            return "channels/\(channelId.apiPath)/topics/disable"
        case .createTopic(let queryString):
            return "channels/\(queryString)/query"
        case .editTopic(let queryString):
            return "channels/\(queryString)/topics"
        case .closeTopic(let channelId):
            return "channels/\(channelId.apiPath)/topics/close"
        case .reopenTopic(let channelId):
            return "channels/\(channelId.apiPath)/topics/reopen"
        }
    }

    var isRefreshToken: Bool {
        switch self {
        case .refreshToken:
            return true
        default:
            return false
        }
    }
}
