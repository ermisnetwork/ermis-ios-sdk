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
/// - Message edit retry
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
            log.error("Failed to start MessageEditor worker. \(error)")
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
        database.write { [weak self, weak messageRepository, weak e2eRepository] session in
            guard let messageId = self?.pendingMessageIDs.first else { return }

            guard
                let dto = session.message(id: messageId),
                let cidString = dto.channel?.cid,
                let cid = try? ChannelId(cid: cidString),
                dto.localMessageState == .pendingSync
            else {
                self?.removeMessageIDAndContinue(messageId)
                return
            }

            var requestBody = dto.asRequestBody() as MessageRequestBody
            // Topics inherit their parent channel's MLS group, so a topic under an
            // E2EE parent is encrypted too.
            let isEncrypted = dto.channel?.isE2eeEnabled == true

            // Encrypt the edited message for E2E channels
            if isEncrypted, let e2eRepository {
                let e2ePayload = E2ePayload(
                    text: requestBody.text,
                    attachments: requestBody.attachments,
                    stickerUrl: requestBody.stickerUrl
                )
                do {
                    let (encryptedData, epoch) = try e2eRepository.encryptedMessage(e2ePayload, in: cid)
                    requestBody.encryptedData = encryptedData
                    requestBody.mlsEpoch = epoch
                    requestBody.text = ""
                    requestBody.attachments = []
                    requestBody.stickerUrl = nil
                } catch {
                    log.error("Failed to encrypt edited message \(messageId): \(error)")
                    messageRepository?.updateMessage(withID: messageId, localState: .syncingFailed) {
                        self?.removeMessageIDAndContinue(messageId)
                    }
                    return
                }
            }

            messageRepository?.updateMessage(withID: messageId, localState: .syncing) {
                self?.apiClient.request(endpoint: .editMessage(payload: requestBody,
                                                               oldMessage: nil,
                                                               channelId: cid)) {
                    let newMessageState: LocalMessageState? = $0.error == nil ? nil : .syncingFailed

                    messageRepository?.updateMessage(
                        withID: messageId,
                        localState: newMessageState
                    ) {
                        self?.removeMessageIDAndContinue(messageId)
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
