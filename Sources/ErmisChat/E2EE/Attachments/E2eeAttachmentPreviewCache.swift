//
// Copyright 2026 Ermis Inc.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Process-local plaintext preview cache. Decrypted previews must not be written to Core Data or
/// another persistent cache; they are rebuilt from the encrypted R2 asset after relaunch.
final class E2eeAttachmentPreviewCache {
    static let shared = E2eeAttachmentPreviewCache()

    static let totalCostLimit = 24 * 1024 * 1024
    static let countLimit = 32

    private final class Entry: NSObject {
        let data: NSData
        let generation: String

        init(data: Data) {
            self.data = data as NSData
            generation = UUID().uuidString
        }
    }

    private let cache = NSCache<NSString, Entry>()

    private init() {
        cache.totalCostLimit = Self.totalCostLimit
        cache.countLimit = Self.countLimit
#if canImport(UIKit)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(removeAll),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
#endif
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func data(for assetId: String) -> Data? {
        value(for: assetId)?.data
    }

    func value(for assetId: String) -> (data: Data, generation: String)? {
        guard let entry = cache.object(forKey: assetId as NSString) else { return nil }
        return (Data(referencing: entry.data), entry.generation)
    }

    @discardableResult
    func insert(_ data: Data, for assetId: String) -> String {
        let entry = Entry(data: data)
        cache.setObject(entry, forKey: assetId as NSString, cost: data.count)
        return entry.generation
    }

    @objc private func removeAll() {
        cache.removeAllObjects()
    }
}
