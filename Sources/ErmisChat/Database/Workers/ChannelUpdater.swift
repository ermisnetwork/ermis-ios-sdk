//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// Makes a channel query call to the backend and updates the local storage with the results.
class ChannelUpdater: Worker {
    private let channelRepository: ChannelRepository
    private let callRepository: CallRepository
    private let paginationStateHandler: MessagesPaginationStateHandling

    init(
        channelRepository: ChannelRepository,
        callRepository: CallRepository,
        paginationStateHandler: MessagesPaginationStateHandling,
        database: DatabaseContainer,
        apiClient: APIClient
    ) {
        self.channelRepository = channelRepository
        self.callRepository = callRepository
        self.paginationStateHandler = paginationStateHandler
        super.init(database: database, apiClient: apiClient)
    }

    var paginationState: MessagesPaginationState {
        paginationStateHandler.state
    }

    /// Makes a channel query call to the backend and updates the local storage with the results.
    ///
    /// - Parameters:
    ///   - channelQuery: The channel query used in the request
    ///   - isInRecoveryMode: Determines whether the SDK is in offline recovery mode
    ///   - onChannelCreated: For some type of channels we need to obtain id from backend.
    ///     This callback is called with the obtained `cid` before the channel payload is saved to the DB.
    ///   - completion: Called when the API call is finished. Called with `Error` if the remote update fails.
    ///
    /// **Note**: If query messages pagination parameter is `nil` AKA updater is asked to fetch the first page of messages,
    /// the local channel's message history will be cleared before the channel payload is saved to the local storage.
    ///
    func update(
        channelQuery: ChannelQuery,
        isInRecoveryMode: Bool,
        onChannelCreated: ((ChannelId) -> Void)? = nil,
        completion: ((Result<ChannelPayload, Error>) -> Void)? = nil
    ) {
        if let pagination = channelQuery.pagination {
            paginationStateHandler.begin(pagination: pagination)
        }
        
        let didLoadFirstPage = channelQuery.pagination?.parameter == nil
        let didJumpToMessage: Bool = channelQuery.pagination?.parameter?.isJumpingToMessage == true
        let isChannelCreate = onChannelCreated != nil

        let completion: (Result<ChannelPayload, Error>) -> Void = { [weak database] result in
            do {
                if let pagination = channelQuery.pagination {
                    self.paginationStateHandler.end(pagination: pagination, with: result.map(\.messages))
                }

                let payload = try result.get()

                onChannelCreated?(payload.channel.cid)

                database?.write { session in
                    if let channelDTO = session.channel(cid: payload.channel.cid) {
                        if didJumpToMessage || didLoadFirstPage {
                            channelDTO.cleanAllMessagesExcludingLocalOnly()
                        }
                    }

                    let updatedChannel = try session.saveChannel(payload: payload,
                                                                 query: nil,
                                                                 cache: nil,
                                                                 shouldSavePinnedMessage: true)
                    updatedChannel.oldestMessageAt = self.paginationState.oldestMessageAt?.bridgeDate
                    updatedChannel.newestMessageAt = self.paginationState.newestMessageAt?.bridgeDate

                } completion: { error in
                    if let error = error {
                        completion?(.failure(error))
                        return
                    }
                    completion?(.success(payload))
                }
            } catch {
                completion?(.failure(error))
            }
        }

        let endpoint: Endpoint<ChannelPayload> = {
            if channelQuery.parentCid != nil {
                return .createTopic(isUpdate: isChannelCreate, query: channelQuery)
            } else {
                return isChannelCreate ? .createChannel(query: channelQuery) :
                    .updateChannel(query: channelQuery)
            }
        }()

        if isInRecoveryMode {
            apiClient.recoveryRequest(endpoint: endpoint, completion: completion)
        } else {
            apiClient.request(endpoint: endpoint, completion: completion)
        }
    }

    /// Updates specific channel with new data.
    /// - Parameters:
    ///   - channelPayload: New channel data.
    ///   - completion: Called when the API call is finished. Called with `Error` if the remote update fails.
    func updateChannel(channelPayload: ChannelEditDetailPayload, completion: ((Error?) -> Void)? = nil) {
        apiClient.request(endpoint: .updateChannel(channelPayload: channelPayload)) { [weak self] result in
            switch result {
            case let .success(payload):
                self?.database.write { (session) in
                    try session.saveChannel(payload: payload.channel, query: nil, cache: nil)
                } completion: { _ in
                    completion?(nil)
                }
            case let .failure(error):
                completion?(error)
            }
        }
    }

    /// Deletes the specific channel.
    /// - Parameters:
    ///   - cid: The channel identifier.
    ///   - completion: Called when the API call is finished. Called with `Error` if the remote update fails.
    func deleteChannel(cid: ChannelId, completion: ((Error?) -> Void)? = nil) {
        apiClient.request(endpoint: .deleteChannel(cid: cid)) { [weak self] result in
            switch result {
            case .success:
                self?.database.write {
                    if let channel = $0.channel(cid: cid) {
                        channel.truncatedAt = channel.lastMessageAt ?? channel.createdAt
                        channel.deletedAt = channel.updatedAt
                    }
                } completion: { error in
                    completion?(error)
                }
            case let .failure(error):
                log.error("Delete Channel on request fail \(error)")
                // Note: not removing local channel if not removed on backend
                completion?(result.error)
            }
        }
    }

    /// Deletes all messages of the specific channel.
    /// - Parameters:
    ///   - cid: The channel identifier.
    ///   - completion: Called when the API call is finished. Called with `Error` if the remote update fails.
    func deleteChannelMessages(cid: ChannelId, completion: ((Error?) -> Void)? = nil) {
        apiClient.request(endpoint: .truncatedChannel(cid: cid)) { [weak self] result in
            switch result {
            case .success:
                self?.database.write {
                    if let channel = $0.channel(cid: cid) {
                        channel.truncatedAt = channel.lastMessageAt ?? channel.createdAt
                    }
                } completion: { error in
                    completion?(error)
                }
            case let .failure(error):
                log.error("Truncated channel on request fail \(error)")
                // Note: not removing local channel if not removed on backend
                completion?(result.error)
            }
        }
    }

    /// Creates a new message in the local DB and sets its local state to `.pendingSend`.
    ///
    /// - Parameters:
    ///   - cid: The cid of the channel the message is create in.
    ///   - messageId: The id for the sent message.
    ///   - text: Text of the message.
    ///   - pinning: Pins the new message. Nil if should not be pinned.
    ///   - isSilent: A flag indicating whether the message is a silent message. Silent messages are special messages that don't increase the unread messages count nor mark a channel as unread.
    ///   - attachments: An array of the attachments for the message.
    ///   - stickerUrl: The url of sticker.
    ///   - quotedMessageId: An id of the message new message quotes. (inline reply)
    ///   - completion: Called when saving the message to the local DB finishes.
    ///
    func createNewMessage(
        in cid: ChannelId,
        messageId: MessageId?,
        text: String,
        isSilent: Bool,
        command: String?,
        arguments: String?,
        attachments: [AnyAttachmentPayload] = [],
        stickerUrl: URL? = nil,
        mentionedUserIds: [UserId],
        mentionedAll: Bool,
        quotedMessageId: MessageId?,
        completion: ((Result<ChatMessage, Error>) -> Void)? = nil
    ) {
        var newMessage: ChatMessage?
        database.write({ (session) in
            let newMessageDTO = try session.createNewMessage(
                in: cid,
                messageId: messageId,
                text: text,
                command: command,
                arguments: arguments,
                parentMessageId: nil,
                attachments: attachments,
                stickerUrl: stickerUrl,
                mentionedUserIds: mentionedUserIds,
                mentionedAll: mentionedAll,
                isSilent: isSilent,
                quotedMessageId: quotedMessageId,
                createdAt: nil
            )

            newMessageDTO.localMessageState = .pendingSend
            newMessage = try newMessageDTO.asModel()
        }) { error in
            if let message = newMessage, error == nil {
                completion?(.success(message))
            } else {
                completion?(.failure(error ?? ClientError.Unknown()))
            }
        }
    }

    /// Add users to the channel as members.
    /// - Parameters:
    ///   - currentUserId: the id of the current user.
    ///   - cid: The Id of the channel where you want to add the users.
    ///   - userIds: User ids to add to the channel.
    ///   - completion: Called when the API call is finished. Called with `Error` if the remote update fails.
    func addMembers(
        currentUserId: UserId? = nil,
        cid: ChannelId,
        userIds: Set<UserId>,
        completion: ((Error?) -> Void)? = nil
    ) {
        apiClient.request(
            endpoint: .addMembers(
                cid: cid,
                userIds: userIds
            )
        ) {
            completion?($0.error)
        }
    }

    /// Remove users to the channel as members.
    /// - Parameters:
    ///   - currentUserId: the id of the current user.
    ///   - cid: The Id of the channel where you want to remove the users.
    ///   - userIds: User ids to remove from the channel.
    ///   - completion: Called when the API call is finished. Called with `Error` if the remote update fails.
    func removeMembers(
        currentUserId: UserId? = nil,
        cid: ChannelId,
        userIds: Set<UserId>,
        completion: ((Error?) -> Void)? = nil
    ) {
        apiClient.request(
            endpoint: .removeMembers(
                cid: cid,
                userIds: userIds
            )
        ) {
            completion?($0.error)
        }
    }

    /// Accept invitation to a channel
    /// - Parameters:
    ///   - cid: A channel identifier of a channel a user was invited to.
    ///   - action: A action type: "accept" or "join"
    ///   - completion: Called when the API call is finished. Called with `Error` if the remote update fails.
    func acceptInvite(
        cid: ChannelId,
        completion: ((Error?) -> Void)? = nil
    ) {
        apiClient.request(endpoint: .acceptInvite(cid: cid)) {
            completion?($0.error)
        }
    }

    /// Reject invitation to a channel
    /// - Parameters:
    ///   - cid: A channel identifier of a channel a user was invited to.
    ///   - completion: Called when the API call is finished. Called with `Error` if the remote update fails.
    func rejectInvite(
        cid: ChannelId,
        completion: ((Error?) -> Void)? = nil
    ) {
        apiClient.request(endpoint: .rejectInvite(cid: cid)) {
            completion?($0.error)
        }
    }

    /// Join a public channel
    /// - Parameters:
    ///   - cid: A channel identifier of a channel a user was invited to.
    ///   - action: A action type: "accept" or "join"
    ///   - completion: Called when the API call is finished. Called with `Error` if the remote update fails.
    func joinPublicChannel(
        cid: ChannelId,
        completion: ((Error?) -> Void)? = nil
    ) {
        apiClient.request(endpoint: .joinPublicChannel(cid: cid)) {
            completion?($0.error)
        }
    }

    /// Marks a channel as read
    /// - Parameters:
    ///   - cid: Channel id of the channel to be marked as read
    ///   - completion: Called when the API call is finished. Called with `Error` if the remote update fails.
    func markRead(cid: ChannelId, messageId: String?, userId: UserId, completion: ((Error?) -> Void)? = nil) {
        channelRepository.markRead(cid: cid, messageId: messageId, userId: userId, completion: completion)
    }

    /// Marks a subset of the messages of the channel as unread. All the following messages, including the one that is
    /// passed as parameter, will be marked as not read.
    /// - Parameters:
    ///   - cid: The id of the channel to be marked as unread
    ///   - userId: The id of the current user
    ///   - messageId: The id of the first message id that will be marked as unread.
    ///   - lastReadMessageId: The id of the last message that was read.
    ///   - completion: Called when the API call is finished. Called with `Error` if the remote update fails.
    func markUnread(
        cid: ChannelId,
        userId: UserId,
        from messageId: MessageId,
        lastReadMessageId: MessageId?,
        completion: ((Result<Channel, Error>) -> Void)? = nil
    ) {
        channelRepository.markUnread(
            for: cid,
            userId: userId,
            from: messageId,
            lastReadMessageId: lastReadMessageId,
            completion: completion
        )
    }

    /// Block/unblock current channel.
    /// - Parameters:
    ///   - cid: The id of the channel to be marked as unread
    ///   - isBlocked: The boolean `true` if we want to block this channel, `false` if we want to unblock this channel.
    ///   - completion: Called when the API call is finished. Called with `Error` if the remote update fails.
    func blocked(cid: ChannelId, isBlocked: Bool, completion: ((Result<Channel, Error>) -> Void)? = nil) {
        apiClient.request(endpoint: .blockChannel(cid: cid, isBlocked: isBlocked), completion: { [weak self] result in
            var channel: Channel?
            switch result {
            case .success(let channelPayload):
                self?.database.write ({ session in
                    channel = try session.saveChannel(payload: channelPayload).asModel()
                }, completion: { error in
                    if let channel = channel, error == nil {
                        completion?(.success(channel))
                    } else {
                        completion?(.failure(error ?? ClientError.ChannelNotCreatedYet()))
                    }
                })

            case .failure(let error):
                completion?(.failure(error))
            }
        })
    }

    /// Mutes/unmutes the specific channel.
    /// - Parameters:
    ///   - cid: The channel identifier.
    ///   - muteType: Mute behavior of channel.
    ///   - completion: Called when the API call is finished. Called with `Error` if the remote update fails.
    func mute(cid: ChannelId, muteType: ChannelMuteType, completion: ((Result<EmptyResponse, Error>) -> Void)? = nil) {
        channelRepository.mute(cid: cid, muteType: muteType, completion: completion)
    }

    /// Pin/Unpin the specific channel.
    /// - Parameters:
    ///   - cid: The channel identifier.
    ///   - isPinned: The boolean value, `true` if we want to pin the channel with given `cid`.
    ///   - completion: Called when the API call is finished. Called with `Error` if the remote update fails.
    func pinChannel(cid: ChannelId, isPinned: Bool, completion: ((Result<EmptyResponse, Error>) -> Void)? = nil) {
        channelRepository.setPinned(cid: cid, isPinned: isPinned, completion: completion)
    }
    
    func topinChannel(cid: ChannelId, projectId: String, isPinned: Bool, completion: ((Result<EmptyResponse, Error>) -> Void)? = nil) {
        channelRepository.setTopic(cid: cid, projectId: projectId, isEnable: isPinned, completion: completion)
    }

    ///
    /// When slow mode is enabled, users can only send a message every `cooldownDuration` time interval.
    /// `cooldownDuration` is specified in milliseconds
    ///
    /// - Parameters:
    ///   - cid: Channel id of the channel to be marked as read
    ///   - cooldownDuration: Duration of the time interval users have to wait between messages.
    ///   Specified in milliSeconds.
    ///   - completion: Called when the API call is finished. Called with `Error` if the remote update fails.
    func setCoolDownDuration(cid: ChannelId, cooldownDuration: Int, completion: ((Error?) -> Void)? = nil) {
        let channelquery = ChannelEditDetailPayload(type: .messaging, coolDownDuration: cooldownDuration)
        apiClient.request(endpoint: .coolDownDuration(cid: cid, cooldownDuration: cooldownDuration)) {
            completion?($0.error)
        }
    }

    /// Start watching a channel
    ///
    /// Watching a channel is defined as observing notifications about this channel.
    /// Usually you don't need to call this function since `ChannelController` watches channels
    /// by default.
    ///
    /// - Parameter cid: Channel id of the channel to be watched
    /// - Parameter isInRecoveryMode: Determines whether the SDK is in offline recovery mode
    /// - Parameter completion: Called when the API call is finished. Called with `Error` if the remote update fails.
    func startWatching(cid: ChannelId, isInRecoveryMode: Bool, completion: ((Error?) -> Void)? = nil) {
        var query = ChannelQuery(cid: cid)
        let endpoint = Endpoint<ChannelPayload>.updateChannel(query: query)
        let completion: (Result<ChannelPayload, Error>) -> Void = { completion?($0.error) }
        if isInRecoveryMode {
            apiClient.recoveryRequest(endpoint: endpoint, completion: completion)
        } else {
            apiClient.request(endpoint: endpoint, completion: completion)
        }
    }

    /// Stop watching a channel
    ///
    /// Watching a channel is defined as observing notifications about this channel.
    ///
    /// - Parameter cid: Channel id of the channel to stop watching
    /// - Parameter completion: Called when the API call is finished. Called with `Error` if the remote update fails.
    func stopWatching(cid: ChannelId, completion: ((Error?) -> Void)? = nil) {
        apiClient.request(endpoint: .stopWatching(cid: cid)) {
            completion?($0.error)
        }
    }

    /// Queries the watchers of a channel.
    ///
    /// - Parameters:
    ///   - query: Query object for watchers. See `ChannelWatcherListQuery`
    ///   - completion: Called when the API call is finished. Called with `Error` if the remote update fails.
    func channelWatchers(query: ChannelWatcherListQuery, completion: ((Error?) -> Void)? = nil) {
        apiClient.request(endpoint: .channelWatchers(query: query)) { (result: Result<ChannelPayload, Error>) in
            do {
                let payload = try result.get()
                self.database.write { (session) in
                    if let channel = session.channel(cid: query.cid) {
                        if query.pagination.offset == 0, (payload.watchers?.isEmpty ?? false) {
                            // This is the first page of the watchers, and backend reported empty array
                            // We can clear the existing watchers safely
                            channel.watchers.removeAll()
                        }
                    }
                    // In any case (backend reported another page of watchers or no watchers)
                    // we should save the payload as it's the latest state of the channel
                    try session.saveChannel(payload: payload)
                } completion: { error in
                    completion?(error)
                }
            } catch {
                completion?(error)
            }
        }
    }

    func uploadFile(
        type: AttachmentType,
        localFileURL: URL,
        cid: ChannelId,
        progress: ((Double) -> Void)? = nil,
        completion: @escaping ((Result<UploadedAttachment, Error>) -> Void)
    ) {
        do {
            let attachmentFile = try AttachmentFile(url: localFileURL, fileSize: nil)
            let attachment = AnyMessageAttachment(
                id: .init(cid: cid, messageId: "", index: 0), // messageId and index won't be used for uploading
                type: type,
                payload: .init(),
                thumbnailData: nil, // thumbnail data won't be used for uploading
                uploadingState: .init(
                    localFileURL: localFileURL,
                    state: .pendingUpload, // will not be used
                    file: attachmentFile
                )
            )
            apiClient.uploadAttachment(attachment, progress: progress, completion: completion)
        } catch {
            completion(.failure(ClientError.InvalidAttachmentFileURL(localFileURL)))
        }
    }
    
    func deleteFile(in cid: ChannelId, url: String, completion: ((Error?) -> Void)? = nil) {
        apiClient.request(endpoint: .deleteFile(cid: cid, url: url), completion: {
            completion?($0.error)
        })
    }
    
    func deleteImage(in cid: ChannelId, url: String, completion: ((Error?) -> Void)? = nil) {
        apiClient.request(endpoint: .deleteImage(cid: cid, url: url), completion: {
            completion?($0.error)
        })
    }

    func promoteMember(in cid: ChannelId, members: [String], completion: ((Error?) -> Void)?) {
        apiClient.request(endpoint: .promoteMembers(cid: cid, memberIds: members), completion: {
            completion?($0.error)
        })
    }

    func demoteMember(in cid: ChannelId, members: [String], completion: ((Error?) -> Void)?) {
        apiClient.request(endpoint: .demoteMembers(cid: cid, memberIds: members), completion: {
            completion?($0.error)
        })
    }

    func banMember(in cid: ChannelId, members: [String], completion: ((Error?) -> Void)?) {
        apiClient.request(endpoint: .banMember(members, cid: cid), completion: {
            completion?($0.error)
        })
    }

    func unbanMember(in cid: ChannelId, members: [String], completion: ((Error?) -> Void)?) {
        apiClient.request(endpoint: .unbanMember(members, cid: cid), completion: {
            completion?($0.error)
        })
    }

    func updateChannelCapabilities(in cid: ChannelId,
                                   capabilities: [String],
                                   completion: ((Error?) -> Void)?) {
        apiClient.request(endpoint:
                .updateChannelCapabilities(cid: cid,
                                           capabilities: capabilities),
                          completion: { [weak self] result in
            switch result {
            case let .success(payload):
                self?.database.write { (session) in
                    try session.saveChannel(payload: payload.channel, query: nil, cache: nil)
                } completion: { _ in
                    completion?(nil)
                }
            case let .failure(error):
                completion?(error)
            }
        })
    }

    func search(payload: ChannelSearchRequestPayload, completion: @escaping (Result<ChannelSearchPayload, Error>) -> Void) {
        apiClient.request(endpoint: .channelSearch(body: payload), completion: { result in
            switch result {
            case .success(let searchResultPayload):
                completion(.success(searchResultPayload.searchResult))
            case .failure(let error):
                completion(.failure(error))
            }
        })
    }

    func saveComposerUnsentContent(in cid: ChannelId, content: ComposerContent?) {
        self.database.write { session in
            try session.updateComposerUnsentContent(in: cid, content: content)
        }
    }
    // MARK: - private
    
    private func messagePayload(text: String?, currentUserId: UserId?) -> MessageRequestBody? {
        var messagePayload: MessageRequestBody?
        if let text = text, let currentUserId = currentUserId {
            let userRequestBody = UserRequestBody(
                id: currentUserId,
                name: nil,
                imageURL: nil
            )
            messagePayload = MessageRequestBody(
                id: .newUniqueId,
                user: userRequestBody,
                text: text
            )
            return messagePayload
        }
        return nil
    }
}

// MARK: Topic
extension ChannelUpdater {
    
    /// Adds a new topic to the channel.
    /// - Parameters:
    ///  - query: The channel query used in the request.
    ///  - completion: Called when the API call is finished. Called with `Error` if the remote update fails.
    ///  **Note**: This method is used to create a topic in a parent channel. The parent channel must be specified in the query.
    func addTopic(isUpdate: Bool, _ query: ChannelQuery, completion: ((Error?) -> Void)? = nil) {
        apiClient.request(endpoint: .createTopic(isUpdate: isUpdate, query: query)) {
            completion?($0.error)
        }
    }
    
    func closeTopic(_ cid: ChannelId, data: CloseAndReopenTopic, completion: ((Error?) -> Void)? = nil) {
        apiClient.request(endpoint: .closeTopic(cid: cid, data: data)) {
            completion?($0.error)
        }
    }
    
    func reopenTopic(_ cid: ChannelId, data: CloseAndReopenTopic, completion: ((Error?) -> Void)? = nil) {
        apiClient.request(endpoint: .reopenTopic(cid: cid, data: data)) {
            completion?($0.error)
        }
    }
}
