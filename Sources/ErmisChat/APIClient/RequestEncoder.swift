//
// Copyright 2025 Ermis Inc.
//

import Foundation
import ErmisShared

/// The protocol which creating a `URLRequest`, and encoding all required and `Endpoint` specific data to it.
protocol RequestEncoder {
    /// A delegate the encoder uses for obtaining the current `connectionId`.
    ///
    /// Trying to encode an `Endpoint` with the `needConnectionId` set to `true` without setting the delegate
    var connectionProviderDelegate: ConnectionProviderDelegate? { get set }

    /// Asynchronously creates a new `URLRequest` with the data from the `Endpoint`. It also adds all required data
    /// like an api key, etc.
    ///
    /// - Parameters:
    ///   - endpoint: The `Endpoint` to be encoded.
    ///   - completion: Called when the encoded `URLRequest` is ready. Called with en `Error` if the encoding fails.
    func encodeRequest<ResponsePayload: Decodable>(
        for endpoint: Endpoint<ResponsePayload>,
        completion: @escaping (Result<URLRequest, Error>) -> Void
    )

    /// Creates a new `RequestEncoder`.
    ///
    /// - Parameters:
    ///   - baseURL: The base URL for all normal requests.
    ///   - authURL: The base URL for authentication requests.
    ///   - stickerURL: The base URL for sticker requests.
    ///   - apiKey: The app specific API key.
    init(baseURL: URL, authURL: URL, stickerURL: URL, apiKey: APIKey)

    var baseURL: URL { get }
    var authURL: URL { get }
    var stickerURL: URL { get }
}

extension RequestEncoder {
    /// Synchronously creates a new `URLRequest` with the data from the `Endpoint`. It also adds all required data
    /// like an api key, etc.
    ///
    /// - Warning: ⚠️ This method shouldn't be called for endpoints with `needConnectionId == true` because they
    /// require an async call to obtain `connectionId`. Use the asynchronous variant of this function instead.
    ///
    /// - Parameter endpoint: The `Endpoint` to be encoded.
    func encodeRequest<ResponsePayload: Decodable>(for endpoint: Endpoint<ResponsePayload>) throws -> URLRequest {
        log.assert(
            !endpoint.needConnectionId,
            "Use the asynchronous version of `encodeRequest` for endpoints with `requiresConnectionId` set to `true.`",
            subsystems: .httpRequests
        )

        var result: Result<URLRequest, Error> = .failure(
            ClientError("Unexpected error. The result was not changed after encoding the request.")
        )

        let dispatchGroup = DispatchGroup()
        dispatchGroup.enter()
        encodeRequest(for: endpoint) {
            result = $0
            dispatchGroup.leave()
        }

        let waitResult = dispatchGroup.wait(timeout: .now() + returningResultTimeout)
        if waitResult == .timedOut {
            result = .failure(ClientError("Encoding request timed out. Endpoint: \(endpoint)"))
        }

        return try result.get()
    }

    private var returningResultTimeout: TimeInterval {
        5
    }
}

/// The default implementation of `RequestEncoder`.
class DefaultRequestEncoder: RequestEncoder {
    let baseURL: URL
    let authURL: URL
    let stickerURL: URL
    let apiKey: APIKey

    /// Timeout when waiting for token or connectionId
    private let waiterTimeout: TimeInterval = 10
    weak var connectionProviderDelegate: ConnectionProviderDelegate?

    func encodeRequest<ResponsePayload: Decodable>(
        for endpoint: Endpoint<ResponsePayload>,
        completion: @escaping (Result<URLRequest, Error>) -> Void
    ) {
        var request: URLRequest
        do {
            // Prepare the URL
            var url = try encodeRequestURL(for: endpoint)
            url = try url.appendingQueryItems(["api_key": apiKey.apiKeyString])

            // Create a request
            request = URLRequest(url: url)
            request.httpMethod = endpoint.method.rawValue
            request.addValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")

            switch endpoint.path {
            case .users, .updateUsers:
                break
            case .subscribe:
                /// SSE request
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
            default:
                request.addValue("gzip, deflate, br", forHTTPHeaderField: "Content-Encoding")
                request.addValue("gzip", forHTTPHeaderField: "Accept-Encoding")
            }
            request.addValue("keep-alive", forHTTPHeaderField: "Connection")
            if case .stickerPacks = endpoint.path {
                request.cachePolicy = .reloadIgnoringLocalCacheData
            }
            // Encode endpoint-specific query items
            if let queryItems = endpoint.query {
                try encodeRequestQuery(with: queryItems, to: &request)
            }

            try encodeRequestBody(request: &request, endpoint: endpoint)
        } catch {
            completion(.failure(error))
            return
        }
        // Add authorazation header.
        addAuthorizationHeader(request: request, endpoint: endpoint) {
            switch $0 {
            case let .success(requestWithAuth):
                self.addConnectionIdIfNeeded(
                    request: requestWithAuth,
                    endpoint: endpoint,
                    completion: completion
                )
            case let .failure(error):
                completion(.failure(error))
            }
        }
    }

    required init(baseURL: URL, authURL: URL, stickerURL: URL, apiKey: APIKey) {
        self.baseURL = baseURL
        self.authURL = authURL
        self.stickerURL = stickerURL
        self.apiKey = apiKey
    }

    // MARK: - Private

    private func addAuthorizationHeader<T: Decodable>(
        request: URLRequest,
        endpoint: Endpoint<T>,
        completion: @escaping (Result<URLRequest, Error>) -> Void
    ) {
        guard endpoint.needToken else {
            let updatedRequest = request
            completion(.success(updatedRequest))
            return
        }

        log.assert(
            connectionProviderDelegate != nil,
            "The endpoint need `token` but `connectionProviderDelegate` is nil.",
            subsystems: .httpRequests
        )

        let missingTokenError = ClientError.MissingToken("Failed to get `token` -> request can't be created.")

        connectionProviderDelegate?.provideToken(timeout: waiterTimeout) {
            switch $0 {
            case let .success(token):
                var updatedRequest = request

                updatedRequest.setHTTPHeaders(.authorization("Bearer " + token.rawValue))
                if let url = try? updatedRequest.url?.appendingQueryItems(["user_id" : token.userId]) {
                    updatedRequest.url = url
                }
                completion(.success(updatedRequest))
            case let .failure(error as ClientError.WaiterTimeout):
                // The receiver will treat a waiter timeout differently than the other ones, and that's why we are not
                // masking it under missing token. The receiver should retry based on their own logic
                completion(.failure(error))
            case .failure:
                completion(.failure(missingTokenError))
            }
        }
    }
    /// Add `connectionId` to request if `needConnectionId` = true
    private func addConnectionIdIfNeeded<T: Decodable>(
        request: URLRequest,
        endpoint: Endpoint<T>,
        completion: @escaping (Result<URLRequest, Error>) -> Void
    ) {
        guard endpoint.needConnectionId else {
            completion(.success(request))
            return
        }
        log.assert(
            connectionProviderDelegate != nil,
            "The endpoint need `connectionId` but `connectionProviderDelegate` is nil.",
            subsystems: .httpRequests
        )

        let missingConnectionIdError = ClientError.MissingConnectionId(
            "Failed to get `connectionId` -> request can't be created."
        )

        connectionProviderDelegate?.provideConnectionId(timeout: waiterTimeout) {
            do {
                switch $0 {
                case let .success(connectionId):
                    var updatedRequest = request
                    updatedRequest.url = try updatedRequest.url?.appendingQueryItems(["connection_id": connectionId])
                    completion(.success(updatedRequest))
                case let .failure(error as ClientError.WaiterTimeout):
                    // The receiver will treat a waiter timeout differently than the other ones, and that's why we are not
                    // masking it under missing token. The receiver should retry based on their own logic
                    throw error
                case .failure:
                    throw missingConnectionIdError
                }
            } catch {
                completion(.failure(error))
            }
        }
    }
    /// Create request URL from endpoint.
    private func encodeRequestURL<T: Decodable>(for endpoint: Endpoint<T>) throws -> URL {
        var urlComponents = URLComponents()

        switch endpoint.urlType {
        case .auth:
            urlComponents.scheme = authURL.scheme
            urlComponents.host = authURL.host
            urlComponents.port = authURL.port
        case .normal:
            urlComponents.scheme = baseURL.scheme
            urlComponents.host = baseURL.host
            urlComponents.port = baseURL.port
        case .sticker:
            urlComponents.scheme = stickerURL.scheme
            urlComponents.host = stickerURL.host
            urlComponents.port = stickerURL.port
        }

        guard var url = urlComponents.url else {
            throw ClientError.InvalidURL("URL can't be created using components: \(urlComponents)")
        }

        url = url.appendingPathComponent(endpoint.path.value)
        return url
    }
    
    private func encodeRequestBody<T: Decodable>(request: inout URLRequest, endpoint: Endpoint<T>) throws {
        switch endpoint.method {
        case .get:
            guard let body = endpoint.body else { return }
            try encodeRequestQuery(with: body, to: &request)
        case .post, .patch, .delete:
            if let data = endpoint.body as? Data {
                request.httpBody = data
            } else {
                let body = try JSONEncoder.ermis.encode(AnyEncodable(endpoint.body ?? EmptyBody()))
                request.httpBody = body
            }
        }
    }

    private func encodeRequestQuery(with query: Encodable, to request: inout URLRequest) throws {
        let data = try (query as? Data) ?? JSONEncoder.ermis.encode(AnyEncodable(query))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClientError.InvalidJSON("Data is not a valid JSON: \(String(data: data, encoding: .utf8) ?? "nil")")
        }

        let bodyQueryItems = json.compactMap { (key, value) -> URLQueryItem? in
            // If the `value` is a JSON, encode it like that
            if let jsonValue = value as? [String: Any] {
                do {
                    let jsonStringValue = try JSONSerialization.data(withJSONObject: jsonValue)
                    return URLQueryItem(name: key, value: String(data: jsonStringValue, encoding: .utf8))
                } catch {
                    log.error(
                        "Skipping encoding data for key:`\(key)` because it's not a valid JSON: "
                        + "\(String(data: data, encoding: .utf8) ?? "nil")", subsystems: .httpRequests
                    )
                }
            }

            return URLQueryItem(name: key, value: String(describing: value))
        }

        log.assert(request.url != nil, "Request URL must not be `nil`.", subsystems: .httpRequests)

        request.url = try request.url!.appendingQueryItems(bodyQueryItems)
    }
}

private extension URL {
    func appendingQueryItems(_ items: [String: String]) throws -> URL {
        let queryItems = items.map { URLQueryItem(name: $0.key, value: $0.value) }
        return try appendingQueryItems(queryItems)
    }

    func appendingQueryItems(_ items: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            throw ClientError.InvalidURL("Can't create `URLComponents` from the url: \(self).")
        }
        let existingQueryItems = components.queryItems ?? []
        components.queryItems = existingQueryItems + items

        // Manually replace all occurrences of "+" in the query because it can be understood as a placeholder
        // value for a space. We want to keep it as "+" so we have to manually percent-encode it.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")

        guard let newURL = components.url else {
            throw ClientError.InvalidURL("Can't create a new `URL` after appending query items: \(items).")
        }
        return newURL
    }
}

typealias WaiterToken = String
protocol ConnectionProviderDelegate: AnyObject {
    func provideConnectionId(timeout: TimeInterval, completion: @escaping (Result<ConnectionId, Error>) -> Void)
    func provideToken(timeout: TimeInterval, completion: @escaping (Result<Token, Error>) -> Void)
}

extension ClientError {
    class InvalidURL: ClientError {}
    class InvalidJSON: ClientError {}
    class MissingConnectionId: ClientError {}
}
