//
// Copyright 2025 Ermis Inc.
//

import Foundation
import ErmisShared

/// The protocol which decoding incoming URL request response.
protocol RequestDecoder {
    /// Decodes an incoming URL request response.
    ///
    /// - Parameters:
    ///   - data: The response data.
    ///   - response: The response object from the network.
    ///   - error: An error object returned by the data task.
    ///
    /// - Throws: An error if the decoding fails.
    func decodeRequestResponse<ResponseType: Decodable>(data: Data?, response: URLResponse?, error: Error?) throws -> ResponseType
    func decodeSSEMessage<ResponseType: Decodable>(message: String?) throws -> ResponseType
}

/// The default implementation of `RequestDecoder`.
struct DefaultRequestDecoder: RequestDecoder {
    func decodeRequestResponse<ResponseType: Decodable>(data: Data?, response: URLResponse?, error: Error?) throws -> ResponseType {
        // Handle the error
        if let error {
            switch (error as NSError).code {
            case NSURLErrorCancelled:
                log.info("The request was cancelled.", subsystems: .httpRequests)
            case NSURLErrorNetworkConnectionLost:
                log.info("The network connection was lost.", subsystems: .httpRequests)
            default:
                log.error("[API_REQUEST] state=transport_failed category=network", subsystems: .httpRequests)
            }

            throw error
        }

        guard var data = data else {
            throw ClientError.ResponseBodyEmpty()
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClientError.Unexpected("Expected an HTTP response.")
        }

//        log.debug("URL request response: \(httpResponse), data:\n\(data.debugPrettyPrintedJSON))", subsystems: .httpRequests)
        // Handler ermis api error.
        if let ermisErrorPayload = try? JSONDecoder.default.decode(ErmisErrorPayload.self, from: data) {
            let ermisApiError: ErmisApiError
            ermisApiError = ErmisApiError(payload: ermisErrorPayload,
                                          httpStatusCode: httpResponse.statusCode)
            if ermisApiError.isInvalidTokenError {
                log.info("Request failed because of an experied token.", subsystems: .httpRequests)
                throw ClientError.ExpiredToken()
            }
            
            log
                .error(
                    "[API_REQUEST] state=server_failed http_status=\(httpResponse.statusCode) api_code=\(ermisApiError.code)",
                    subsystems: .httpRequests
                )
            throw ClientError(with: ermisApiError)
        }

        // Handler http error.
        guard httpResponse.statusCode < 300 else {
            throw ErmisApiError.init(type: .unknown,
                                     statusCode: httpResponse.statusCode,
                                     message: "Http status code \(httpResponse.statusCode) is not valid.")
        }

        if let responseAsData = data as? ResponseType {
            return responseAsData
        }

        do {
            if data.isEmpty {
                data = try JSONEncoder.default.encode("{}")
            }
            let decodedPayload = try JSONDecoder.default.decode(ResponseType.self, from: data)
            return decodedPayload
        } catch {
            log.error("[API_REQUEST] state=decode_failed category=response_schema", subsystems: .httpRequests)
            throw error
        }
    }

    func decodeSSEMessage<ResponseType: Decodable>(message: String?) throws -> ResponseType {
        guard let message = message, let data = message.data(using: .utf8) else {
            throw ClientError.ResponseBodyEmpty()
        }

        do {
            let decodedPayload = try JSONDecoder.default.decode(ResponseType.self, from: data)
            return decodedPayload
        } catch {
            log.error("[API_REQUEST] state=decode_failed category=sse_schema", subsystems: .httpRequests)
            throw error
        }
    }
}

public extension ClientError {
    class ExpiredToken: ClientError {}
    class RefreshingToken: ClientError {}
    class TokenRefreshed: ClientError {}
    class TokenRefreshRetryLimitExceeded: ClientError {
        public override var localizedDescription: String {
            "The server rejected the token after the maximum number of refresh attempts."
        }
    }
    class RefreshTokenExpired: ClientError {}
    class ConnectionError: ClientError {}
    class ResponseBodyEmpty: ClientError {
        public override var localizedDescription: String { "Response body is empty." }
    }

    static let temporaryErrors: Set<Int> = [
        NSURLErrorCancelled,
        NSURLErrorNetworkConnectionLost,
        NSURLErrorTimedOut,
        NSURLErrorCannotFindHost,
        NSURLErrorCannotConnectToHost,
        NSURLErrorNetworkConnectionLost,
        NSURLErrorDNSLookupFailed,
        NSURLErrorNotConnectedToInternet,
        NSURLErrorBadServerResponse,
        NSURLErrorUserCancelledAuthentication,
        NSURLErrorCannotLoadFromNetwork,
        NSURLErrorDataNotAllowed
    ]

    // returns true if the error is related to a temporary condition
    // you can use this to check if it makes sense to retry an API call
    static func isEphemeral(error: Error) -> Bool {
        if temporaryErrors.contains((error as NSError).code) {
            return true
        }

        if error.isRateLimitError {
            return true
        }

        return false
    }
}
