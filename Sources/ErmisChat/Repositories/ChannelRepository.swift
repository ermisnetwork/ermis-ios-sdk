//
// Copyright 2025 Ermis Inc.
//

class ChannelRepository {
    let database: DatabaseContainer
    let apiClient: APIClient

    init(database: DatabaseContainer, apiClient: APIClient) {
        self.database = database
        self.apiClient = apiClient
    }

    /// Marks a channel as read
    /// - Parameters:
    ///   - cid: Channel id of the channel to be marked as read
    ///   - messageId: Message id need to mark as read
    ///   - completion: Called when the API call is finished. Called with `Error` if the remote update fails.
    func markRead(
        cid: ChannelId,
        messageId: String?,
        userId: UserId,
        completion: ((Error?) -> Void)? = nil
    ) {
        apiClient.request(endpoint: .markRead(cid: cid, messageId: messageId)) { [weak self] result in
            if let error = result.error {
                completion?(error)
                return
            }

            self?.database.write({ session in
                session.markChannelAsRead(cid: cid, userId: userId, at: .init())
            }, completion: { error in
                completion?(error)
            })
        }
    }

    /// Marks a subset of the messages of the channel as unread. All the following messages, including the one that is
    /// passed as parameter, will be marked as not read.
    /// - Parameters:
    ///   - cid: The id of the channel to be marked as unread
    ///   - userId: The id of the current user
    ///   - messageId: The id of the first message that will be marked as unread.
    ///   - lastReadMessageId: The id of the last message that was read.
    ///   - completion: Called when the API call is finished. Called with `Error` if the remote update fails.
    func markUnread(
        for cid: ChannelId,
        userId: UserId,
        from messageId: MessageId,
        lastReadMessageId: MessageId?,
        completion: ((Result<Channel, Error>) -> Void)? = nil
    ) {
        apiClient.request(
            endpoint: .markUnread(cid: cid, messageId: messageId, userId: userId)
        ) { [weak self] result in
            if let error = result.error {
                completion?(.failure(error))
                return
            }

            var channel: Channel?
            self?.database.write({ session in
                session.markChannelAsUnread(
                    for: cid,
                    userId: userId,
                    from: messageId,
                    lastReadMessageId: lastReadMessageId,
                    lastReadAt: nil,
                    unreadMessagesCount: nil
                )
                channel = try session.channel(cid: cid)?.asModel()
            }, completion: { error in
                if let channel = channel, error == nil {
                    completion?(.success(channel))
                } else {
                    completion?(.failure(error ?? ClientError.ChannelNotCreatedYet()))
                }
            })
        }
    }

    /// Mutes/unmutes the specific channel.
    /// - Parameters:
    ///   - cid: The channel identifier.
    ///   - muteType: Mute behavior of channel.
    ///   - completion: Called when the API call is finished. Called with `Error` if the remote update fails.
    func mute(cid: ChannelId, muteType: ChannelMuteType, completion: ((Result<EmptyResponse, Error>) -> Void)? = nil) {
        apiClient.request(
            endpoint: .muteChannel(cid: cid, muteType: muteType)
        ) { [weak self] result in
            if let error = result.error {
                completion?(.failure(error))
                return
            }
            completion?(result)
        }
    }

    /// Pin/UnPin the specific channel.
    /// - Parameters:
    ///   - cid: The channel identifier.
    ///   - isPinned: The boolean value, `true` if we want to pin the channel with given `cid`.
    ///   - completion: Called when the API call is finished. Called with `Error` if the remote update fails.
    func setPinned(cid: ChannelId, isPinned: Bool, completion: ((Result<EmptyResponse, Error>) -> Void)? = nil) {
        apiClient.request(endpoint: .pinnedChannel(cid: cid, isPinned: isPinned)) { [weak self] result in
            if let error = result.error {
                completion?(.failure(error))
                return
            }
            completion?(result)
        }
    }
    
    /// Enable/Disable topic for the specific channel.
    /// - Parameters:
    ///  - cid: The channel identifier.
    ///  - isEnable: The boolean value, `true` if we want to enable topic for the channel with given `cid`.
    ///  - completion: Called when the API call is finished. Called with `Error` if the remote update fails.
    func setTopic(cid: ChannelId, projectId: String, isEnable: Bool, completion: ((Result<EmptyResponse, Error>) -> Void)? = nil) {
        apiClient.request(endpoint: .enableTopic(cid: cid,
                                                 projectId: projectId,
                                                 isEnable: isEnable)) { [weak self] result in
            if let error = result.error {
                completion?(.failure(error))
                return
            }
            completion?(result)
        }
    }

    /// Enable encryption for the specific channel.
    /// - Parameters:
    ///  - cid: The channel identifier.
    ///  - completion: Called when the API call is finished. Called with `Error` if the remote update fails.
    func enableEncryption(cid: ChannelId, body: EnableEncryptionRequestBody, completion: ((Result<EmptyResponse, Error>) -> Void)? = nil) {
        apiClient.request(endpoint: .enableEncryption(cid: cid, body: body)) { [weak self] result in
            if let error = result.error {
                completion?(.failure(error))
                return
            }
            completion?(result)
        }
    }

    /// Upload GroupInfo for a channel after a successful MLS commit.
    ///
    /// Must be called by any member after every successful commit (enableE2ee, addMembers,
    /// removeMember, keyRotation, externalJoin). The server upserts — only the latest GroupInfo
    /// is stored per channel.
    ///
    /// - Parameters:
    ///   - cid: The channel identifier.
    ///   - body: The GroupInfo bytes and the new epoch.
    ///   - completion: Called when the API call is finished. Called with `Error` if the remote update fails.
    func uploadGroupInfo(cid: ChannelId, body: UploadGroupInfoRequestBody, completion: ((Result<ChannelPayload, Error>) -> Void)? = nil) {
        apiClient.request(endpoint: .uploadGroupInfo(cid: cid, body: body)) { [weak self] result in
            if let error = result.error {
                completion?(.failure(error))
                return
            }
            completion?(result)
        }
    }

    /// Fetch the current GroupInfo for a channel.
    ///
    /// Returns a `GroupInfoPayload` which includes the full channel state plus `groupInfo` bytes,
    /// `epoch`, and `isStale`. When `isStale` is `true` the stored GroupInfo is behind the current
    /// MLS epoch and an existing member must upload a fresh one.
    ///
    /// - Parameters:
    ///   - cid: The channel identifier.
    ///   - completion: Called when the API call is finished. Called with `Error` if the remote update fails.
    func getGroupInfo(cid: ChannelId, completion: ((Result<GroupInfoPayload, Error>) -> Void)? = nil) {
        apiClient.request(endpoint: .getGroupInfo(cid: cid)) { [weak self] result in
            if let error = result.error {
                completion?(.failure(error))
                return
            }
            completion?(result)
        }
    }

    /// Join an MLS group via an External Commit (no Welcome needed).
    ///
    /// - Multi-device (sender is already a member): only broadcasts the external commit.
    /// - Public channel (sender is not a member): inserts the member, sends a SystemMessage,
    ///   fires a MemberJoined event, and broadcasts the external commit.
    ///
    /// - Parameters:
    ///   - cid: The channel identifier.
    ///   - body: The external commit bytes, new epoch, optional projectId and members list.
    ///   - completion: Called when the API call is finished. Called with `Error` if the remote update fails.
    func externalJoin(cid: ChannelId, body: ExternalJoinRequestBody, completion: ((Result<ChannelPayload, Error>) -> Void)? = nil) {
        apiClient.request(endpoint: .externalJoin(cid: cid, body: body)) { [weak self] result in
            if let error = result.error {
                completion?(.failure(error))
                return
            }
            completion?(result)
        }
    }
}
