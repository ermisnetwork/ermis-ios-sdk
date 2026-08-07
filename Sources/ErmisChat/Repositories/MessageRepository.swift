//
// Copyright 2025 Ermis Inc.
//

import Foundation
import ErmisShared

enum MessageRepositoryError: LocalizedError {
    case messageDoesNotExist
    case messageNotPendingSend
    case messageDoesNotHaveValidChannel
    case failedToEncryptedMessage(Error)
    case failedToSendMessage(Error)
}

class MessageRepository {
    let database: DatabaseContainer
    let apiClient: APIClient
    let e2eRepository: E2eRepository

    init(database: DatabaseContainer, apiClient: APIClient, e2eRepository: E2eRepository) {
        self.database = database
        self.apiClient = apiClient
        self.e2eRepository = e2eRepository
    }

    func sendMessage(
        with messageId: MessageId,
        completion: @escaping (Result<ChatMessage, MessageRepositoryError>) -> Void
    ) {
        // Check the message with the given id is still in the DB.
        database.backgroundReadOnlyContext.perform { [weak self] in
            guard let self else {
                return
            }

            guard let dto = self.database.backgroundReadOnlyContext.message(id: messageId) else {
                log.error("Trying to send a message with id \(messageId) but the message was deleted.")
                completion(.failure(.messageDoesNotExist))
                return
            }

            // Check the message still have `pendingSend` state.
            guard dto.localMessageState == .pendingSend else {
                log.info("Skipping sending message with id \(dto.id) because it doesn't have `pendingSend` local state.")
                completion(.failure(.messageNotPendingSend))
                return
            }

            guard let channelDTO = dto.channel, let cid = try? ChannelId(cid: channelDTO.cid) else {
                log.info("Skipping sending message with id \(dto.id) because it doesn't have a valid channel.")
                completion(.failure(.messageDoesNotHaveValidChannel))
                return
            }

            var requestBody = dto.asRequestBody() as MessageRequestBody

            // Topics inherit their parent channel's MLS group, so `isE2eeEnabled`
            // also returns true for a topic under an E2EE parent.
            let isEncrypted = dto.channel?.isE2eeEnabled == true
            let e2eeTrace = isEncrypted
                ? E2eeSendTrace.Context(messageId: messageId, cid: cid)
                : nil
            e2eeTrace?.info(
                stage: "send_preflight_succeeded",
                reusedIntent: requestBody.hasDurableE2eeNetworkIntent
            )
            // Encrypted message
            if isEncrypted {
                guard !requestBody.requiresE2eeAuthenticatedSendLane else {
                    let error = E2eeMessageAADError.authenticatedSendLaneUnavailable
                    e2eeTrace?.failure(stage: "authenticated_send_lane_unavailable", error: error)
                    completion(.failure(.failedToEncryptedMessage(error)))
                    return
                }
                let e2ePayload = E2ePayload(text: requestBody.text,
                                            attachments: requestBody.attachments,
                                            stickerUrl: requestBody.stickerUrl)
                do {
                    if let durableCiphertext = requestBody.encryptedData,
                       let durableEpoch = requestBody.mlsEpoch {
                        e2eeTrace?.info(
                            stage: "durable_intent_reused",
                            epoch: UInt64(max(0, durableEpoch)),
                            ciphertextBytes: durableCiphertext.count,
                            reusedIntent: true
                        )
                        requestBody.bindE2eeNetworkIntent(
                            ciphertext: durableCiphertext,
                            epoch: durableEpoch
                        )
                    } else {
                        e2eeTrace?.info(stage: "encrypt_requested", reusedIntent: false)
                        let (encryptedData, epoch) = try e2eRepository.encryptedMessage(
                            e2ePayload,
                            in: cid,
                            trace: e2eeTrace
                        )

                        // `encryptedMessage` has already saved the OpenMLS provider state. The
                        // exact retry intent must now be durable before local state becomes
                        // `.sending` and before any network request can start. If the app dies in
                        // the narrow saveState-before-this-write window, no intent exists and the
                        // next launch safely creates a fresh MLS generation.
                        let intentPersistenceStartedAt = E2eeSendTrace.nowNanoseconds()
                        e2eeTrace?.info(
                            stage: "durable_intent_persist_started",
                            epoch: UInt64(max(0, epoch)),
                            ciphertextBytes: encryptedData.count,
                            reusedIntent: false
                        )
                        try database.writeAndWait { session in
                            guard let messageDTO = session.message(id: messageId),
                                  messageDTO.localMessageState == .pendingSend else {
                                throw MessageRepositoryError.messageNotPendingSend
                            }
                            messageDTO.encryptedData = Data(encryptedData)
                            messageDTO.mlsEpoch = Int64(epoch)
                            try session.saveMessageDecrypt(
                                payload: e2ePayload,
                                messageId: messageId,
                                ciphertextHash: nil
                            )
                        }
                        e2eeTrace?.info(
                            stage: "durable_intent_persist_succeeded",
                            epoch: UInt64(max(0, epoch)),
                            ciphertextBytes: encryptedData.count,
                            operationMilliseconds: E2eeSendTrace.elapsedMilliseconds(
                                since: intentPersistenceStartedAt
                            ),
                            reusedIntent: false
                        )
                        requestBody.bindE2eeNetworkIntent(ciphertext: encryptedData, epoch: epoch)
                    }
                } catch (let error) {
                    e2eeTrace?.failure(stage: "encrypt_or_intent_persist_failed", error: error)
                    // The sender queue removes a completed request. Leaving this row in
                    // `.pendingSend` therefore strands the bubble until a new worker is created
                    // on the next app launch, at which point it is sent unexpectedly. Encryption
                    // failed before any HTTP request, so surface an explicit retryable failure.
                    self.markMessageAsFailedToSend(id: messageId, trace: e2eeTrace) {
                        completion(.failure(.failedToEncryptedMessage(error)))
                    }
                    return
                }
            }

            // Change the message state to `.sending` and the proceed with the actual sending
            let sendingStateStartedAt = E2eeSendTrace.nowNanoseconds()
            e2eeTrace?.info(stage: "local_state_sending_started")
            self.database.write({
                let messageDTO = $0.message(id: messageId)
                messageDTO?.localMessageState = .sending
            }, completion: { error in
                if let error = error {
                    if let e2eeTrace {
                        e2eeTrace.failure(
                            stage: "local_state_sending_failed",
                            error: error,
                            operationMilliseconds: E2eeSendTrace.elapsedMilliseconds(
                                since: sendingStateStartedAt
                            )
                        )
                    } else {
                        log.error("Error changing localMessageState message with id \(messageId) to `sending`: \(error)")
                    }
                    self.markMessageAsFailedToSend(id: messageId, trace: e2eeTrace) {
                        completion(.failure(.failedToSendMessage(error)))
                    }
                    return
                }
                e2eeTrace?.info(
                    stage: "local_state_sending_succeeded",
                    operationMilliseconds: E2eeSendTrace.elapsedMilliseconds(
                        since: sendingStateStartedAt
                    )
                )

                let endpoint: Endpoint<MessagePayload.Boxed> = .sendMessage(
                    cid: cid,
                    messagePayload: requestBody
                )
                let requestStartedAt = E2eeSendTrace.nowNanoseconds()
                e2eeTrace?.info(
                    stage: "http_request_started",
                    epoch: requestBody.mlsEpoch.map { UInt64(max(0, $0)) },
                    ciphertextBytes: requestBody.encryptedData?.count,
                    reusedIntent: requestBody.hasDurableE2eeNetworkIntent
                )
                self.apiClient.request(endpoint: endpoint) {
                    switch $0 {
                    case let .success(payload):
                        e2eeTrace?.info(
                            stage: "http_request_succeeded",
                            epoch: payload.message.mlsEpoch.map { UInt64(max(0, $0)) },
                            operationMilliseconds: E2eeSendTrace.elapsedMilliseconds(
                                since: requestStartedAt
                            )
                        )
                        self.saveSuccessfullySentMessage(
                            cid: cid,
                            message: payload.message,
                            trace: e2eeTrace
                        ) { result in
                            switch result {
                            case let .success(message):
                                completion(.success(message))
                            case let .failure(error):
                                completion(.failure(.failedToSendMessage(error)))
                            }
                        }

                    case let .failure(error):
                        e2eeTrace?.failure(
                            stage: "http_request_failed",
                            error: error,
                            operationMilliseconds: E2eeSendTrace.elapsedMilliseconds(
                                since: requestStartedAt
                            )
                        )
                        self.handleSendingMessageError(
                            error,
                            messageId: messageId,
                            trace: e2eeTrace,
                            completion: completion
                        )
                    }
                }
            })
        }
    }

    func saveSuccessfullySentMessage(
        cid: ChannelId,
        message: MessagePayload,
        trace: E2eeSendTrace.Context? = nil,
        completion: @escaping (Result<ChatMessage, Error>) -> Void
    ) {
        let persistenceStartedAt = E2eeSendTrace.nowNanoseconds()
        trace?.info(stage: "response_persist_started")
        database.write({
            let messageDTO = try $0.saveMessage(payload: message, for: cid, syncOwnReactions: false, cache: nil)
            if messageDTO.localMessageState == .sending || messageDTO.localMessageState == .sendingFailed {
                messageDTO.markMessageAsSent()
            }

            let messageModel = try messageDTO.asModel()
            completion(.success(messageModel))
        }, completion: {
            if let error = $0 {
                if let trace {
                    trace.failure(
                        stage: "response_persist_failed",
                        error: error,
                        operationMilliseconds: E2eeSendTrace.elapsedMilliseconds(
                            since: persistenceStartedAt
                        )
                    )
                } else {
                    log.error("Error saving sent message with id \(message.id): \(error)", subsystems: .offlineSupport)
                }
                completion(.failure(error))
            } else {
                trace?.info(
                    stage: "response_persist_succeeded",
                    operationMilliseconds: E2eeSendTrace.elapsedMilliseconds(
                        since: persistenceStartedAt
                    )
                )
            }
        })
        enqueueDecryptIfNeeded(messageId: message.id, payload: message, cid: cid)
    }

    private func handleSendingMessageError(
        _ error: Error,
        messageId: MessageId,
        trace: E2eeSendTrace.Context?,
        completion: @escaping (Result<ChatMessage, MessageRepositoryError>) -> Void
    ) {
        if trace == nil {
            log.error("Sending the message with id \(messageId) failed with error: \(error)")
        }
        // In case no internet connection, we will mark it as sending.
        // Other type of error, we will mark message as failed.
        if (error as NSError).code == -1009 {
            trace?.info(stage: "offline_kept_in_sending_state")
            completion(.failure(.failedToSendMessage(error)))
            return
        }
        markMessageAsFailedToSend(id: messageId, trace: trace) {
            completion(.failure(.failedToSendMessage(error)))
        }
    }

    private func markMessageAsFailedToSend(
        id: MessageId,
        trace: E2eeSendTrace.Context? = nil,
        completion: @escaping () -> Void
    ) {
        let persistenceStartedAt = E2eeSendTrace.nowNanoseconds()
        trace?.info(stage: "local_state_failed_started")
        database.write({
            let dto = $0.message(id: id)
            if dto?.localMessageState == .pendingSend || dto?.localMessageState == .sending {
                dto?.markMessageAsFailed()
            }
        }, completion: {
            if let error = $0 {
                if let trace {
                    trace.failure(
                        stage: "local_state_failed_persist_failed",
                        error: error,
                        operationMilliseconds: E2eeSendTrace.elapsedMilliseconds(
                            since: persistenceStartedAt
                        )
                    )
                } else {
                    log.error(
                        "Error changing localMessageState message with id \(id) to `sendingFailed`: \(error)",
                        subsystems: .offlineSupport
                    )
                }
            } else {
                trace?.info(
                    stage: "local_state_failed_persist_succeeded",
                    operationMilliseconds: E2eeSendTrace.elapsedMilliseconds(
                        since: persistenceStartedAt
                    )
                )
            }
            completion()
        })
    }

    func saveSuccessfullyEditedMessage(for id: MessageId, completion: @escaping () -> Void) {
        updateMessage(withID: id, localState: nil, completion: completion)
    }

    func saveSuccessfullyDeletedMessage(message: MessagePayload, completion: ((Error?) -> Void)? = nil) {
        database.write({ session in
            guard let messageDTO = session.message(id: message.id), let cid = messageDTO.channel?.cid else {
                return
            }
            session.delete(message: messageDTO)
        }, completion: {
            completion?($0)
        })
    }

    /// Fetches the message from the backend and saves it into the database
    /// - Parameters:
    ///   - cid: The channel identifier the message relates to.
    ///   - messageId: The message identifier.
    ///   - store: A boolean indicating if the message should be stored to database or should only be retrieved
    ///   - completion: The completion. Will be called with an error if something goes wrong, otherwise - will be called with `nil`.
    func getMessage(cid: ChannelId, messageId: MessageId, store: Bool, completion: ((Result<ChatMessage, Error>) -> Void)? = nil) {
        let endpoint: Endpoint<MessagePayload.Boxed> = .getMessage(messageId: messageId)
        apiClient.request(endpoint: endpoint) {
            switch $0 {
            case let .success(boxed):
                var message: ChatMessage?
                self.database.write({ session in
                    message = try session.saveMessage(payload: boxed.message, for: cid, syncOwnReactions: true, cache: nil).asModel()
                    if !store {
                        self.database.writableContext.discardCurrentChanges()
                    }
                }, completion: { error in
                    if let error = error {
                        completion?(.failure(error))
                    } else if let message = message {
                        completion?(.success(message))
                    } else {
                        let error = ClientError.MessagePayloadSavingFailure("Missing message or error")
                        completion?(.failure(error))
                    }
                })
                self.enqueueDecryptIfNeeded(messageId: boxed.message.id, payload: boxed.message, cid: cid)
            case let .failure(error):
                completion?(.failure(error))
            }
        }
    }

    func updateMessage(withID id: MessageId, localState: LocalMessageState?, completion: @escaping () -> Void) {
        database.write({
            let dto = $0.message(id: id)
            dto?.localMessageState = localState
        }, completion: { error in
            if let error = error {
                log
                    .error(
                        "Error changing localMessageState for message with id \(id) to `\(String(describing: localState))`: \(error)"
                    )
            }
            completion()
        })
    }

    func undoReactionAddition(
        on messageId: MessageId,
        type: MessageReactionType,
        completion: (() -> Void)? = nil
    ) {
        database.write {
            let reaction = try $0.removeReaction(from: messageId, type: type, on: nil)
            reaction?.localState = .sendingFailed
        } completion: { error in
            if let error = error {
                log.error("Error removing reaction for message with id \(messageId): \(error)")
            }
            completion?()
        }
    }

    func undoReactionDeletion(
        on messageId: MessageId,
        type: MessageReactionType,
        completion: (() -> Void)? = nil
    ) {
        database.write {
            _ = try $0.addReaction(to: messageId, type: type, localState: .deletingFailed)
        } completion: { error in
            if let error = error {
                log.error("Error adding reaction for message with id \(messageId): \(error)")
            }
            completion?()
        }
    }

    // MARK: - Decrypt helper

    /// Enqueues a decrypt operation if the message payload carries encrypted data.
    /// Safe to call unconditionally — it is a no-op for plain-text messages.
    private func enqueueDecryptIfNeeded(messageId: MessageId, payload: MessagePayload, cid: ChannelId) {
        guard let encryptedBytes = payload.encryptedData else { return }
        e2eRepository.decryptMessagePayload(
            messageId: messageId,
            encryptedData: Data(encryptedBytes),
            cid: cid
        )
    }
}
