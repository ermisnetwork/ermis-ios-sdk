import Foundation

public extension ClientError {
    /// Reauthentication is needed when a returning session has no refresh credential.
    final class MissingRefreshToken: ClientError, @unchecked Sendable {
        public init() { super.init("The saved session cannot be renewed. Please sign in again.") }
    }
}

/// Fixed categories and bounded codes only. Never projects token values, error messages or URLs.
enum ErmisAuthenticationDiagnostics {
    static func marker(for error: Error) -> String {
        var candidate = error
        for _ in 0..<6 {
            if candidate is ClientError.ExpiredToken {
                return "mls_auth_failure category=api http_status=401 code=0"
            }
            if let api = candidate as? ErmisApiError {
                let status = (100...599).contains(api.httpStatusCode) ? api.httpStatusCode : 0
                let code = (-999999...999999).contains(api.code) ? api.code : 0
                return "mls_auth_failure category=api http_status=\(status) code=\(code)"
            }
            let nsError = candidate as NSError
            if nsError.domain == NSURLErrorDomain {
                let category = nsError.code == URLError.notConnectedToInternet.rawValue ? "offline" : "transport"
                let code = (-999999...999999).contains(nsError.code) ? nsError.code : 0
                return "mls_auth_failure category=\(category) http_status=0 code=\(code)"
            }
            guard let wrapped = candidate as? ClientError, let underlying = wrapped.underlyingError else { break }
            candidate = underlying
        }
        return "mls_auth_failure category=other http_status=0 code=0"
    }

    /// Classify the public login response without projecting arbitrary server strings.
    static func googleResponseMarker(data: Data?, response: URLResponse?, error: Error?) -> String {
        let rawStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
        let status = (100...599).contains(rawStatus) ? rawStatus : 0
        var reason = error == nil ? "unclassified" : "transport"
        if error == nil, let data, data.count <= 65536,
           let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let detail = body["error"] as? [String: Any] ?? body
            let message = detail["message"] as? String
            switch message {
            case "Invalid apikey!": reason = "invalid_api_key"
            case "InvalidAudience", "Invalid audience": reason = "invalid_audience"
            case "Settings not found": reason = "settings_missing"
            case "Json parse error": reason = "settings_invalid"
            case "This account is not allowed!": reason = "account_not_allowed"
            default:
                if status == 200, body["token"] is String, body["user_id"] is String {
                    reason = "auth_payload_present"
                }
            }
        }
        return "uhm_auth phase=google_http result=response http_status=\(status) reason=\(reason)"
    }
}
