//
// Copyright 2025 Ermis Inc.
//

import Foundation

extension Endpoint {
    /// Create the endpoint to get list of sticker pack name.
    ///
    /// - Returns: The endpoint to get list of sticker pack name.
    static func stickerPacks() -> Endpoint<StickerPackListPayload> {
        .init(
            path: .stickerPacks(packName: nil),
            method: .get,
            needConnectionId: false,
            needToken: false,
            urlType: .sticker
        )
    }

    /// Create the endpoint to get detail of sticker pack with given name.
    ///
    /// - Returns: The endpoint to get detail of sticker pack with given name.
    static func stickerPackDetail(of packName: String) -> Endpoint<StickerPackPayload> {
        .init(
            path: .stickerPacks(packName: packName),
            method: .get,
            needConnectionId: false,
            needToken: false,
            urlType: .sticker
        )
    }

    /// Create the endpoint to get detail of sticker at given path.
    ///
    /// - Returns: The endpoint to get detail of sticker at given path.
    static func stickerData(path: String) -> Endpoint<Data> {
        .init(
            path: .sticker(path: path),
            method: .get,
            needConnectionId: false,
            needToken: false,
            urlType: .sticker
        )
    }
}

