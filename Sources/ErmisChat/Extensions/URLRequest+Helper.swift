//
// Copyright 2025 Ermis Inc.
//

import Foundation

enum URLRequestDiagnosticState: String {
    case started
    case resumed
    case succeeded
    case failed
}

private let privacySafeHTTPMethods: Set<String> = [
    "DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"
]

extension URLRequest {
    /// A bounded request summary safe for production diagnostics.
    ///
    /// Deliberately omits the URL, query, headers, body, response, and raw error. Those fields can
    /// contain credentials, presigned storage grants, push tokens, and user/content identifiers.
    func privacySafeDiagnosticSummary(state: URLRequestDiagnosticState) -> String {
        let normalizedMethod = httpMethod?.uppercased() ?? "UNKNOWN"
        let method = privacySafeHTTPMethods.contains(normalizedMethod) ? normalizedMethod : "OTHER"
        return "[API_REQUEST] state=\(state.rawValue) method=\(method)"
    }
}

public
extension URLRequest {
    func cURL(pretty: Bool = false) -> String {
        let newLine = pretty ? "\\\n" : ""
        let method = (pretty ? "--request " : "-X ") + "\(self.httpMethod ?? "GET") \(newLine)"
        let url: String = (pretty ? "--url " : "") + "\'\(self.url?.absoluteString ?? "")\' \(newLine)"
        var cURL = "curl "
        var header = ""
        var data: String = ""
        if let httpHeaders = self.allHTTPHeaderFields, httpHeaders.keys.count > 0 {
            for (key,value) in httpHeaders {
                header += (pretty ? "--header " : "-H ") + "\'\(key): \(value)\' \(newLine)"
            }
        }
        if let bodyData = self.httpBody, let bodyString = String(data: bodyData, encoding: .utf8),  !bodyString.isEmpty {
            data = "--data '\(bodyString)'"
        }

        cURL += method + url + header + data
        return cURL
    }
}
