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
}
