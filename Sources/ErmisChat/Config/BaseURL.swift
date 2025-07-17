//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// A struct representing base URL for `ErmisClient`.
public struct BaseURL: CustomStringConvertible {
    public static let product = BaseURL(baseURLString: "https://api.ermis.network",
                                        authURLString: "https://api.ermis.network")!

    public static let staging = BaseURL(baseURLString: "https://api-staging.ermis.network",
                                        authURLString: "https://api-staging.ermis.network")!

    public static let dev = BaseURL(baseURLString: "https://api-dev.ermis.network",
                                    authURLString: "https://api-dev.ermis.network")!

    public static let `internal` = BaseURL(baseURLString: "https://api-internal.ermis.network",
                                           authURLString: "https://api-internal.ermis.network")!

    public static let uhm = BaseURL(baseURLString: "https://api-trieve.ermis.network",
                                    authURLString: "https://api-trieve.ermis.network")!
//    public static let uhm = BaseURL(urlString: "https://tuan-dev.bandia.vn")!


    let restAPIBaseURL: URL
    let authAPIBaseURL: URL
    let webSocketBaseURL: URL

    public var description: String { restAPIBaseURL.absoluteString }

    /// Create a base URL from an URL string.
    ///
    /// - Parameter urlString: a Ermis Chat server location url string.
    public init?(baseURLString: String, authURLString: String) {
        guard let baseURL = URL(string: baseURLString),
              let authURL = URL(string: authURLString) else { return nil }
        self.init(baseURL: baseURL, authURL: authURL)
    }

    /// Init with a custom server URL.
    ///
    /// - Parameter url: an URL
    public init(baseURL: URL, authURL: URL? = nil, wsURL: URL? = nil) {
        var urlString = baseURL.absoluteString

        // Remove a scheme prefix.
        for prefix in ["https:", "http:", "wss:", "ws:"] {
            if urlString.hasPrefix(prefix) {
                urlString = String(urlString.suffix(urlString.count - prefix.count))
                break
            }
        }

        urlString = urlString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        let scheme = "https"
        restAPIBaseURL = URL(string: "\(scheme)://\(urlString)/")!
        authAPIBaseURL = authURL ?? restAPIBaseURL
        webSocketBaseURL = wsURL ?? URL(string: "wss" + "://\(urlString)/")!
    }
}
