//
// Copyright 2026 Ermis Inc.
//

import XCTest
@testable import ErmisChat

final class ConnectionProviderImmediateDeliveryTests: XCTestCase {
    func testAvailableTokenIsDeliveredBeforeProvideTokenReturns() throws {
        let dependencies = try makeDependencies(isClientInActiveMode: false)
        let token = Token(
            rawValue: "test-token",
            userId: "user-1",
            clientId: "client-1",
            projectId: "project-1",
            chainId: 1,
            isErmis: false,
            expiration: nil
        )
        dependencies.authenticationRepository.setToken(
            token: token,
            completeTokenWaiters: true
        )

        var resultBeforeReturn: Result<Token, Error>?
        dependencies.authenticationRepository.provideToken { result in
            resultBeforeReturn = result
        }

        XCTAssertEqual(try resultBeforeReturn?.get(), token)
    }

    func testImmediateConnectionProviderErrorIsDeliveredBeforeReturn() throws {
        let dependencies = try makeDependencies(isClientInActiveMode: false)

        var resultBeforeReturn: Result<ConnectionId, Error>?
        dependencies.connectionRepository.provideConnectionId { result in
            resultBeforeReturn = result
        }

        guard case .failure(let error)? = resultBeforeReturn else {
            return XCTFail("Expected the inactive-mode error before provideConnectionId returned")
        }
        XCTAssertTrue(error is ClientError.ClientIsNotInActiveMode)
    }

    private func makeDependencies(
        isClientInActiveMode: Bool
    ) throws -> (
        authenticationRepository: AuthenticationRepository,
        connectionRepository: ConnectionRepository
    ) {
        let baseURL = try XCTUnwrap(URL(string: "https://example.invalid"))
        let encoder = DefaultRequestEncoder(
            baseURL: baseURL,
            authURL: baseURL,
            stickerURL: baseURL,
            apiKey: APIKey("test-key")
        )
        let decoder = DefaultRequestDecoder()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        let apiClient = APIClient(
            sessionConfiguration: sessionConfiguration,
            requestEncoder: encoder,
            requestDecoder: decoder,
            uploader: ErmisUploader(
                uploadClient: ErmisUploadClient(
                    encoder: encoder,
                    decoder: decoder,
                    sessionConfiguration: sessionConfiguration
                )
            ),
            downloader: ErmisDownloader(
                client: ErmisDownloadClient(sessionConfiguration: sessionConfiguration)
            )
        )
        let connectionRepository = ConnectionRepository(
            isClientInActiveMode: isClientInActiveMode,
            webSocketClient: nil,
            apiClient: apiClient,
            timerType: DefaultTimer.self,
            apiKey: "test-key"
        )
        let database = DatabaseContainer(
            kind: .inMemory,
            shouldResetEphemeralValuesOnStart: false
        )
        let storeLoaded = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                !database.persistentStoreCoordinator.persistentStores.isEmpty
            },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [storeLoaded], timeout: 5), .completed)

        let authenticationRepository = AuthenticationRepository(
            apiClient: apiClient,
            databaseContainer: database,
            connectionRepository: connectionRepository,
            tokenExpirationRetryStrategy: DefaultRetryStrategy(),
            projectId: "project-1",
            timerType: DefaultTimer.self
        )
        return (authenticationRepository, connectionRepository)
    }
}
