//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// A type representing sticker pack. `StickerPack` is an immutable snapshot of a sticker pack entity at the given time.
///
public struct StickerPack: Hashable {
    public let id: String
    public let title: String
    public var stickers: [Sticker]
    public let orderIndex: Int

    public static var recentsPackId: String {
        return "Ermis-Recents-Pack"
    }

    public init(id: String, title: String, stickers: [Sticker], orderIndex: Int) {
        self.id = id
        self.title = title
        self.stickers = stickers
        self.orderIndex = orderIndex
    }

    public static func == (lhs: StickerPack, rhs: StickerPack) -> Bool {
        return lhs.id == rhs.id &&
        lhs.title == rhs.title &&
        lhs.orderIndex == rhs.orderIndex &&
        lhs.stickers.elementsEqual(rhs.stickers)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

