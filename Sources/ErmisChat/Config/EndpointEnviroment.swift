//
// Copyright 2025 Ermis Inc.
//

import Foundation

public struct EndpointEnviroment {
    public var baseURL: URL
    public var authURL: URL
    public var stickerURL: URL
    public var webSocketURL: URL

    /// Create a base EndpointEnviroment from an URLs string.
    ///
    /// - Parameters:
    ///  - baseURLString: an Ermis Chat server location url string.
    ///  - authURLString: an authentication API URL string, defaults to the base URL.
    ///  - stickerURL: a sticker location url string.
    ///
    public init?(baseURLString: String, authURLString: String, stickerURLString: String) {
        guard let baseURL = URL(string: baseURLString),
              let authURL = URL(string: authURLString),
              let stickerURL = URL(string: stickerURLString) else { return nil }
        self.init(baseURL: baseURL, authURL: authURL, stickerURL: stickerURL)
    }

    /// Init with a custom server URL.
    ///
    /// - Parameters:
    ///  - baseURL: an URL
    ///  - authURL: an optional URL for the authentication API, defaults to the base URL.
    ///  - stickerURL: an option URL for the sticker api
    ///  - wsURL: an optional URL for the WebSocket API, defaults to a WebSocket URL based on the base URL.
    ///
    public init(baseURL: URL, authURL: URL? = nil, stickerURL: URL? = nil, wsURL: URL? = nil) {
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
        self.stickerURL = stickerURL ?? URL(string: "https://sticker.ermis.network")!
        self.webSocketURL = wsURL ?? URL(string: "wss" + "://\(urlString)/")!
    }
}
