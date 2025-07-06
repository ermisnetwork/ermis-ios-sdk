//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// This class is in charge of the synchronization of our local storage with the remote.
/// When executing a sync, it will remove outdated elements, and will refresh the content to always show the latest data.
class SyncRepository {
    private let config: ErmisClientConfig
    private let database: DatabaseContainer
    private let apiClient: APIClient
    let offlineRequestsRepository: OfflineRequestsRepository

    init(
        config: ErmisClientConfig,
        offlineRequestsRepository: OfflineRequestsRepository,
        database: DatabaseContainer,
        apiClient: APIClient
    ) {
        self.config = config
        self.offlineRequestsRepository = offlineRequestsRepository
        self.database = database
        self.apiClient = apiClient
    }

    deinit {
        apiClient.exitRecoveryMode()
    }

    func subscribe() {
        apiClient.sseRequest(endpoint: .subscribe(), completion: { [weak self] ssePayload, error in
            if let ssePayload, let userPayload = ssePayload.user {
                self?.database.write { session in
                    try? session.saveUser(payload: userPayload, projectId: userPayload.projectId)
                }
            }

        })
    }

    func queueOfflineRequest(endpoint: DataEndpoint) {
        guard config.isLocalStorageEnabled else { return }
        offlineRequestsRepository.queueOfflineRequest(endpoint: endpoint)
    }
}
