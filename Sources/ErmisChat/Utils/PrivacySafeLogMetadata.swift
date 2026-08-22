//
// Copyright 2026 Ermis Inc.
//

import Foundation

/// Bounded metadata for diagnostics that can reach device, TestFlight, or host-app logs.
///
/// Never pass identifiers, URLs, request/response bodies, tokens, filenames, paths, or localized
/// error descriptions through this type. Unknown error domains are deliberately collapsed because
/// `NSError.domain` is caller-controlled and can itself contain sensitive data.
enum PrivacySafeLogMetadata {
    static func errorFields(_ error: Error) -> String {
        let nsError = error as NSError
        var fields = [
            "error_type=\(safeTypeName(error))",
            "error_domain=\(safeDomain(nsError.domain))",
            "error_code=\(nsError.code)",
        ]

        if let apiError = error as? ErmisApiError {
            fields.append("http_status=\(apiError.httpStatusCode)")
            fields.append("api_code=\(apiError.code)")
        }

        return fields.joined(separator: " ")
    }

    private static func safeTypeName(_ error: Error) -> String {
        let reflected = String(reflecting: type(of: error))
        let component = reflected.split(separator: ".").last.map(String.init) ?? "Error"
        return boundedToken(component)
    }

    private static func safeDomain(_ domain: String) -> String {
        switch domain {
        case NSURLErrorDomain:
            return "url_session"
        case NSCocoaErrorDomain:
            return "cocoa"
        case NSPOSIXErrorDomain:
            return "posix"
        case NSMachErrorDomain:
            return "mach"
        case NSOSStatusErrorDomain:
            return "os_status"
        default:
            return "other"
        }
    }

    private static func boundedToken(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let token = String(value.unicodeScalars.prefix(64).map {
            allowed.contains($0) ? Character(String($0)) : "_"
        })
        return token.isEmpty ? "unknown" : token
    }
}
