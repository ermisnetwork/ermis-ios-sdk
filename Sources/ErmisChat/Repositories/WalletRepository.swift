//
// Copyright 2025 Ermis Inc.
//

import Foundation

class WalletRepository {
    let database: DatabaseContainer
    let apiClient: APIClient
    let apiKey: APIKey

    init(database: DatabaseContainer, apiClient: APIClient, apiKey: APIKey) {
        self.database = database
        self.apiClient = apiClient
        self.apiKey = apiKey
    }

    func startAuth(with address: String) async throws -> SignWalletPayload {
        return try await apiClient.request(endpoint: .signWallet(address,
                                                                 apiKey: apiKey.apiKeyString))
    }

    func walletAuthenticate(with signature: String,
                            address: String,
                            nonce: String) async throws -> AuthenticationPayload {
        return try await apiClient.request(endpoint: .walletAuthenticate(signature,
                                                                         address: address,
                                                                         nonce: nonce,
                                                                         apiKey: apiKey.apiKeyString))
    }

    func getChains() async throws -> ChainListPayload {
        let chainList = try await apiClient.request(endpoint: .getChains())
        return chainList
    }

    func getChains(completion: @escaping (Result<ChainListPayload, Error>) -> Void) {
        apiClient.request(endpoint: .getChains(), completion: completion)
    }

    func getClients(on chain: String) async throws -> [ErmisClientPayload] {
        let clientList = try await apiClient.request(endpoint: .getClients(on: chain))
        return clientList
    }

    func getClients(on chain: String, completion: @escaping (Result<[ErmisClientPayload], Error>) -> Void) {
        apiClient.request(endpoint: .getClients(on: chain), completion: completion)
    }

    func getProjects(of client: String, on chain: String) async throws -> [ErmisProjectPayload] {
        let projects = try await apiClient.request(endpoint: .getProjects(of: client, on: chain))
        return projects
    }

    func getProjects(of client: String,
                     on chain: String,
                     completion: @escaping (Result<[ErmisProjectPayload], Error>) -> Void) {
        apiClient.request(endpoint: .getProjects(of: client, on: chain), completion: completion)
    }

    func joinProject(_ projectId: String,
                     completion: @escaping (Result<ChainListPayload, Error>) -> Void) {
        apiClient.request(endpoint: .joinProject(projectId), completion: completion)
    }
}
