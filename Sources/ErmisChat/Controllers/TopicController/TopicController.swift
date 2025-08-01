
public class TopicController: ChannelController {
    
    /// The parent channel id for the topic channel.
    public var channelParentId: ChannelId?
    
    /// Creates a new `TopicController` for the topic channel with the provided id.
    /// - Parameters:
    ///   - channelQuery: channel query for observing changes
    ///   - channelListQuery: The channel list query the channel this controller represents is part of.
    ///   - client: The `Client` this controller belongs to.
    ///   - environment: Environment for this controller.
    ///   - isChannelAlreadyCreated: Flag indicating whether channel is created on backend.
    init(
        channelParentId: ChannelId,
        channelQuery: ChannelQuery,
        channelListQuery: ChannelListQuery?,
        client: ErmisClient,
        environment: Environment = .init(),
        isChannelAlreadyCreated: Bool = true,
        messageOrdering: MessageOrdering = .topToBottom
    ) {
        
        super.init(channelQuery: channelQuery,
                   channelListQuery: channelListQuery,
                   client: client,
                   environment: environment,
                   isChannelAlreadyCreated: isChannelAlreadyCreated,
                   messageOrdering: messageOrdering)
        
        self.channelParentId = channelParentId
    }
    
    
}
