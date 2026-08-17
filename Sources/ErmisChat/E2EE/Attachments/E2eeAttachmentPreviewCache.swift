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
    static let maximumEntryCost = 4 * 1024 * 1024

    enum CacheError: Error {
        case invalidImage
        case decodedImageTooLarge
    }

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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(removeAll),
            name: UIApplication.didEnterBackgroundNotification,
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

    /// Stores compressed preview bytes while charging the cache for the memory required by the
    /// decoded bitmap. Charging `data.count` here substantially undercounts JPEG previews and can
    /// let a long Channel Info grid exceed its intended 24 MiB decoded-image budget.
    @discardableResult
    func insert(_ data: Data, for assetId: String) throws -> String {
        guard let decodedCost = Self.decodedCost(for: data) else {
            throw CacheError.invalidImage
        }
        guard decodedCost <= Self.maximumEntryCost else {
            throw CacheError.decodedImageTooLarge
        }
        let entry = Entry(data: data)
        cache.setObject(entry, forKey: assetId as NSString, cost: decodedCost)
        return entry.generation
    }

    static func decodedCost(for data: Data) -> Int? {
#if canImport(UIKit)
        guard let image = UIImage(data: data), let cgImage = image.cgImage else { return nil }
        let bytesPerRow = cgImage.bytesPerRow > 0 ? cgImage.bytesPerRow : cgImage.width * 4
        let (cost, overflow) = bytesPerRow.multipliedReportingOverflow(by: cgImage.height)
        return overflow ? nil : cost
#else
        return nil
#endif
    }

    @objc private func removeAll() {
        cache.removeAllObjects()
    }
}
