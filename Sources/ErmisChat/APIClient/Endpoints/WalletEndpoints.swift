//
// Copyright 2025 Ermis Inc.
//

import Foundation

extension Endpoint {
    /// Create the endpoint to sign with user's wallet.
    ///
    /// - Parameters:
    ///   - address: The address of wallet.
    /// - Returns: The endpoint sign with user's walet.
    static func signWallet(_ address: String, apiKey: String) -> Endpoint<SignWalletPayload> {
        let params = [
            "address": address,
            "apikey": apiKey
        ]
        return .init(path: .signWallet,
                     method: .post,
                     body: params,
                     needToken: false,
                     isAuth: true
        )
    }

    /// Create the endpoint to authenticate with user's wallet.
    ///
    /// - Parameters:
    ///   - signature: sinature string get when sign with wallet.
    ///   - address: user's wallet address.
    ///   - nonce: The nonce value.
    ///   - apiKey: Current project's apikey.
    /// - Returns: The endpoint to authenticate with user's wallet.
    static func walletAuthenticate(_ signature: String,
                                   address: String,
                                   nonce: String,
                                   apiKey: String) -> Endpoint<AuthenticationPayload> {
        let body = WalletAuthenticateRequestBody(address: address,
                                                 signature: signature,
                                                 nonce: nonce,
                                                 apiKey: apiKey)
        return .init(path: .walletAuthenticate,
                     method: .post,
                     body: body,
                     needToken: false,
                     isAuth: true
        )
    }

    /// Create the endpoint to get available chains of current project.
    ///
    /// - Returns: The endpoint to get available chains of current project.
    static func getChains() -> Endpoint<ChainListPayload> {
        .init(path: .getChains,
              method: .get,
              needConnectionId: false,
              isAuth: true
        )
    }

    /// Create the endpoint to get list client on a chain.
    ///
    /// - Parameters:
    ///   - chain: The chain's identifier.
    /// - Returns: The endpoint to get list client on a chain.
    static func getClients(on chain: String) -> Endpoint<[ErmisClientPayload]> {
        .init(path: .getUserClients,
              method: .post,
              body: [
                "chain_id": chain
              ],
              isAuth: true)
    }

    /// Create the endpoint to get list project on a client.
    ///
    /// - Parameters:
    ///   - client: The client's identifier.
    ///   - chain: The chain's identifier
    /// - Returns: The endpoint to get list project on a client.
    static func getProjects(of client: String, on chain: String) -> Endpoint<[ErmisProjectPayload]> {
        .init(path: .getUserProjects,
              method: .post,
              body: [
                "chain_id": chain,
                "client_id": client
              ],
              isAuth: true)
    }

    /// Create the endpoint to join a project.
    ///
    /// - Parameters:
    ///   - projectId: The project's identifier.
    /// - Returns: The endpoint to get list project on a client.
    static func joinProject(_ projectId: String) -> Endpoint<ChainListPayload> {
        .init(path: .joinProject,
              method: .post,
              body: [
                "project_id": projectId
              ],
              isAuth: true)
    }
}


