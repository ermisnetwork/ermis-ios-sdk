//
// Copyright 2025 Ermis Inc.
//

import Foundation

public struct EndpointEnviroment {
    public var baseURL: URL
    public var authURL: URL
    public var webSocketURL: URL

    /// Create a base EndpointEnviroment from an URLs string.
    ///
    /// - Parameter baseURLString: a Ermis Chat server location url string.
    /// - Parameter authURLString: an optional authentication API URL string, defaults to the base URL.
    ///
    public init?(baseURLString: String, authURLString: String) {
        guard let baseURL = URL(string: baseURLString),
              let authURL = URL(string: authURLString) else { return nil }
        self.init(baseURL: baseURL, authURL: authURL)
    }

    /// Init with a custom server URL.
    ///
    /// - Parameter baseURL: an URL
    /// - Parameter authURL: an optional URL for the authentication API, defaults to the b ase URL.
    /// - Parameter wsURL: an optional URL for the WebSocket API, defaults to a WebSocket URL based on the base URL.
    ///
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
        self.baseURL = URL(string: "\(scheme)://\(urlString)/")!
        self.authURL = authURL ?? baseURL
        self.webSocketURL = wsURL ?? URL(string: "wss" + "://\(urlString)/")!
    }
}
