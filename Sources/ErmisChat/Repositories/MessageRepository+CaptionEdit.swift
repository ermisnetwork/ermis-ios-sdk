import Foundation
import CryptoKit

extension MessageRepository {
    func editCaptionMessage(with messageId: String, completion: @escaping (Result<Void, Error>) -> Void) {
        database.backgroundReadOnlyContext.perform { [weak self] in
            guard let self else { return }
            do {
                guard let dto = self.database.backgroundReadOnlyContext.message(id: messageId),
                      let bytes = dto.e2eeCaptionEditData, !dto.isHardDeleted,
                      dto.localMessageState == .pendingSync || dto.localMessageState == .syncingFailed else {
                    throw MlsSendIntentError.conflict
                }
                let snapshot = try E2eeCaptionEditSnapshot.decode(bytes)
                let cid = try ChannelId(cid: snapshot.cid)
                guard dto.id.lowercased() == snapshot.messageId, dto.channel?.cid == snapshot.cid else {
                    throw MlsSendIntentError.conflict
                }
                let intent = try self.e2eRepository.prepareOutgoingCaptionEdit(snapshot)
                let fence = try self.e2eRepository.outgoingSessionFence(intent)
                try self.database.writeAndWait { session in
                    try fence()
                    guard let current = session.message(id: messageId), current.e2eeCaptionEditData == bytes,
                          !current.isHardDeleted, current.deletedAt == nil,
                          current.encryptedData.map({ Data(SHA256.hash(data: $0)) }) == snapshot.baseCiphertextHash ||
                            current.encryptedData == intent.ciphertext else { throw MlsSendIntentError.conflict }
                    current.localMessageState = .syncing
                }
                if intent.requiresReconcile || intent.phase == .accepted {
                    self.queryCaptionEditCanonical(snapshot, intent: intent, completion: completion)
                } else {
                    self.dispatchCaptionEdit(snapshot, intent: intent, completion: completion)
                }
            } catch {
                self.finishCaptionEditFailure(messageId, error: error, completion: completion)
            }
        }
    }

    private func queryCaptionEditCanonical(_ snapshot: E2eeCaptionEditSnapshot, intent: MlsSendIntent,
                                            completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            let cid = try ChannelId(cid: snapshot.cid), fence = try e2eRepository.outgoingSessionFence(intent)
            let query = ChannelQuery(cid: cid, pageSize: 1, paginationParameter: .around(snapshot.messageId), membersLimit: 0, watchersLimit: 0)
            var endpoint = Endpoint<ChannelPayload>(path: .mlsControl("channels/" + cid.apiPath + "/query"), method: .post, body: try JSONEncoder.ermis.encode(query))
            endpoint.localMlsGuard = fence
            endpoint.localMlsDeadline = Date().addingTimeInterval(15)
            endpoint.localMlsTimeoutReason = "mls_edit_reconcile_unknown"
            apiClient.request(endpoint: endpoint) { result in
                do {
                    try fence()
                    guard let current = try result.get().messages.first(where: { $0.id.lowercased() == snapshot.messageId }),
                          let cipher = current.encryptedData.map({ Data($0) }) else { throw MlsSendIntentError.conflict }
                    if cipher == intent.ciphertext {
                        self.publishCaptionEdit(snapshot, intent: intent, canonical: current, completion: completion)
                    } else if Data(SHA256.hash(data: cipher)) == snapshot.baseCiphertextHash && intent.phase != .accepted {
                        self.dispatchCaptionEdit(snapshot, intent: intent, completion: completion)
                    } else {
                        throw MlsSendIntentError.conflict // Another canonical version won; never repost the stale edit.
                    }
                } catch { self.finishCaptionEditFailure(snapshot.messageId, error: error, completion: completion) }
            }
        } catch { finishCaptionEditFailure(snapshot.messageId, error: error, completion: completion) }
    }

    private func dispatchCaptionEdit(_ snapshot: E2eeCaptionEditSnapshot, intent: MlsSendIntent,
                                     completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            let record = try e2eRepository.markOutgoingDispatch(intent)
            let fence = try e2eRepository.outgoingSessionFence(record)
            guard let wire = record.wireEnvelope else { throw MlsSendIntentError.invalid }
            let cid = try ChannelId(cid: snapshot.cid)
            var endpoint = Endpoint<MessagePayload.Boxed>(path: .editE2eMessage(snapshot.messageId, cid), method: .post, body: wire, needDeviceId: true)
            endpoint.localMlsDeadline = Date().addingTimeInterval(15)
            endpoint.localMlsTimeoutReason = "mls_edit_outcome_unknown"
            endpoint.localMlsGuard = { [weak self] in
                try fence()
                guard let self else { throw MlsSendIntentError.conflict }
                try self.e2eRepository.assertOutgoingOwner(record)
            }
            apiClient.request(endpoint: endpoint) { result in
                do {
                    try fence()
                    self.publishCaptionEdit(snapshot, intent: record, canonical: try result.get().message, completion: completion)
                } catch { self.finishCaptionEditFailure(snapshot.messageId, error: error, completion: completion) }
            }
        } catch { finishCaptionEditFailure(snapshot.messageId, error: error, completion: completion) }
    }

    private func publishCaptionEdit(_ snapshot: E2eeCaptionEditSnapshot, intent: MlsSendIntent, canonical: MessagePayload,
                                    completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            let cid = try ChannelId(cid: snapshot.cid), fence = try e2eRepository.outgoingSessionFence(intent)
            try e2eRepository.validateOutgoingAcceptance(intent, message: canonical, destination: cid)
            let decoded = try E2eeArchiveMessageValidator.validate(snapshot.payload, processedAAD: intent.aad,
                messageId: snapshot.messageId, cid: snapshot.cid, groupCid: intent.cid)
            guard let cipher = intent.ciphertext else { throw MlsSendIntentError.invalid }
            try database.writeAndWait { session in
                try fence()
                guard let current = session.message(id: snapshot.messageId), !current.isHardDeleted, current.deletedAt == nil,
                      current.channel?.cid == snapshot.cid, current.user.userId == canonical.user.id,
                      current.createdAt.bridgeDate == canonical.createdAt,
                      let data = current.e2eeCaptionEditData,
                      try E2eeCaptionEditSnapshot.decode(data) == snapshot,
                      current.encryptedData.map({ Data(SHA256.hash(data: $0)) }) == snapshot.baseCiphertextHash || current.encryptedData == cipher else {
                    throw MlsSendIntentError.conflict
                }
                current.localMessageState = .syncing // Ordinary save's unsent guard remains intact.
                let saved = try session.saveMessage(payload: canonical, for: cid, syncOwnReactions: false, cache: nil)
                guard saved.encryptedData == cipher else { throw MlsSendIntentError.conflict }
                try session.saveMessageDecrypt(payload: decoded, messageId: snapshot.messageId,
                    ciphertextHash: Data(SHA256.hash(data: cipher)))
                guard try saved.decryptedMessage?.asPayload() == decoded else { throw MlsSendIntentError.storage }
            }
            // writeAndWait has released Core Data's writer before entering MLS retirement.
            try e2eRepository.acceptOutgoingSend(intent)
            try database.writeAndWait { session in
                try fence()
                guard let saved = session.message(id: snapshot.messageId), saved.encryptedData == cipher,
                      let data = saved.e2eeCaptionEditData, try E2eeCaptionEditSnapshot.decode(data) == snapshot else {
                    throw MlsSendIntentError.conflict
                }
                saved.e2eeCaptionEditData = nil
                saved.localMessageState = nil
            }
            completion(.success(()))
        } catch { finishCaptionEditFailure(snapshot.messageId, error: error, completion: completion) }
    }

    private func finishCaptionEditFailure(_ id: String, error: Error, completion: @escaping (Result<Void, Error>) -> Void) {
        database.write({ session in
            if let current = session.message(id: id), current.e2eeCaptionEditData != nil {
                current.localMessageState = .syncingFailed
            }
        }, completion: { _ in completion(.failure(error)) })
    }
}
