//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// A struct representing base URL for `ErmisClient`.
public struct BaseURL: CustomStringConvertible {
    public static let product = BaseURL(urlString: "https://api.ermis.network")!

    public static let staging = BaseURL(urlString: "https://api-staging.ermis.network")!

    public static let dev = BaseURL(urlString: "https://api-dev.ermis.network")!

    public static let `internal` = BaseURL(urlString: "https://api-internal.ermis.network")!

public static let uhm = BaseURL(urlString: "https://api-trieve.ermis.network")!
//    public static let uhm = BaseURL(urlString: "https://tuan-dev.bandia.vn")!


    let restAPIBaseURL: URL
    let webSocketBaseURL: URL

    public var description: String { restAPIBaseURL.absoluteString }

    /// Create a base URL from an URL string.
    ///
    /// - Parameter urlString: a Ermis Chat server location url string.
    init?(urlString: String) {
        guard let url = URL(string: urlString) else { return nil }
        self.init(url: url)
    }

    /// Init with a custom server URL.
    ///
    /// - Parameter url: an URL
    public init(url: URL) {
        var urlString = url.absoluteString

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
        webSocketBaseURL = URL(string: "wss" + "://\(urlString)/")!
    }
}
