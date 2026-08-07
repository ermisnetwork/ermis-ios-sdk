//
// Copyright 2025 Ermis Inc.
//

import CoreData
import Foundation
import ErmisShared

/// The type provides the API for getting/editing/deleting a message
class MessageUpdater: Worker {
    private let repository: MessageRepository
    private let isLocalStorageEnabled: Bool
    private let paginationStateHandler: MessagesPaginationStateHandling

    init(
        isLocalStorageEnabled: Bool,
        messageRepository: MessageRepository,
        paginationStateHandler: MessagesPaginationStateHandling,
        database: DatabaseContainer,
        apiClient: APIClient
    ) {
        self.isLocalStorageEnabled = isLocalStorageEnabled
        repository = messageRepository
        self.paginationStateHandler = paginationStateHandler
        super.init(database: database, apiClient: apiClient)
    }

    var paginationState: MessagesPaginationState {
        paginationStateHandler.state
    }

    /// Fetches the message from the backend and saves it into the database
    /// - Parameters:
    ///   - cid: The channel identifier the message relates to.
    ///   - messageId: The message identifier.
    ///   - completion: The completion. Will be called with an error if something goes wrong, otherwise - will be called with `nil`.
    func getMessage(cid: ChannelId, messageId: MessageId, completion: ((Result<ChatMessage, Error>) -> Void)? = nil) {
        repository.getMessage(cid: cid, messageId: messageId, store: true, completion: completion)
    }

    /// Deletes the message.
    ///
    /// If the message with a provided `messageId` has `pendingSend` or `sendingFailed` state
    /// it will be removed locally as it hasn't been sent yet.
    ///
    /// If the message with the provided `messageId` has some other local state it should be removed on the backend.
    /// Before the `delete` network call happens the local state is set to `deleting` and based on
    /// the response it becomes either `nil` if request succeeds or `deletingFailed` if request fails.
    ///
    /// - Parameters:
    ///   - messageId: The message identifier.
    ///   - onlyForMe: The `Boolean` value, true if delete only for me, otherwhise delete for all users.
    ///   - completion: The completion. Will be called with an error if smth goes wrong, otherwise - will be called with `nil`.
    func deleteMessage(message: ChatMessage, cid: ChannelId, onlyForMe: Bool, completion: ((Error?) -> Void)? = nil) {
        var shouldDeleteOnBackend = true

        database.write({ session in
            guard let storedMessage = session.message(id: message.id) else {
                // Even though the message does not exist locally
                // we don't throw for delete-for-me because the server may still have it.
                // Delete-for-everyone must fail closed because authorship cannot be verified.
                if !onlyForMe {
                    throw ClientError.MessageDoesNotExist(messageId: message.id)
                }
                return
            }

            let messageDTO: MessageDTO
            if onlyForMe {
                messageDTO = storedMessage
            } else {
                messageDTO = try session.messageEditableByCurrentUser(message.id)
            }

            // Hard Deleting is necessary for messages which are only available locally in the DB
            // and authored by this user. A stale/corrupt local state on somebody else's server
            // message must never suppress the delete-for-me backend request.
            let shouldBeHardDeleted = (try? session.currentUserIsAuthor(of: messageDTO)) == true
                && messageDTO.isLocalOnly
            messageDTO.isHardDeleted = shouldBeHardDeleted
            if shouldBeHardDeleted {
                messageDTO.type = MessageType.deleted.rawValue
                messageDTO.deletedAt = DBDate()
                messageDTO.text = ""
                // If a message is local only, it means it is not in the server, so we should
                // not make any call to the server.
                shouldDeleteOnBackend = false

                // Ensures bounced message deletion updates the channel preview.
                if let channelDTO = messageDTO.previewOfChannel, let channelId = try? ChannelId(cid: channelDTO.cid) {
                    channelDTO.previewMessage = session.preview(for: channelId)
                }
            } else {
                messageDTO.localMessageState = .deleting
            }
        }, completion: { [weak database, weak apiClient, weak repository] error in
            guard shouldDeleteOnBackend, error == nil else {
                completion?(error)
                return
            }
            apiClient?.request(endpoint: .deleteMessage(message: message, cid: cid, onlyForMe: onlyForMe)) { result in
                switch result {
                case let .success(response):
                    repository?.saveSuccessfullyDeletedMessage(message: response.message, completion: completion)
                case let .failure(error):
                    database?.write { session in
                        let messageDTO = session.message(id: message.id)
                        messageDTO?.localMessageState = .deletingFailed
                        messageDTO?.isHardDeleted = false
                        completion?(error)
                    }
                }
            }
        })
    }

    /// Edits a new message in the local DB and sets its local state to `.pendingSync`
    /// The message should exist locally and have current user as a sender
    ///  - Parameters:
    ///   - messageId: The message identifier.
    ///   - text: The updated message text.
    ///   - attachments: An array of the attachments for the message.
    ///   - completion: The completion. Will be called with an error if smth goes wrong, otherwise - will be called with `nil`.
    func editMessage(
        messageId: MessageId,
        text: String,
        attachments: [AnyAttachmentPayload] = [],
        mentionedUserIds: [UserId] = [],
        mentionedAll: Bool = false,
        completion: ((Error?) -> Void)? = nil
    ) {
        database.write({ session in
            let messageDTO = try session.messageEditableByCurrentUser(messageId)

            func updateMessage(localState: LocalMessageState) throws {
                messageDTO.text = text

                // `encryptedData`/`mlsEpoch` are the exact durable network intent for the
                // currently queued E2EE generation. A user edit creates a new generation, so
                // the ciphertext of the previously accepted message (or a failed earlier edit)
                // must never be reused for the new plaintext.
                messageDTO.invalidateE2eeNetworkIntentForNewEdit()

                messageDTO.localMessageState = localState

                messageDTO.updatedAt = DBDate()

                messageDTO.quotedBy.forEach { message in
                    message.updatedAt = messageDTO.updatedAt
                }

                guard let cid = try? messageDTO.channel.map({ try ChannelId(cid: $0.cid) }) else { return }
                let messageId = messageDTO.id

                messageDTO.attachments.forEach {
                    session.delete(attachment: $0)
                }

                messageDTO.attachments = Set(
                    try attachments.enumerated().map { index, attachment in
                        let id = AttachmentId(cid: cid, messageId: messageId, index: index)
                        return try session.createNewAttachment(attachment: attachment, id: id)
                    }
                )

                messageDTO.mentionedAll = mentionedAll
                messageDTO.mentionedUserIds = mentionedUserIds

//                messageDTO.mentionedUsers = try Set(mentionedUserIds.compactMap {
//                    let user = try session.user(id: $0, projectId: cid.projectId)
//                    return user
//                })

                // Update the cached decrypted message if one exists (E2E encrypted channel)
                if let decryptDTO = MessageDecryptDTO.load(messageId: messageId, context: session as! NSManagedObjectContext) {
                    decryptDTO.text = text
                    if !attachments.isEmpty {
                        let attachmentPayloads = messageDTO.attachments.compactMap {
                            $0.asRequestPayload()
                        }
                        decryptDTO.attachmentsData = try? JSONEncoder.default.encode(attachmentPayloads)
                    } else {
                        decryptDTO.attachmentsData = nil
                    }
                }
            }

            if messageDTO.isBounced {
                try updateMessage(localState: .pendingSend)
                return
            }

            switch messageDTO.localMessageState {
            case nil, .pendingSync, .syncingFailed, .deletingFailed,
                 .pendingSyncAfterE2eeEpochStale:
                try updateMessage(localState: .pendingSync)
            case .pendingSend, .sendingFailed, .pendingSendAfterE2eeEpochStale:
                try updateMessage(localState: .pendingSend)
            case .sending, .syncing, .deleting,
                 .sendingAfterE2eeEpochStale, .syncingAfterE2eeEpochStale:
                throw ClientError.MessageEditing(
                    messageId: messageId,
                    reason: "message is in `\(messageDTO.localMessageState!)` state"
                )
            }
        }, completion: {
            completion?($0)
        })
    }

    /// Creates a new reply message in the local DB and sets its local state to `.pendingSend`.
    ///
    /// - Parameters:
    ///   - cid: The cid of the channel the message is create in.
    ///   - messageId: The id for the sent message.
    ///   - text: Text of the message.
    ///   - pinning: Pins the new message. Nil if should not be pinned.
    ///   - parentMessageId: The `MessageId` of the message this message replies to.
    ///   - attachments: An array of the attachments for the message.
    ///   in the response thread.
    ///   - stickerUrl: The url of sticker.
    ///   - quotedMessageId: An id of the message new message quotes. (inline reply)
    ///   - completion: Called when saving the message to the local DB finishes.
    ///
    func createNewReply(
        in cid: ChannelId,
        messageId: MessageId?,
        text: String,
        command: String?,
        arguments: String?,
        parentMessageId: MessageId,
        attachments: [AnyAttachmentPayload],
        stickerUrl: URL?,
        mentionedUserIds: [UserId],
        mentionedAll: Bool,
        isSilent: Bool,
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
                parentMessageId: parentMessageId,
                attachments: attachments,
                stickerUrl: stickerUrl,
                mentionedUserIds: mentionedUserIds,
                mentionedAll: mentionedAll,
                isSilent: isSilent,
                quotedMessageId: quotedMessageId,
                createdAt: nil
            )

            newMessageDTO.showInsideThread = true
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

    /// Loads replies for the given message.
    ///
    ///  - Parameters:
    ///   - cid: The `channelId` that messages should be linked to.
    ///   - messageId: The message identifier.
    ///   - pagination: The pagination for replies.
    ///   - completion: The completion. Will be called with an error if smth goes wrong, otherwise - will be called with `nil`.
    func loadReplies(
        cid: ChannelId,
        messageId: MessageId,
        pagination: MessagesPagination,
        completion: ((Result<MessageRepliesPayload, Error>) -> Void)? = nil
    ) {
        paginationStateHandler.begin(pagination: pagination)

        let didLoadFirstPage = pagination.parameter == nil
        let didJumpToMessage = pagination.parameter?.isJumpingToMessage == true
        let endpoint: Endpoint<MessageRepliesPayload> = .loadReplies(messageId: messageId, pagination: pagination)

        apiClient.request(endpoint: endpoint) {
            self.paginationStateHandler.end(pagination: pagination, with: $0.map(\.messages))

            switch $0 {
            case let .success(payload):
                self.database.write({ session in
                    // If it is first page or jumping to a message, clear the current messages.
                    if let parentMessage = session.message(id: messageId) {
                        if didJumpToMessage || didLoadFirstPage {
                            parentMessage.replies.filter { !$0.isLocalOnly }.forEach {
                                $0.showInsideThread = false
                            }
                        }

                        parentMessage.newestReplyAt = self.paginationState.newestMessageAt?.bridgeDate
                    }

                    let replies = session.saveMessages(messagesPayload: payload, for: cid, syncOwnReactions: true)
                    replies.forEach {
                        $0.showInsideThread = true
                    }

                }, completion: { error in
                    if let error = error {
                        completion?(.failure(error))
                    } else {
                        completion?(.success(payload))
                    }
                })
            case let .failure(error):
                completion?(.failure(error))
            }
        }
    }

    func loadReactions(
        cid: ChannelId,
        messageId: MessageId,
        pagination: Pagination,
        completion: ((Result<[MessageReaction], Error>) -> Void)? = nil
    ) {
        let endpoint: Endpoint<MessageReactionsPayload> = .loadReactions(
            messageId: messageId,
            pagination: pagination
        )

        apiClient.request(endpoint: endpoint) { result in
            switch result {
            case let .success(payload):
                var reactions: [MessageReaction] = []
                self.database.write({ session in
                    reactions = try session.saveReactions(payload: payload).map { try $0.asModel() }
                }, completion: { error in
                    if let error = error {
                        completion?(.failure(error))
                    } else {
                        completion?(.success(reactions))
                    }
                })
            case let .failure(error):
                completion?(.failure(error))
            }
        }
    }

    /// Adds a new reaction to the message.
    /// - Parameters:
    ///   - type: The reaction type.
    ///   - messageId: The message identifier the reaction will be added to.
    ///   - completion: Called when the API call is finished. Called with `Error` if the remote update fails.
    func addReaction(
        _ type: MessageReactionType,
        cid: ChannelId,
        messageId: MessageId,
        completion: ((Error?) -> Void)? = nil
    ) {
        let version = UUID().uuidString

        let endpoint: Endpoint<EmptyResponse> = .addReaction(
            type,
            cid: cid,
            messageId: messageId
        )

        database.write { session in
            do {
                let reaction = try session.addReaction(
                    to: messageId,
                    type: type,
                    localState: .sending
                )
                reaction.version = version
            } catch {
                log.warning("Failed to optimistically add the reaction to the database: \(error)")
            }
        } completion: { [weak self, weak repository] error in
            self?.apiClient.request(endpoint: endpoint) { result in
                guard let error = result.error else { return }

                if self?.canKeepReactionState(for: error) == true { return }

                repository?.undoReactionAddition(on: messageId, type: type)
            }
            completion?(error)
        }
    }

    /// Pin/Unpin a message in the channel.
    /// - Parameters:
    ///   - isPinned: If set to `true` message will be pinned and otherwise.
    ///   - messageId: The message identifier of the message will be pinned/unpinned.
    ///   - cid: The channel identifier of the channel.
    ///   - completion: Called when the API call is finished. Called with `Error` if the remote update fails.
    func pinMessage(_ isPinned: Bool, messageId: MessageId, cid: ChannelId, completion: ((Error?) -> Void)? = nil) {
        self.apiClient.request(endpoint: isPinned ? .pinMessage(with: messageId, in: cid) : .unpinMessage(with: messageId, in: cid), completion: { [weak self] result in
            switch result {
            case .success:
                self?.database.write({ session in
                    if let channel = try session.channel(cid: cid),
                       let message = session.message(id: messageId) {
                        if isPinned {
                            channel.pinnedMessages.insert(message)
                        } else {
                            channel.pinnedMessages.remove(message)
                        }
                    }
                }, completion: { error in
                    completion?(nil)
                })
            case .failure(let error):
                completion?(error)
            }
        })
    }

    /// Forward a message to the channel.
    /// - Parameters:
    ///   - messageRequestBody: The `MessageRequestBody` of the forwarded message.
    ///   - cid: The channel identifier of the channel which message will be forwarded to.
    ///   - completion: Called when the API call is finished. Called with `Error` if the remote update fails.
    func forwardMessage(_ messageRequestBody: MessageRequestBody, to cid: ChannelId, completion: ((Error?) -> Void)? = nil) {
        var destinationIsEncrypted: Bool?
        database.viewContext.performAndWait {
            destinationIsEncrypted = ChannelDTO.load(cid: cid, context: database.viewContext)?.isE2eeEnabled
        }
        guard destinationIsEncrypted == false else {
            // The legacy forward endpoint would expose the forwarded payload and does not bind
            // forward metadata into MLS AAD. M4 replaces this with the destination-aware E2EE
            // forward pipeline; until then, fail closed for encrypted or unknown destinations
            // instead of silently downgrading privacy.
            completion?(E2eeMessageAADError.authenticatedSendLaneUnavailable)
            return
        }

        let endpoint: Endpoint<MessagePayload.Boxed> = .sendMessage(
            cid: cid,
            messagePayload: messageRequestBody
        )

        self.apiClient.request(endpoint: endpoint) { [weak self] in
            switch $0 {
            case let .success(payload):
                completion?(nil)
            case let .failure(error):
                completion?(error)
            }
        }
    }

    /// Deletes the message reaction left by the current user.
    /// - Parameters:
    ///   - type: The reaction type.
    ///   - messageId: The message identifier the reaction will be deleted from.
    ///   - completion: Called when the API call is finished. Called with `Error` if the remote update fails.
    func deleteReaction(
        _ type: MessageReactionType,
        cid: ChannelId,
        messageId: MessageId,
        completion: ((Error?) -> Void)? = nil
    ) {
        var reactionScore: Int?
        database.write { session in
            do {
                guard let reaction = try session.removeReaction(from: messageId, type: type, on: nil) else { return }
                reaction.localState = .pendingDelete
                reactionScore = Int(reaction.score)
            } catch {
                log.warning("Failed to remove the reaction from to the database: \(error)")
            }
        } completion: { [weak self, weak repository] error in
            self?.apiClient.request(endpoint: .deleteReaction(type, cid: cid, messageId: messageId)) { result in
                guard let error = result.error else { return }

                if self?.canKeepReactionState(for: error) == true { return }

                repository?.undoReactionDeletion(on: messageId, type: type)
            }
            completion?(error)
        }
    }

    private func canKeepReactionState(for error: Error) -> Bool {
        isLocalStorageEnabled && ClientError.isEphemeral(error: error)
    }

    /// Updates local state of attachment with provided `id` to be enqueued by attachment uploader.
    /// - Parameters:
    ///   - id: The attachment identifier.
    ///   - completion: Called when the attachment database entity is updated. Called with `Error` if update fails.
    func restartFailedAttachmentUploading(
        with id: AttachmentId,
        completion: @escaping (Error?) -> Void
    ) {
        database.write({
            guard let attachmentDTO = $0.attachment(id: id) else {
                throw ClientError.AttachmentDoesNotExist(id: id)
            }

            guard case .uploadingFailed = attachmentDTO.localState else {
                throw ClientError.AttachmentEditing(
                    id: id,
                    reason: "uploading can be restarted for attachments in `.uploadingFailed` state only"
                )
            }

            attachmentDTO.localState = .pendingUpload
        }, completion: completion)
    }

    /// Updates local state of the message with provided `messageId` to be enqueued by message sender background worker.
    /// - Parameters:
    ///   - messageId: The message identifier.
    ///   - completion: Called when the message database entity is updated. Called with `Error` if update fails.
    func resendMessage(
        with messageId: MessageId,
        completion: @escaping (Error?
        ) -> Void
    ) {
        database.write({
            let messageDTO = try $0.messageEditableByCurrentUser(messageId)

            guard messageDTO.localMessageState == .sendingFailed || messageDTO.isBounced else {
                throw ClientError.MessageEditing(
                    messageId: messageId,
                    reason: "only failed or bounced messages can be resent."
                )
            }
            
            let failedAttachments = messageDTO.attachments.filter { $0.localState == .uploadingFailed }
            failedAttachments.forEach {
                $0.localState = .pendingUpload
            }

            messageDTO.localMessageState = .pendingSend
        }, completion: completion)
    }

    func search(query: MessageSearchQuery, policy: UpdatePolicy = .merge, completion: ((Result<MessageSearchResultsPayload, Error>) -> Void)? = nil) {
        apiClient.request(endpoint: .search(query: query)) { result in
            switch result {
            case let .success(payload):
                self.database.write { session in
                    if case .replace = policy {
                        let dto = session.saveQuery(query: query)
                        dto.messages.removeAll()
                    }

                    session.saveMessageSearch(payload: payload, for: query)
                } completion: { error in
                    if let error = error {
                        completion?(.failure(error))
                    } else {
                        completion?(.success(payload))
                    }
                }
            case let .failure(error):
                completion?(.failure(error))
            }
        }
    }

    func clearSearchResults(for query: MessageSearchQuery, completion: ((Error?) -> Void)? = nil) {
        database.write { session in
            let dto = session.saveQuery(query: query)
            dto.messages.removeAll()
        } completion: { error in
            completion?(error)
        }
    }
}

// MARK: - Private

private extension MessageUpdater {
    func fetchAndSaveMessageIfNeeded(_ messageId: MessageId, cid: ChannelId, completion: @escaping (Error?) -> Void) {
        checkMessageExistsLocally(messageId) { exists in
            exists ? completion(nil) : self.getMessage(
                cid: cid,
                messageId: messageId,
                completion: { completion($0.error) }
            )
        }
    }

    func checkMessageExistsLocally(_ messageId: MessageId, completion: @escaping (Bool) -> Void) {
        let context = database.backgroundReadOnlyContext
        context.perform {
            let exists = context.message(id: messageId) != nil
            completion(exists)
        }
    }
}

extension ClientError {
    class MessageDoesNotExist: ClientError {
        init(messageId: MessageId) {
            super.init("There is no `MessageDTO` instance in the DB matching id: \(messageId).")
        }
    }

    class MessageEditing: ClientError {
        init(messageId: String, reason: String) {
            super.init("Message with id: \(messageId) can't be edited (\(reason)")
        }
    }
}

extension DatabaseSession {
    /// Returns whether the message author is the active user in the message's project.
    /// A single database may contain identities for multiple projects, so comparing against an
    /// arbitrary first current-user row is not sufficient.
    func currentUserIsAuthor(of messageDTO: MessageDTO) throws -> Bool {
        guard let projectId = messageDTO.channel?.projectId,
              let currentProjectUser = currentUser?.user(of: projectId) else {
            throw ClientError.CurrentUserDoesNotExist()
        }
        return currentProjectUser.id == messageDTO.user.id
    }

    /// This helper return the message if it can be edited by the current user.
    /// The message entity will be returned if it exists and authored by the current user.
    /// If any of the requirements is not met the error will be thrown.
    ///
    /// - Parameter messageId: The message identifier.
    /// - Throws: Either `CurrentUserDoesNotExist`/`MessageDoesNotExist`/
    /// - Returns: The message entity.
    func messageEditableByCurrentUser(_ messageId: MessageId) throws -> MessageDTO {
        guard let messageDTO = message(id: messageId) else {
            throw ClientError.MessageDoesNotExist(messageId: messageId)
        }

        guard try currentUserIsAuthor(of: messageDTO) else {
            throw ClientError.MessageEditing(
                messageId: messageId,
                reason: "message is not authored by the current user"
            )
        }

        return messageDTO
    }
}
