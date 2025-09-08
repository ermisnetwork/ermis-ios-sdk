//
// Copyright 2025 Ermis Inc.
//

import Foundation

class CallRepository {
    private let apiClient: APIClient

    init(apiClient: APIClient) {
        self.apiClient = apiClient
    }

    func sendSignal(body: CallSignalRequestBody,
                    completion: @escaping (Result<CallSignalRequestPayload, Error>) -> Void) {
        apiClient.request(endpoint: .signal(body: body),
                          completion: completion)
    }

    func sendSignal(body: CallSignalRequestBody) async throws -> CallSignalRequestPayload {
        try await apiClient.request(endpoint: .signal(body: body))
    }
}
