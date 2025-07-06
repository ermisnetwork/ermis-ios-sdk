//
// Copyright 2025 Ermis Inc.
//

import Foundation

extension Endpoint {
    /// Create the endpoint to delete file in a channel.
    ///
    /// - Parameters:
    ///   - cid: The channel identifier.
    ///   - url: The file's url to delete.
    /// - Returns: The endpoint to delete file in a channel.
    static func deleteFile(cid: ChannelId, url: String) -> Endpoint<EmptyResponse> {
        .init(
            path: .deleteFile(cid.apiPath),
            method: .delete,
            query: ["url": url]
        )
    }

    /// Create the endpoint to delete image in a channel.
    ///
    /// - Parameters:
    ///   - cid: The channel identifier.
    ///   - url: The image's url to delete.
    /// - Returns: The endpoint to delete image in a channel.
    static func deleteImage(cid: ChannelId, url: String) -> Endpoint<EmptyResponse> {
        .init(
            path: .deleteImage(cid.apiPath),
            method: .delete,
            query: ["url": url]
        )
    }
}
