////
//// Copyright 2025 Ermis Inc.
////
//
//import Foundation
//import ReownAppKit
//import Combine
//import UIKit
//@preconcurrency import CoinbaseWalletSDK
//import ErmisChat
//import WalletConnectSign
//
///// A class for authentication with crypto wallet.
///// Sign in flows when login with crypto wallet:
///// 1. Call `func start(from viewController: UIViewController, isDeleteAccount: Bool = false)`
///// 2. After user choose wallet to connect, call function `func startAuth(with address: String) async throws -> SignWalletPayload`
///// from `ErmisClient`
///// 3. Send `sendEthSignTypedData` (`sendCBSignTypedData` if wallet is CBWallet) with message is response from step 2.
///// 4. After user sign from there wallet, call `func walletAuthenticate(signature: String, address: String, nonce: String)` to get access token
//public class ErmisWalletAuthClient {
//    public weak var client: ErmisClient?
//    var currentNonce: String?
//    var chainId: Int?
//    var connectionState = WalletSignInState.idle
//
//    private var isDeleteAccount: Bool = false
//    private var disposeBag = Set<AnyCancellable>()
//
//    public var onUpdateState: ((WalletSignInState) -> Void)?
//    public var onLoginComplete: ((Result<(AuthenticationPayload, String), Error>) -> Void)?
//    public var onDeleteAccountCompleted: ((Error?) -> Void)?
//
//    /// Init new `ErmisWalletAuthClient` instance
//    ///
//    /// - Parameters:
//    ///   - client: The `ErmisClient` instance.
//    ///   - appName: The application name, this will show in wallet app when user connect.
//    ///   - description: The description infomation, this will show in wallet app when user connect.
//    ///   - url: The website url, this will show in wallet app when user connect
//    ///   - icons: The icon will show in wallet app when user connect.
//    ///
//    public init(with client: ErmisClient? = nil,
//                appName: String,
//                description: String,
//                url: String,
//                icons: [String]) {
//        let metadata = AppMetadata(
//            name: appName,
//            description: description,
//            url: url,
//            icons: icons,
//            redirect: try! .init(native: "w3mdapp://", universal: nil)
//        )
//
//        self.client = client
//        let projectId = "e31373630e55aba61ab1d976cecb2107"
//        setup(with: metadata,
//              projectId: projectId)
//    }
//    // MARK: - Public
//
//    /// Start singin wallet flows, this will show default UI of Reown
//    /// This will show pop up for user to select chain and wallet to connect.
//    ///
//    /// - Parameters:
//    ///  - viewController: The `UIViewController` to present pop up.
//    ///  - isDeleteAccount: The boolean variable, `true` if we this session for delete account,
//    ///  `false` if this session for login account.
//    ///
//    public func start(from viewController: UIViewController,
//                      isDeleteAccount: Bool = false) async {
//        await reset()
//        connectionState = .idle
//        self.isDeleteAccount = isDeleteAccount
//        DispatchQueue.main.async {
//            AppKit.present(from: viewController)
//        }
//    }
//
//    /// Handle WalletConnect deeplink.
//    ///
//    /// - Parameters:
//    ///  - url: The deeplink URL to handle.
//    ///
//    public func handleDeeplink(_ url: URL) {
//        guard url.scheme == "w3mdapp",
//              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
//              let queryItems = components.queryItems else {
//            return
//        }
//        if queryItems.contains(where: { $0.name == "wc_ev" }) {
//            AppKit.instance.handleDeeplink(url)
//        } else {
//            AppKit.instance.handleDeeplink(url)
//            handleCoinbaseDeepLink()
//        }
//    }
//
//    /// Reset to inital state.
//    public func reset() async {
//        CoinbaseWalletSDK.shared.resetSession()
//        try? await AppKit.instance.cleanup()
//        isDeleteAccount = false
//        self.connectionState = .idle
//        onUpdateState?(.idle)
//    }
//
//    // MARK: - Private
//    private func setup(with metaData: AppMetadata,
//                       projectId: String) {
//        Networking.configure(
//            groupIdentifier: client?.config.applicationGroupIdentifier ?? "",
//            projectId: projectId,
//            socketFactory: DefaultSocketFactory()
//        )
//
//        let methods: Set<String> = ["personal_sign", "eth_signTypedData"]
//        let events: Set<String> = ["chainChanged", "accountsChanged"]
//        let blockchains: [Blockchain] = [Blockchain("eip155:1")!]
//        let namespaces: [String: ProposalNamespace] = [
//            "eip155": ProposalNamespace(
//                chains: blockchains,
//                methods: methods,
//                events: events
//            )
//        ]
//
//        let optionalBlockchains: [Blockchain] = [
//            Blockchain("eip155:11155111")!
//        ]
//
//        AppKit.configure(projectId: projectId,
//                         metadata: metaData,
//                         crypto: DefaultCryptoProvider(),
//                         authRequestParams: nil
//        )
//
//        AppKit.instance.logger.setLogging(level: .debug)
//
//        AppKit.instance.sessionSettlePublisher.receive(on: DispatchQueue.main).sink { [weak self] session in
//            AppKit.instance.logger.debug(session)
//            let address = AppKit.instance.getAddress() ?? (session.namespaces.first?.value.accounts.first?.address) ?? ""
//            guard !address.isEmpty else {
//                return
//            }
//            self?.connectionState = .connected
//            self?.onUpdateState?(.connected)
//
//            Task(operation: { [weak self] in
//                guard let self else {
//                    return
//                }
//                do {
//                    var response: SignWalletPayload?
//                    if isDeleteAccount {
//                        response = try await client?.getDeleteUserChallange()
//                    } else {
//                        response = try await client?.startAuth(with: address)
//                    }
//                    guard let response, let challenge = response.value else {
//                        let error = NSError(domain: "Start auth failed", code: -999)
//                        self.complete(with: error)
//                        return
//                    }
//
//                    self.currentNonce = challenge.message.nonce
//                    
//                    // Wait until session hasValue
////                    while AppKit.instance.getSessions().isEmpty || AppKit.instance.getSelectedChain() == nil {
////                        try await Task.sleep(nanoseconds: 1_000_000_000)
////                    }
//
//                    try await sendEthSignTypedData(address: address, message: response.challenge)
//                    // Add some delay to ensure launch current wallet success.
//                    openWallet { [weak self] isSuccess in
//                        // Retry twice:
//                        if !isSuccess {
//                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: {
//                                self?.openWallet(completion: { [weak self] isSuccess in
//                                    if !isSuccess {
//                                        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: {
//                                            self?.openWallet(completion: nil)
//                                        })
//                                    }
//                                })
//                            })
//                        }
//                    }
//                } catch(let error) {
//                    AppKit.instance.logger.error(error.localizedDescription)
//                    self.complete(with: error)
//                }
//            })
//        }.store(in: &disposeBag)
//
//        AppKit.instance.sessionResponsePublisher.receive(on: DispatchQueue.main).sink { [weak self] response in
//            self?.handleSessionResponse(chainId: response.chainId, result: response.result)
//        }.store(in: &disposeBag)
//    }
//
//    private func coinbaseSign() {
//        guard let address = AppKit.instance.getAddress() else {
//            return
//        }
//        guard !address.isEmpty else {
//            return
//        }
//        self.connectionState = .connected
//        onUpdateState?(.connected)
//        Task(operation: { [weak self] in
//            guard let self else {
//                return
//            }
//
//            do {
//                var response: SignWalletPayload?
//                if isDeleteAccount {
//                    response = try await client?.getDeleteUserChallange()
//                } else {
//                    response = try await client?.startAuth(with: address)
//                }
//                guard let response, let challenge = response.value else {
//                    let error = NSError(domain: "Can't not send sign request", code: -999)
//                    self.complete(with: error)
//                    return
//                }
//                self.currentNonce = challenge.message.nonce
//                let rPCResult = try await sendCBSignTypedData(address: address, message: response.challenge)
//                self.handleSessionResponse(chainId: nil, result: rPCResult)
//            } catch(let error) {
//                AppKit.instance.logger.error(error.localizedDescription)
//            }
//        })
//    }
//
//    private func handleCoinbaseDeepLink() {
//        guard connectionState == .idle else {
//            return
//        }
//        DispatchQueue.main.async {
//            self.coinbaseSign()
//        }
//    }
//
//    private func sendEthSignTypedData(address: String, message: String) async throws {
//        guard let session = AppKit.instance.getSessions().first else {
//            return
//        }
//
//        let params = try Request(
//            topic: session.topic,
//            method: "eth_signTypedData",
//            params: AnyCodable(any: [address, message]),
//            chainId: Blockchain("eip155:1")!
//        )
//
//        try await Sign.instance.request(params: params)
//    }
//
//    private func sendCBSignTypedData(address: String, message: String) async throws -> RPCResult {
//        let request: Web3JSONRPC = .eth_signTypedData_v3(address: address, typedDataJson: JSONString(rawValue: message)!)
//        let coinbaseResult = try await withCheckedThrowingContinuation { continuation in
//            DispatchQueue.main.async(execute: {
//                CoinbaseWalletSDK.shared.makeRequest(.init(actions: [
//                    Action(jsonRpc: request)
//                ])) { result in
//                    switch result {
//                    case let .success(payload):
//                        continuation.resume(returning: payload)
//                    case let .failure(error):
//                        continuation.resume(throwing: error)
//                    }
//                }
//            })
//        }
//        let chainRefefence = AppKit.instance.getSelectedChain()?.chainReference
//        self.chainId = Int(chainRefefence ?? "1")
//        switch coinbaseResult.content.first {
//        case let .success(JSONString):
//            return .response(AnyCodable(JSONString))
//        case let .failure(error):
//            throw JSONRPCError(code: error.code, message: error.message)
//        case .none:
//            throw JSONRPCError(code: -1, message: "Empty response")
//        }
//    }
//
//    private func handleSessionResponse(chainId: String?, result: RPCResult) {
//        switch result {
//        case .response(let value):
//            // Save selected chainId:
//            if let chainId {
//                self.chainId = self.getSelectedChainId(from: chainId)
//            }
//            let signature = value.value as? String ?? ((value.value as? JSONString)?.decode() as? String ) ?? ""
//            guard let address = AppKit.instance.getAddress(),
//                  let currentNonce = self.currentNonce else {
//                return
//            }
//            self.connectionState = .signed
//            self.onUpdateState?(.signed)
//            Task(priority: .userInitiated, operation: { [weak self] in
//                if self?.isDeleteAccount == true {
//                    await self?.deleteUser(signature: signature)
//                } else {
//                    await self?.walletAuthenticate(signature: signature, address: address, nonce: currentNonce)
//                }
//            })
//        case .error(let error):
//            self.connectionState = .error
//            self.onUpdateState?(.error)
//            AppKit.instance.logger.error(error.localizedDescription)
//        }
//    }
//
//    private func getSelectedChainId(from chain: String) -> Int? {
//        guard let chainId = chain.split(separator: ":").last else {
//            return nil
//        }
//        return Int(chainId)
//    }
//
//    private func openWallet(completion: ((Bool) -> Void)?) {
//        let session = Sign.instance.getSessions().first
//        if let nativeUri = session?.peer.redirect?.native {
//            DispatchQueue.main.async(execute: {
//                UIApplication.shared.open(URL(string: "\(nativeUri)wc?requestSent")!) { isSuccess in
//                    completion?(isSuccess)
//                }
//            })
//        } else {
//            log.warning("Can't open wallet because there is not redirect url")
//        }
//    }
//
//    private func complete(with error: Error) {
//        if isDeleteAccount {
//            onDeleteAccountCompleted?(error)
//        } else {
//            onLoginComplete?(.failure(error))
//        }
//    }
//
//    private func walletAuthenticate(signature: String, address: String, nonce: String) async {
//        do {
//            guard let walletSigninResponse = try await self.client?.walletAuthenticate(with: signature,
//                                                                                       address: address,
//                                                                                       nonce: nonce) else {
//                self.complete(with: ClientError("Can't not get wallet token"))
//                return
//            }
//            self.onLoginComplete?(.success((walletSigninResponse, address)))
//            let session = AppKit.instance.getSessions().first
//            try await AppKit.instance.cleanup()
//            //                        AppKit.instance.removeSessionAndAccount()
//            try? await AppKit.instance.disconnect(topic: session?.topic ?? "")
//        } catch(let error) {
//            AppKit.instance.logger.error(error.localizedDescription)
//            self.complete(with: error)
//        }
//    }
//
//    private func deleteUser(signature: String) async {
//        do {
//            try await client?.deleteUser(signature: signature)
//            self.onDeleteAccountCompleted?(nil)
//        } catch {
//            self.complete(with: error)
//        }
//    }
//}
//
//extension AuthRequestParams {
//    static func ermis(
//        domain: String = "https://ermis.network",
//        chains: [String] = ["eip155:1", "eip155:137"],
//        nonce: String = "32891756",
//        uri: String = "https://lab.web3modal.com",
//        nbf: String? = nil,
//        exp: String? = nil,
//        statement: String? = "I accept the ServiceOrg Terms of Service: https://ermis.network",
//        requestId: String? = nil,
//        resources: [String]? = nil,
//        methods: [String]? = ["personal_sign", "eth_sendTransaction"]
//    ) -> AuthRequestParams {
//        return try! AuthRequestParams(
//            domain: domain,
//            chains: chains,
//            nonce: nonce,
//            uri: uri,
//            nbf: nbf,
//            exp: exp,
//            statement: statement,
//            requestId: requestId,
//            resources: resources,
//            methods: methods
//        )
//    }
//}
