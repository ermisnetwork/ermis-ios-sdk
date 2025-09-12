//
// Copyright 2025 Ermis Inc.
//

import Foundation
import UIKit

/// A type representing sticker. `Sticker` is an immutable snapshot of a sticker entity at the given time.
///
public struct Sticker: Hashable {
    public let id: String
    public let url: String?
    public let body: String?
    public let data: Data?
    public var image: UIImage?

    public init(id: String, url: String?, body: String?, data: Data?) {
        self.id = id
        self.url = url
        self.body = body
        if let data, let url, !url.hasSuffix(".tgs") {
            self.image = UIImage(data: data)
            self.data = nil
        } else {
            self.data = data
        }
    }

    public static func == (lhs: Sticker, rhs: Sticker) -> Bool {
        return lhs.id == rhs.id &&
        lhs.url == rhs.url &&
        lhs.body == rhs.body
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}


