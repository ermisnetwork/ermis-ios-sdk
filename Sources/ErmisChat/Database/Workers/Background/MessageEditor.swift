//
// Copyright 2025 Ermis Inc.
//

import CoreData
import Foundation
import ErmisShared

/// Observers the storage for messages in a `pendingSync` state and updates them on the backend.
///
/// Sending of the message has the following phases:
///     1. When a message with `pendingSync` state local state appears in the db, the editor eques it in the sending queue.
///     2. The pending messages are edited one by one, the order doesn't matter here.
///     3. When the message is being sent, its local state is changed to `syncing`
///     4. If the operation is successful, the local state of the message is changed to `nil`. If the operation fails, the local
///     state of is changed to `syncingFailed`.
///
// TODO:
/// - Start editing messages when connection status changes (offline -> online)
///
class MessageEditor: Worker {
    @Atomic private var pendingMessageIDs: Set<MessageId> = []

    private let observer: ListDatabaseObserver<MessageDTO, MessageDTO>
    private let messageRepository: MessageRepository
    private let e2eRepository: E2eRepository?

    init(messageRepository: MessageRepository, e2eRepository: E2eRepository? = nil, database: DatabaseContainer, apiClient: APIClient) {
        observer = .init(
            context: database.backgroundReadOnlyContext,
            fetchRequest: MessageDTO.messagesPendingSyncFetchRequest(),
            itemCreator: { $0 }
        )
        self.messageRepository = messageRepository
        self.e2eRepository = e2eRepository
        super.init(database: database, apiClient: apiClient)

        startObserving()
    }

    // MARK: - Private

    private func startObserving() {
        do {
            try observer.startObserving()
            observer.onChange = { [weak self] in self?.handleChanges(changes: $0) }
            let changes = observer.items.map { ListChange.insert($0, index: .init(item: 0, section: 0)) }
            handleChanges(changes: changes)
        } catch {
            log.error("[MESSAGE_EDIT] state=observer_start_failed \(PrivacySafeLogMetadata.errorFields(error))")
        }
    }

    private func handleChanges(changes: [ListChange<MessageDTO>]) {
        guard !changes.isEmpty else { return }

        var wasEmpty: Bool = false
        _pendingMessageIDs.mutate { pendingMessageIDs in
            wasEmpty = pendingMessageIDs.isEmpty
            changes.pendingEditMessageIDs.forEach { pendingMessageIDs.insert($0) }
        }

        if wasEmpty {
            processNextMessage()
        }
    }

    private func processNextMessage() {
        guard let messageId = pendingMessageIDs.first else { return }

        processMessage(messageId, epochRecoveryCompleted: false)
    }

    private func processMessage(_ messageId: MessageId, epochRecoveryCompleted: Bool) {
        database.backgroundReadOnlyContext.perform { [weak self, weak messageRepository, weak e2eRepository] in
            guard let self else { return }
            let localState = self.database.backgroundReadOnlyContext.message(id: messageId)?.localMessageState
            let isEpochStaleRetry = localState == .pendingSyncAfterE2eeEpochStale
            guard
                let dto = self.database.backgroundReadOnlyContext.message(id: messageId),
                let cidString = dto.channel?.cid,
                let cid = try? ChannelId(cid: cidString),
                localState == .pendingSync || isEpochStaleRetry
            else {
                self.removeMessageIDAndContinue(messageId)
                return
            }

            var requestBody = dto.asRequestBody() as MessageRequestBody
            // Topics inherit their parent channel's MLS group, so a topic under an
            // E2EE parent is encrypted too.
            let isEncrypted = dto.channel?.isE2eeEnabled == true

            if isEpochStaleRetry && !epochRecoveryCompleted {
                guard let e2eRepository else {
                    messageRepository?.updateMessage(withID: messageId, localState: .syncingFailed) {
                        self.removeMessageIDAndContinue(messageId)
                    }
                    return
                }
                e2eRepository.recoverMessageEpoch(
                    in: cid,
                    minimumEpoch: dto.mlsEpoch
                ) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .success:
                        self.processMessage(messageId, epochRecoveryCompleted: true)
                    case .failure(let error):
                        log.error("[MESSAGE_EDIT] state=epoch_recovery_failed \(PrivacySafeLogMetadata.errorFields(error))")
                        messageRepository?.updateMessage(withID: messageId, localState: .syncingFailed) {
                            self.removeMessageIDAndContinue(messageId)
                        }
                    }
                }
                return
            }

            // Encrypt the edited message for E2E channels. A failed/unknown HTTP result must
            // reuse the exact ciphertext already stored on MessageDTO; generating another one
            // consumes a new sender secret and makes crash recovery non-idempotent.
            if isEncrypted {
                guard let e2eRepository else {
                    log.error("[MESSAGE_EDIT] state=blocked reason=e2ee_repository_missing")
                    messageRepository?.updateMessage(withID: messageId, localState: .syncingFailed) {
                        self.removeMessageIDAndContinue(messageId)
                    }
                    return
                }
                guard !requestBody.requiresE2eeAuthenticatedSendLane else {
                    log.error("[MESSAGE_EDIT] state=blocked reason=authenticated_lane_required")
                    messageRepository?.updateMessage(withID: messageId, localState: .syncingFailed) {
                        self.removeMessageIDAndContinue(messageId)
                    }
                    return
                }

                let e2ePayload = E2ePayload(
                    text: requestBody.text,
                    attachments: requestBody.attachments,
                    stickerUrl: requestBody.stickerUrl
                )
                do {
                    let encryptedData: [UInt8]
                    let epoch: Int
                    if let durableCiphertext = requestBody.encryptedData,
                       let durableEpoch = requestBody.mlsEpoch {
                        encryptedData = durableCiphertext
                        epoch = durableEpoch
                    } else {
                        (encryptedData, epoch) = try e2eRepository.encryptedMessage(e2ePayload, in: cid)
                    }

                    // Claim this exact edit generation and durably store its network intent in
                    // one Core Data transaction before the HTTP request can start. Re-checking
                    // the plaintext prevents a concurrent user edit from sending stale content.
                    try self.database.writeAndWait { session in
                        guard let current = session.message(id: messageId),
                              current.localMessageState == localState else {
                            throw MessageEditIntentError.messageNoLongerPending
                        }
                        let currentBody = current.asRequestBody()
                        let currentPayload = E2ePayload(
                            text: currentBody.text,
                            attachments: currentBody.attachments,
                            stickerUrl: currentBody.stickerUrl
                        )
                        guard currentPayload == e2ePayload else {
                            throw MessageEditIntentError.generationChanged
                        }

                        if let storedCiphertext = current.encryptedData {
                            guard storedCiphertext.uint8Array == encryptedData,
                                  Int(current.mlsEpoch) == epoch else {
                                throw MessageEditIntentError.generationChanged
                            }
                        } else {
                            current.encryptedData = Data(encryptedData)
                            current.mlsEpoch = Int64(epoch)
                            try session.saveMessageDecrypt(
                                payload: e2ePayload,
                                messageId: messageId,
                                ciphertextHash: nil
                            )
                        }
                        current.localMessageState = isEpochStaleRetry
                            ? .syncingAfterE2eeEpochStale
                            : .syncing
                    }
                    requestBody.bindE2eeNetworkIntent(ciphertext: encryptedData, epoch: epoch)
                } catch MessageEditIntentError.generationChanged {
                    // Keep the ID queued. The next pass snapshots and encrypts the newer edit.
                    self.processNextMessage()
                    return
                } catch MessageEditIntentError.messageNoLongerPending {
                    self.removeMessageIDAndContinue(messageId)
                    return
                } catch {
                    log.error("[MESSAGE_EDIT] state=encryption_failed \(PrivacySafeLogMetadata.errorFields(error))")
                    messageRepository?.updateMessage(withID: messageId, localState: .syncingFailed) {
                        self.removeMessageIDAndContinue(messageId)
                    }
                    return
                }
                self.apiClient.request(endpoint: .editMessage(payload: requestBody,
                                                              oldMessage: nil,
                                                              channelId: cid)) {
                    switch $0 {
                    case .success:
                        messageRepository?.updateMessage(withID: messageId, localState: nil) {
                            self.removeMessageIDAndContinue(messageId)
                        }
                    case .failure(let error):
                        if !isEpochStaleRetry,
                           let rejection = E2eeMessageEpochStaleRejection.parse(error),
                           let intentEpoch = requestBody.mlsEpoch,
                           rejection.canRebind(intentEpoch: Int64(intentEpoch)) {
                            messageRepository?.prepareEpochStaleRebind(
                                rejection,
                                messageId: messageId,
                                isEdit: true
                            ) { result in
                                switch result {
                                case .success:
                                    self.processMessage(messageId, epochRecoveryCompleted: false)
                                case .failure:
                                    messageRepository?.updateMessage(
                                        withID: messageId,
                                        localState: .syncingFailed
                                    ) {
                                        self.removeMessageIDAndContinue(messageId)
                                    }
                                }
                            }
                        } else {
                            messageRepository?.updateMessage(
                                withID: messageId,
                                localState: .syncingFailed
                            ) {
                                self.removeMessageIDAndContinue(messageId)
                            }
                        }
                    }
                }
                return
            }

            messageRepository?.updateMessage(withID: messageId, localState: .syncing) {
                self.apiClient.request(endpoint: .editMessage(payload: requestBody,
                                                              oldMessage: nil,
                                                              channelId: cid)) {
                    let newMessageState: LocalMessageState? = $0.error == nil ? nil : .syncingFailed
                    messageRepository?.updateMessage(withID: messageId, localState: newMessageState) {
                        self.removeMessageIDAndContinue(messageId)
                    }
                }
            }
        }
    }

    private func removeMessageIDAndContinue(_ messageId: MessageId) {
        _pendingMessageIDs.mutate { $0.remove(messageId) }
        processNextMessage()
    }
}

private enum MessageEditIntentError: Error {
    case generationChanged
    case messageNoLongerPending
}

private extension Array where Element == ListChange<MessageDTO> {
    var pendingEditMessageIDs: [MessageId] {
        compactMap {
            switch $0 {
            case let .insert(dto, _), let .update(dto, _):
                return dto.id
            case .move, .remove:
                return nil
            }
        }
    }
}
