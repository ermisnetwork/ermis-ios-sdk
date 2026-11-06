//
// Copyright 2025 Ermis Inc.
//

import Foundation
import CryptoKit
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
    private let reconcileLock = NSLock()
    private var reconciliationWakeInFlight = false
    private var reconciliationWakePending = false
    // Canonical acceptance may synchronously enter the MLS executor, whose inbox
    // reads also need Core Data's writer. Never invoke it while holding that writer.
    private let sendPersistenceCompletionQueue = DispatchQueue(
        label: "network.ermis.MessageRepository.send-persistence-completion",
        qos: .userInitiated
    )

    init(database: DatabaseContainer, apiClient: APIClient, e2eRepository: E2eRepository) {
        self.database = database
        self.apiClient = apiClient
        self.e2eRepository = e2eRepository
        e2eRepository.resumeOutgoingReconciliation = { [weak self] in self?.resumeDispatchedIntents() }
    }

    func sendMessage(
        with messageId: MessageId,
        completion: @escaping (Result<ChatMessage, MessageRepositoryError>) -> Void
    ) {
        sendMessage(with: messageId, epochRecoveryCompleted: false, completion: completion)
    }

    private func sendMessage(
        with messageId: MessageId,
        epochRecoveryCompleted: Bool,
        completion: @escaping (Result<ChatMessage, MessageRepositoryError>) -> Void
    ) {
        // Check the message with the given id is still in the DB.
        database.backgroundReadOnlyContext.perform { [weak self] in
            guard let self else {
                return
            }

            guard let dto = self.database.backgroundReadOnlyContext.message(id: messageId) else {
                log.error("[MESSAGE_SEND] state=blocked reason=message_missing")
                completion(.failure(.messageDoesNotExist))
                return
            }

            // Check the message still have `pendingSend` state.
            let localState = dto.localMessageState
            let isEpochStaleRetry = localState == .pendingSendAfterE2eeEpochStale
            guard !dto.isHardDeleted, localState == .pendingSend || isEpochStaleRetry else {
                log.info("[MESSAGE_SEND] state=skipped reason=not_pending")
                completion(.failure(.messageNotPendingSend))
                return
            }

            guard let channelDTO = dto.channel, let cid = try? ChannelId(cid: channelDTO.cid) else {
                log.info("[MESSAGE_SEND] state=skipped reason=channel_missing")
                completion(.failure(.messageDoesNotHaveValidChannel))
                return
            }

            var requestBody = dto.asRequestBody() as MessageRequestBody
            var outgoingIntent: MlsSendIntent? = nil
            var outgoingSessionFence: (() throws -> Void)? = nil

            // Topics inherit their parent channel's MLS group, so `isE2eeEnabled`
            // also returns true for a topic under an E2EE parent.
            let checkpoint: MlsSendIntent?
            do { checkpoint = try self.e2eRepository.outgoingSendIntent(uuid: messageId) }
            catch {
                completion(.failure(.failedToEncryptedMessage(error)))
                return
            }
            let isEncrypted = dto.channel?.isE2eeEnabled == true || dto.encryptedData != nil || checkpoint != nil
            let e2eeTrace = isEncrypted
                ? E2eeSendTrace.Context(messageId: messageId, cid: cid)
                : nil

            if isEpochStaleRetry && !epochRecoveryCompleted {
                let minimumEpoch = dto.mlsEpoch
                e2eeTrace?.info(
                    stage: "epoch_stale_scope_sync_started",
                    epoch: UInt64(max(0, minimumEpoch))
                )
                self.e2eRepository.recoverMessageEpoch(
                    in: cid,
                    minimumEpoch: minimumEpoch
                ) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .success(let localEpoch):
                        e2eeTrace?.info(
                            stage: "epoch_stale_scope_sync_succeeded",
                            epoch: localEpoch
                        )
                        self.sendMessage(
                            with: messageId,
                            epochRecoveryCompleted: true,
                            completion: completion
                        )
                    case .failure(let error):
                        e2eeTrace?.failure(stage: "epoch_stale_scope_sync_failed", error: error)
                        self.markMessageAsFailedToSend(id: messageId, trace: e2eeTrace) {
                            completion(.failure(.failedToEncryptedMessage(error)))
                        }
                    }
                }
                return
            }
            e2eeTrace?.info(
                stage: "send_preflight_succeeded",
                reusedIntent: requestBody.hasDurableE2eeNetworkIntent
            )
            // Encrypted message
            if isEncrypted {
                let e2ePayload: E2ePayload
                let authenticatedAAD: E2eeMessageAADV1?
                do {
                    if let original = checkpoint {
                        e2ePayload = try JSONDecoder().decode(E2ePayload.self, from: original.payload)
                        authenticatedAAD = original.aad.isEmpty ? nil : try E2eeMessageAADV1.decoded(from: original.aad)
                    } else {
                    let cachedPayload = try dto.decryptedMessage?.asPayload()
                    try Self.validateE2eeAttachmentSendBinding(message: dto, cachedPayload: cachedPayload)
                    if let cachedPayload, !cachedPayload.e2eeAttachments.isEmpty {
                        try Self.bindCompletedE2eeAttachmentEnvelope(
                            request: &requestBody, manifests: cachedPayload.e2eeAttachments,
                            destinationCid: cid, groupCid: self.e2eRepository.mlsGroupCid(for: cid).rawValue
                        )
                        e2ePayload = cachedPayload
                    } else {
                        let cachedMetadata = (try dto.decryptedMessage?.asPayload())?
                            .authenticatedMetadata
                        e2ePayload = E2ePayload(
                            text: requestBody.text,
                            attachments: requestBody.attachments,
                            stickerUrl: requestBody.stickerUrl,
                            authenticatedMetadata: cachedMetadata
                        )
                        if requestBody.forwardCid?.isEmpty == false
                            || requestBody.forwardMessageId?.isEmpty == false
                            || requestBody.forwardParentCid?.isEmpty == false {
                            try requestBody.bindE2eeAuthenticatedEnvelope(
                                destinationCid: cid,
                                groupId: self.e2eRepository.mlsGroupCid(for: cid).rawValue,
                                attachmentIds: [],
                                forwardParentCid: requestBody.forwardParentCid
                            )
                        }
                    }
                    authenticatedAAD = try requestBody.authenticatedAAD()
                    if requestBody.requiresE2eeAuthenticatedSendLane && authenticatedAAD == nil {
                        throw E2eeMessageAADError.authenticatedSendLaneUnavailable
                    }
                    }
                } catch {
                    e2eeTrace?.failure(stage: "authenticated_send_lane_unavailable", error: error)
                    // This is a deterministic local preflight failure. The sender worker removes
                    // the completed request, so leaving the row in `.pendingSend` strands the
                    // optimistic bubble at 100% until a later relaunch unexpectedly retries it.
                    self.markMessageAsFailedToSend(id: messageId, trace: e2eeTrace) {
                        completion(.failure(.failedToEncryptedMessage(error)))
                    }
                    return
                }
                do {
                    let intent = try self.e2eRepository.prepareOutgoingSend(requestBody, payload: e2ePayload, cid: cid)
                    guard let cipher = intent.ciphertext, let epoch = intent.epoch,
                          epoch <= UInt64(Int.max), intent.generation <= UInt64(Int.max) else { throw MlsSendIntentError.invalid }
                    let boundPayload = try E2eeArchiveMessageValidator.validate(
                        JSONDecoder().decode(E2ePayload.self, from: intent.payload),
                        processedAAD: intent.aad, messageId: messageId, cid: cid.rawValue,
                        groupCid: e2eRepository.mlsGroupCid(for: cid).rawValue)
                    try database.writeAndWait { session in
                        guard let messageDTO = session.message(id: messageId), !messageDTO.isHardDeleted, messageDTO.localMessageState == localState else {
                            throw MessageRepositoryError.messageNotPendingSend
                        }
                        messageDTO.encryptedData = cipher
                        messageDTO.mlsEpoch = Int64(epoch)
                        messageDTO.mlsGroupGeneration = Int64(intent.generation)
                        try session.saveMessageDecrypt(payload: boundPayload, messageId: messageId,
                            ciphertextHash: Data(SHA256.hash(data: cipher)))
                    }
                    requestBody.bindE2eeNetworkIntent(ciphertext: Array(cipher), epoch: Int(epoch), groupGeneration: Int(intent.generation))
                    outgoingIntent = intent
                } catch (let error) {
                    e2eeTrace?.failure(stage: "encrypt_or_intent_persist_failed", error: error)
                    self.retireOutgoingIntentAfterLocalCancellation(messageId: messageId, cid: cid)
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
                guard let messageDTO = $0.message(id: messageId), !messageDTO.isHardDeleted,
                      messageDTO.localMessageState == localState else {
                    throw MessageRepositoryError.messageNotPendingSend
                }
                messageDTO.localMessageState = isEpochStaleRetry
                    ? .sendingAfterE2eeEpochStale
                    : .sending
            }, completion: { error in
                if let error = error {
                    if isEncrypted { self.retireOutgoingIntentAfterLocalCancellation(messageId: messageId, cid: cid) }
                    if let e2eeTrace {
                        e2eeTrace.failure(
                            stage: "local_state_sending_failed",
                            error: error,
                            operationMilliseconds: E2eeSendTrace.elapsedMilliseconds(
                                since: sendingStateStartedAt
                            )
                        )
                    } else {
                        log.error("[MESSAGE_SEND] state=sending_state_persist_failed \(PrivacySafeLogMetadata.errorFields(error))")
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

                var endpoint: Endpoint<MessagePayload.Boxed>
                do {
                    if let prepared = outgoingIntent {
                        let reconcile = prepared.requiresReconcile
                        let dispatched = try self.e2eRepository.markOutgoingDispatch(prepared)
                        outgoingIntent = dispatched
                        guard let envelope = dispatched.wireEnvelope else { throw MlsSendIntentError.invalid }
                        endpoint = Endpoint(path: .mlsControl("v1/e2ee/channels/" + cid.apiPath + "/message" + (reconcile ? "/reconcile" : "")),
                            method: .post, body: envelope, needDeviceId: true)
                        let sessionFence = try self.e2eRepository.outgoingSessionFence(dispatched)
                        outgoingSessionFence = sessionFence
                        // One existing request owner covers auth/encoding/network completion. On
                        // expiration the durable dispatched intent remains unknown/reconcile-only.
                        endpoint.localMlsDeadline = Date().addingTimeInterval(15)
                        endpoint.localMlsTimeoutReason = "mls_send_outcome_unknown"
                        endpoint.localMlsGuard = { [weak self] in
                            try sessionFence()
                            guard let self else { throw MlsSendIntentError.conflict }
                            try self.e2eRepository.assertOutgoingOwner(dispatched)
                        }
                    } else {
                        endpoint = .sendMessage(cid: cid, messagePayload: requestBody)
                    }
                } catch {
                    self.markMessageAsFailedToSend(id: messageId, trace: e2eeTrace) {
                        completion(.failure(.failedToSendMessage(error)))
                    }
                    return
                }
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
                        if let intent = outgoingIntent {
                            do {
                                try outgoingSessionFence?()
                                try self.e2eRepository.validateOutgoingAcceptance(intent, message: payload.message, destination: cid)
                            } catch {
                                completion(.failure(.failedToSendMessage(error)))
                                return
                            }
                        }
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
                            trace: e2eeTrace,
                            assertCurrent: outgoingSessionFence
                        ) { result in
                            switch result {
                            case let .success(message):
                                do {
                                    if let intent = outgoingIntent { try self.e2eRepository.acceptOutgoingSend(intent) }
                                    completion(.success(message))
                                } catch { completion(.failure(.failedToSendMessage(error))) }
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
                        if isEncrypted, outgoingIntent == nil,
                           !isEpochStaleRetry,
                           let rejection = E2eeMessageEpochStaleRejection.parse(error),
                           let intentEpoch = requestBody.mlsEpoch,
                           rejection.canRebind(intentEpoch: Int64(intentEpoch)) {
                            e2eeTrace?.info(
                                stage: "epoch_stale_rebind_accepted",
                                epoch: UInt64(rejection.currentGroupEpoch),
                                reusedIntent: false
                            )
                            self.prepareEpochStaleRebind(
                                rejection,
                                messageId: messageId,
                                isEdit: false,
                                trace: e2eeTrace
                            ) { result in
                                switch result {
                                case .success:
                                    self.sendMessage(
                                        with: messageId,
                                        epochRecoveryCompleted: false,
                                        completion: completion
                                    )
                                case .failure(let persistenceError):
                                    self.markMessageAsFailedToSend(id: messageId, trace: e2eeTrace) {
                                        completion(.failure(.failedToSendMessage(persistenceError)))
                                    }
                                }
                            }
                        } else {
                            self.handleSendingMessageError(
                                error,
                                messageId: messageId,
                                trace: e2eeTrace,
                                completion: { [weak self] result in
                                    // HTTP failure cannot revoke acceptance. End the caller's
                                    // loading state, then wake the existing read-only owner;
                                    // do not wait for a later unrelated sync or UI Retry.
                                    completion(result)
                                    if outgoingIntent?.requiresReconcile == true {
                                        self?.resumeDispatchedIntents()
                                    }
                                }
                            )
                        }
                    }
                }
            })
        }
    }

    /// One indexed page (at most four) on an existing sync wake. Requests use APIClient's
    /// existing serial operation queue. No new worker, timer, full-account scan or retry loop.
    private func resumeDispatchedIntents() {
        reconcileLock.lock()
        guard !reconciliationWakeInFlight else {
            reconciliationWakePending = true
            reconcileLock.unlock()
            return
        }
        reconciliationWakeInFlight = true
        reconcileLock.unlock()
        do { reconcileNext(ArraySlice(try e2eRepository.pendingOutgoingReconciliations())) }
        catch { finishReconciliationWake() }
    }
    private func finishReconciliationWake() {
        reconcileLock.lock()
        reconciliationWakeInFlight = false
        let followUp = reconciliationWakePending
        reconciliationWakePending = false
        reconcileLock.unlock()
        // Only an actual incoming wake schedules this bounded follow-up. An unknown
        // reconciliation result never schedules itself or creates a polling loop.
        if followUp { resumeDispatchedIntents() }
    }
    private func reconcileNext(_ records: ArraySlice<MlsSendIntent>) {
        guard let record = records.first else { finishReconciliationWake(); return }
        let rest = records.dropFirst()
        do {
            guard record.requiresReconcile, let wire = record.wireEnvelope,
                  let root = try JSONSerialization.jsonObject(with: record.originalEnvelope) as? [String: Any],
                  let message = root["message"] as? [String: Any], let raw = message["cid"] as? String else { throw MlsSendIntentError.invalid }
            let cid = try ChannelId(cid: raw), sessionFence = try e2eRepository.outgoingSessionFence(record)
            var endpoint = Endpoint<MessagePayload.Boxed>(path: .mlsControl("v1/e2ee/channels/" + cid.apiPath + "/message/reconcile"), method: .post, body: wire, needDeviceId: true)
            endpoint.localMlsGuard = { [weak self] in
                try sessionFence()
                guard let self else { throw MlsSendIntentError.conflict }
                try self.e2eRepository.assertOutgoingOwner(record)
            }
            endpoint.localMlsDeadline = Date().addingTimeInterval(15)
            endpoint.localMlsTimeoutReason = "mls_send_outcome_unknown"
            apiClient.request(endpoint: endpoint) { [weak self] result in
                guard let self else { return }
                do {
                    try sessionFence()
                    let payload = try result.get()
                    try self.e2eRepository.validateOutgoingAcceptance(record, message: payload.message, destination: cid)
                    self.saveSuccessfullySentMessage(cid: cid, message: payload.message, assertCurrent: sessionFence) { saved in
                        if case .success = saved { try? self.e2eRepository.acceptOutgoingSend(record) }
                        self.reconcileNext(rest)
                    }
                } catch { self.reconcileNext(rest) }
            }
        } catch { reconcileNext(rest) }
    }

    /// A cancel can observe no intent before prepare creates it. If the local row wins
    /// that race, settle any late native/client artifact before completing the failed send.
    /// No Core Data transaction is held while the MLS executor commits cancellation.
    private func retireOutgoingIntentAfterLocalCancellation(messageId: MessageId, cid: ChannelId) {
        do {
            var locallyCanceled = false
            try database.writeAndWait { session in
                guard let dto = session.message(id: messageId), dto.channel?.cid == cid.rawValue,
                      dto.isHardDeleted, try session.currentUserIsAuthor(of: dto) else { return }
                locallyCanceled = true
            }
            if locallyCanceled { _ = try e2eRepository.cancelOutgoingSend(uuid: messageId, destination: cid) }
        } catch {
            // Terminal client records retain their retirement obligation for the next existing
            // sync wake when protected storage is temporarily unavailable. Never reseal/retry.
            log.warning("mls_send_cancel result=retained_for_next_wake", subsystems: .mls)
        }
    }

    func preparePendingSendCancellation(messageId: MessageId, cid: ChannelId,
                                        completion: @escaping (Result<MlsSendIntent?, Error>) -> Void) {
        database.backgroundReadOnlyContext.perform { [weak self] in
            guard let self else { return }
            do {
                guard let record = try self.e2eRepository.outgoingSendIntent(uuid: messageId), record.phase != .accepted else {
                    completion(.success(nil)); return
                }
                guard let dto = self.database.backgroundReadOnlyContext.message(id: messageId),
                      dto.channel?.cid == cid.rawValue,
                      try self.database.backgroundReadOnlyContext.currentUserIsAuthor(of: dto) else { throw MlsSendIntentError.conflict }
                // No Core Data write transaction is held while native/client journal commits.
                completion(.success(try self.e2eRepository.cancelOutgoingSend(uuid: messageId, destination: cid)))
            } catch { completion(.failure(error)) }
        }
    }

    func retryOutgoingIntent(messageId: MessageId) throws {
        try e2eRepository.retryOutgoingSend(uuid: messageId)
    }

    func saveSuccessfullySentMessage(
        cid: ChannelId,
        message: MessagePayload,
        trace: E2eeSendTrace.Context? = nil,
        assertCurrent: (() throws -> Void)? = nil,
        completion: @escaping (Result<ChatMessage, Error>) -> Void
    ) {
        let persistenceStartedAt = E2eeSendTrace.nowNanoseconds()
        trace?.info(stage: "response_persist_started")
        var persistedMessage: ChatMessage?
        database.write({
            try assertCurrent?()
            if assertCurrent != nil, let pending = $0.message(id: message.id),
               pending.localMessageState == .pendingSend || pending.localMessageState == .pendingSendAfterE2eeEpochStale {
                // Only validated canonical send/reconcile responses may settle a rescued
                // pending intent. Ordinary cache/realtime saveMessage keeps its unsent guard.
                pending.localMessageState = .sending
            }
            let messageDTO = try $0.saveMessage(payload: message, for: cid, syncOwnReactions: false, cache: nil)
            if messageDTO.localMessageState == .sending ||
                messageDTO.localMessageState == .sendingAfterE2eeEpochStale ||
                messageDTO.localMessageState == .sendingFailed {
                messageDTO.markMessageAsSent()
            }

            persistedMessage = try messageDTO.asModel()
        }, completion: { error in
            self.sendPersistenceCompletionQueue.async {
                if let error {
                    if let trace {
                        trace.failure(
                            stage: "response_persist_failed",
                            error: error,
                            operationMilliseconds: E2eeSendTrace.elapsedMilliseconds(
                                since: persistenceStartedAt
                            )
                        )
                    } else {
                        log.error(
                            "[MESSAGE_SEND] state=response_persist_failed \(PrivacySafeLogMetadata.errorFields(error))",
                            subsystems: .offlineSupport
                        )
                    }
                    completion(.failure(error))
                } else {
                    trace?.info(
                        stage: "response_persist_succeeded",
                        operationMilliseconds: E2eeSendTrace.elapsedMilliseconds(
                            since: persistenceStartedAt
                        )
                    )
                    guard let persistedMessage else {
                        completion(.failure(MessageRepositoryError.messageDoesNotExist))
                        return
                    }
                    completion(.success(persistedMessage))
                }
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
            log.error("[MESSAGE_SEND] state=request_failed \(PrivacySafeLogMetadata.errorFields(error))")
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
            if dto?.localMessageState == .pendingSend ||
                dto?.localMessageState == .sending ||
                dto?.localMessageState == .pendingSendAfterE2eeEpochStale ||
                dto?.localMessageState == .sendingAfterE2eeEpochStale {
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
                        "[MESSAGE_SEND] state=failure_state_persist_failed \(PrivacySafeLogMetadata.errorFields(error))",
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

    func prepareEpochStaleRebind(
        _ rejection: E2eeMessageEpochStaleRejection,
        messageId: MessageId,
        isEdit: Bool,
        trace: E2eeSendTrace.Context? = nil,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        database.write({ session in
            guard let dto = session.message(id: messageId),
                  dto.prepareForE2eeEpochStaleRebind(rejection, isEdit: isEdit) else {
                throw MessageRepositoryError.messageNotPendingSend
            }
        }, completion: { error in
            if let error {
                trace?.failure(stage: "epoch_stale_rebind_persist_failed", error: error)
                completion(.failure(error))
            } else {
                trace?.info(
                    stage: "epoch_stale_rebind_persist_succeeded",
                    epoch: UInt64(rejection.currentGroupEpoch)
                )
                completion(.success(()))
            }
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
                log.error(
                    "[MESSAGE_STATE] state=persist_failed \(PrivacySafeLogMetadata.errorFields(error))"
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
                log.error("[MESSAGE_REACTION] state=remove_rollback_failed \(PrivacySafeLogMetadata.errorFields(error))")
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
                log.error("[MESSAGE_REACTION] state=add_rollback_failed \(PrivacySafeLogMetadata.errorFields(error))")
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
            cid: cid,
            expectedEnvelope: payload.e2eeReceivedEnvelope
        )
    }
}

extension MessageRepository: E2eeAttachmentMessageBinding {
    func persistCompletedE2eeAttachmentManifests(
        messageId: String,
        manifests: [E2eeAttachmentManifestV1]
    ) async throws {
        try manifests.verifyCanonicalAttachmentIds(manifests.map(\.attachmentId))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            database.write({ session in
                guard let message = session.message(id: messageId) else {
                    throw MessageRepositoryError.messageDoesNotExist
                }
                // A force-quit cancellation can be projected as `sendingFailed` before the
                // durable transfer is revived. Persisting the completed manifest is the final
                // pre-send boundary, so repair that stale UI/message state atomically here.
                // `.sending` variants are also safe to replay because E2EE keeps the exact
                // ciphertext/epoch intent durable and the server deduplicates by message ID.
                message.localMessageState = Self.preparedE2eeAttachmentSendState(
                    from: message.localMessageState
                )
                let payload = try Self.completedE2eeAttachmentPayload(message: message, manifests: manifests)
                try session.saveMessageDecrypt(
                    payload: payload,
                    messageId: messageId,
                    ciphertextHash: nil
                )
            }, completion: { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }

    static func completedE2eeAttachmentPayload(
        message: MessageDTO,
        manifests: [E2eeAttachmentManifestV1]
    ) throws -> E2ePayload {
        let existingPayload = try message.decryptedMessage?.asPayload()
        guard let channel = message.channel,
              message.cid == nil || message.cid == channel.cid else {
            throw MessageRepositoryError.messageDoesNotHaveValidChannel
        }
        let cid = try ChannelId(cid: channel.cid)
        var envelope = message.asRequestBody()
        try bindCompletedE2eeAttachmentEnvelope(
            request: &envelope, manifests: manifests, destinationCid: cid, groupCid: channel.mlsGroupCid
        )
        guard let aad = try envelope.authenticatedAAD() else {
            throw E2eeMessageAADError.authenticatedSendLaneUnavailable
        }
        _ = try aad.encoded()
        let metadata = E2eeAuthenticatedMessageMetadata(
            forwardCid: aad.forwardCid,
            forwardMessageId: aad.forwardMessageId,
            forwardParentCid: aad.forwardParentCid,
            attachmentIds: aad.attachmentIds
        )
        // Staging is local pending intent, not received ciphertext proof. Save metadata with
        // the manifest atomically so asPayload does not discard an unbound manifest.
        return E2ePayload(
            text: existingPayload?.text ?? message.text,
            attachments: [],
            e2eeAttachments: manifests,
            stickerUrl: existingPayload?.stickerUrl ?? message.stickerUrl,
            authenticatedMetadata: metadata
        )
    }

    static func bindCompletedE2eeAttachmentEnvelope(
        request: inout MessageRequestBody,
        manifests: [E2eeAttachmentManifestV1],
        destinationCid: ChannelId,
        groupCid: String
    ) throws {
        // Completed V1 manifests are the authoritative attachment lane. Local rendering rows
        // can already be uploaded on durable retry; never bind their standard payloads as AAD.
        request.attachments = []
        try request.bindE2eeAuthenticatedEnvelope(
            destinationCid: destinationCid,
            groupId: groupCid,
            attachmentIds: manifests.map(\.attachmentId),
            forwardParentCid: request.forwardParentCid
        )
        try manifests.verifyCanonicalAttachmentIds(request.e2eeAttachmentIds)
    }

    static func validateE2eeAttachmentSendBinding(
        message: MessageDTO,
        cachedPayload: E2ePayload?
    ) throws {
        guard message.attachments.contains(where: { $0.localURL != nil }) else { return }
        guard let cachedPayload, !cachedPayload.e2eeAttachments.isEmpty,
              let metadata = cachedPayload.authenticatedMetadata else {
            throw E2eeMessageAADError.authenticatedSendLaneUnavailable
        }
        try cachedPayload.e2eeAttachments.verifyCanonicalAttachmentIds(metadata.attachmentIds)
    }

    func sendPreparedE2eeAttachmentMessage(messageId: String) async throws {
        let requiresSend = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Bool, Error>) in
            database.backgroundReadOnlyContext.perform {
                guard let message = self.database.backgroundReadOnlyContext.message(id: messageId) else {
                    continuation.resume(throwing: MessageRepositoryError.messageDoesNotExist)
                    return
                }
                // A nil local state after relaunch proves the authoritative response was already
                // persisted. The transfer may safely close without issuing another POST.
                continuation.resume(returning: message.localMessageState != nil)
            }
        }
        guard requiresSend else { return }

        try await withCheckedThrowingContinuation { continuation in
            sendMessage(with: messageId) { result in
                switch result {
                case .success:
                    continuation.resume(returning: ())
                case let .failure(error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func preparedE2eeAttachmentSendState(
        from localState: LocalMessageState?
    ) -> LocalMessageState? {
        switch localState {
        case .sendingFailed, .sending:
            return .pendingSend
        case .sendingAfterE2eeEpochStale:
            return .pendingSendAfterE2eeEpochStale
        default:
            return localState
        }
    }
}
