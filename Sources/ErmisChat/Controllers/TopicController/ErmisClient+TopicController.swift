import Foundation

extension ErmisClient {
    
    func topicController(
        channelParentId: ChannelId,
        createChannelWithId cid: ChannelId,
        name: String? = nil,
        description: String? = nil,
        imageURL: URL? = nil,
        saveMessage: Bool = true,
        isPublic: Bool = false,
        messageOrdering: MessageOrdering = .topToBottom,
        channelListQuery: ChannelListQuery? = nil
    ) throws -> TopicController {
        guard let currentUserId = currentUserId else {
            throw ClientError.CurrentUserDoesNotExist()
        }

        let payload = ChannelEditDetailPayload(
            cid: cid,
            name: name,
            description: description,
            imageURL: imageURL,
            isPublic: false,
            saveMessage: saveMessage,
            members: [],
            invites: [],
            coolDownDuration: nil,
            filterWords: nil
        )

        return .init(
            channelParentId: channelParentId,
            channelQuery: .init(channelPayload: payload,
                                projectId: projectId),
            channelListQuery: channelListQuery,
            client: self,
            isChannelAlreadyCreated: false,
            messageOrdering: messageOrdering
        )
    }
}
