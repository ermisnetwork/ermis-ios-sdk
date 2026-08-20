//
// Copyright 2025 Ermis Inc.
//

import Foundation
import ErmisShared
import ErmisShared

typealias QueueOfflineRequestBlock = (DataEndpoint) -> Void
typealias DataEndpoint = Endpoint<Data>

extension Endpoint {
    var withDataResponse: DataEndpoint {
        DataEndpoint(
            path: path,
            method: method,
            query: query,
            body: body,
            needConnectionId: needConnectionId,
            needToken: needToken
        )
    }
}

/// OfflineRequestsRepository handles both the enqueuing and the execution of offline requests when needed.
/// When running the queued requests, it basically passes the requests on to the APIClient, and waits for its result.
class OfflineRequestsRepository {
    enum Constants {
        static let secondsInHour: Double = 3600
    }
    
    private let messageRepository: MessageRepository
    private let database: DatabaseContainer
    private let apiClient: APIClient
    private let maxHoursThreshold: Int

    /// Serial queue used to enqueue pending requests one after another
    private let retryQueue = DispatchQueue(label: "network.ermis.queue-requests")

    init(
        messageRepository: MessageRepository,
        database: DatabaseContainer,
        apiClient: APIClient,
        maxHoursThreshold: Int
    ) {
        self.messageRepository = messageRepository
        self.database = database
        self.apiClient = apiClient
        self.maxHoursThreshold = maxHoursThreshold
    }

    /// - If the requests succeeds -> The request is removed from the pending ones
    /// - If the request fails with a connection error -> The request is kept to be executed once the connection is back (we are not putting it back at the queue to make sure we respect the order)
    /// - If the request fails with any other error -> We are dismissing the request, and removing it from the queue
    func runQueuedRequests(completion: @escaping () -> Void) {
        let readContext = database.backgroundReadOnlyContext
        readContext.perform { [weak self] in
            let requests = QueuedRequestDTO.loadAllPendingRequests(context: readContext).map {
                ($0.id, $0.endpoint, $0.date as Date)
            }
            DispatchQueue.main.async {
                self?.executeRequests(requests, completion: completion)
            }
        }
    }

    private func executeRequests(_ requests: [(String, Data, Date)], completion: @escaping () -> Void) {
        log.info("\(requests.count) pending offline requests", subsystems: .offlineSupport)

        let database = self.database
        let currentDate = Date()
        let group = DispatchGroup()
        for (id, endpoint, date) in requests {
            group.enter()
            let leave = {
                group.leave()
            }
            let deleteQueuedRequestAndComplete = {
                database.write({ session in
                    session.deleteQueuedRequest(id: id)
                }, completion: { _ in leave() })
            }

            guard let endpoint = try? JSONDecoder.ermis.decode(DataEndpoint.self, from: endpoint) else {
                log.error("[OFFLINE_REQUEST] state=decode_failed", subsystems: .offlineSupport)
                deleteQueuedRequestAndComplete()
                continue
            }
            
            let hoursQueued = currentDate.timeIntervalSince(date) / Constants.secondsInHour
            let shouldBeDiscarded = hoursQueued > Double(maxHoursThreshold)

            guard endpoint.shouldBeQueuedOffline && !shouldBeDiscarded else {
                log.error("[OFFLINE_REQUEST] state=discarded reason=ineligible_or_expired", subsystems: .offlineSupport)
                deleteQueuedRequestAndComplete()
                continue
            }

            log.info("[OFFLINE_REQUEST] state=executing", subsystems: .offlineSupport)
            apiClient.recoveryRequest(endpoint: endpoint) { [weak self] result in
                log.info("[OFFLINE_REQUEST] state=completed", subsystems: .offlineSupport)
                switch result {
                case let .success(data):
                    self?.performDatabaseRecoveryActionsUponSuccess(
                        for: endpoint,
                        data: data,
                        completion: deleteQueuedRequestAndComplete
                    )
                case .failure(_ as ClientError.ConnectionError):
                    // If we failed because there is still no successful connection, we don't remove it from the queue
                    log.info("[OFFLINE_REQUEST] state=retained reason=network_unavailable", subsystems: .offlineSupport)
                    leave()
                case .failure:
                    log.info("[OFFLINE_REQUEST] state=failed", subsystems: .offlineSupport)
                    deleteQueuedRequestAndComplete()
                }
            }
        }

        group.notify(queue: DispatchQueue.main) {
            log.info("Done executing all queued offline requests", subsystems: .offlineSupport)
            completion()
        }
    }

    private func performDatabaseRecoveryActionsUponSuccess(
        for endpoint: DataEndpoint,
        data: Data,
        completion: @escaping () -> Void
    ) {
        func decodeTo<T: Decodable>(_ type: T.Type) -> T? {
            try? JSONDecoder.ermis.decode(T.self, from: data)
        }

        switch endpoint.path {
        case let .sendMessage(channelId):
            guard let message = decodeTo(MessagePayload.Boxed.self) else {
                completion()
                return
            }
            messageRepository.saveSuccessfullySentMessage(cid: channelId, message: message.message) { _ in completion() }
        case let .editMessage(messageId, _):
            messageRepository.saveSuccessfullyEditedMessage(for: messageId, completion: completion)
        case .deleteMessage:
            guard let message = decodeTo(MessagePayload.Boxed.self) else {
                completion()
                return
            }
            messageRepository.saveSuccessfullyDeletedMessage(message: message.message) { _ in completion() }
        case .addReaction, .deleteReaction:
            // No further action
            completion()
        default:
            log.assertionFailure("Should not reach here, request should not require action")
            completion()
        }
    }

    func queueOfflineRequest(endpoint: DataEndpoint, completion: (() -> Void)? = nil) {
        guard endpoint.shouldBeQueuedOffline else {
            completion?()
            return
        }

        let date = Date()
        retryQueue.async { [database] in
            guard let data = try? JSONEncoder.ermis.encode(endpoint) else {
                log.error("[OFFLINE_REQUEST] state=encode_failed", subsystems: .offlineSupport)
                completion?()
                return
            }

            database.write { _ in
                QueuedRequestDTO.createRequest(date: date, endpoint: data, context: database.writableContext)
                log.info("[OFFLINE_REQUEST] state=queued", subsystems: .offlineSupport)
                completion?()
            }
        }
    }
}
