//
// Copyright 2025 Ermis Inc.
//

import Foundation
import zlib
import ImageIO
import UIKit
import MobileCoreServices
import ErmisShared

/// A final class that holds the context for the ongoing operations during the sync process
final class SyncContext {
    let lastSyncAt: Date
    var localChannelIds: [ChannelId] = []
    var synchedChannelIds: Set<ChannelId> = Set()
    var watchedAndSynchedChannelIds: Set<ChannelId> = Set()
    var unwantedChannelIds: Set<ChannelId> = Set()

    init(lastSyncAt: Date) {
        self.lastSyncAt = lastSyncAt
    }
}

private let syncOperationsMaximumRetries = 2


final class WatchChannelOperation: AsyncOperation {
    init(controller: ChannelController, context: SyncContext) {
        super.init(maxRetries: syncOperationsMaximumRetries) { [weak controller] _, done in
            guard let controller = controller, controller.canBeRecovered else {
                done(.continue)
                return
            }

            let cidString = (controller.cid?.rawValue ?? "unknown")
            log.info("2. Watching active channel \(cidString)", subsystems: .offlineSupport)
            controller.recoverWatchedChannel { error in
                if let cid = controller.cid, error == nil {
                    log.info("Successfully watched active channel \(cidString)", subsystems: .offlineSupport)
                    context.watchedAndSynchedChannelIds.insert(cid)
                    done(.continue)
                } else {
                    let errorMessage = error?.localizedDescription ?? "missing cid"
                    log.error("Failed watching active channel \(cidString): \(errorMessage)", subsystems: .offlineSupport)
                    done(.retry)
                }
            }
        }
    }
}

final class RefetchChannelListQueryOperation: AsyncOperation {
    init(controller: ChannelListController, context: SyncContext) {
        super.init(maxRetries: syncOperationsMaximumRetries) { [weak controller] _, done in
            guard let controller = controller, controller.canBeRecovered else {
                done(.continue)
                return
            }

            let query = controller.query
            log.info("3 & 4. Refetching channel lists queries & Cleaning up local message history", subsystems: .offlineSupport)
            controller.resetQuery(
                watchedAndSynchedChannelIds: context.watchedAndSynchedChannelIds,
                synchedChannelIds: context.synchedChannelIds
            ) { result in
                switch result {
                case let .success((watchedChannels, unwantedCids)):
                    log.info("Successfully refetched query for \(query.debugDescription)", subsystems: .offlineSupport)
                    let queryChannelIds = watchedChannels.map(\.cid)
                    context.watchedAndSynchedChannelIds = context.watchedAndSynchedChannelIds.union(queryChannelIds)
                    context.unwantedChannelIds = context.unwantedChannelIds.union(unwantedCids)
                    done(.continue)
                case let .failure(error):
                    log.error(
                        "Failed refetching query for \(query.debugDescription): \(error)",
                        subsystems: .offlineSupport
                    )
                    done(.retry)
                }
            }
        }
    }
}

final class DeleteUnwantedChannelsOperation: AsyncOperation {
    init(database: DatabaseContainer, context: SyncContext) {
        super.init(maxRetries: syncOperationsMaximumRetries) { [weak database] _, done in
            log.info("4. Clean up unwanted channels", subsystems: .offlineSupport)

            guard let database = database, !context.unwantedChannelIds.isEmpty else {
                done(.continue)
                return
            }

            // We are going to remove those channels that are not present in remote queries, and that have not
            // been watched.
            database.write { session in
                // We remove watchedAndSynched from unwantedChannels because it might happen that a channel marked
                // as unwanted in one query, might still be needed in another query (scenario where multiple queries
                // are active at the same time).
                let idsToRemove = context.unwantedChannelIds.subtracting(context.watchedAndSynchedChannelIds)
                session.removeChannels(cids: idsToRemove)
            } completion: { error in
                if let error = error {
                    log.error(
                        "Failed removing unwanted channels: \(error)",
                        subsystems: .offlineSupport
                    )
                    done(.retry)
                } else {
                    done(.continue)
                }
            }
        }
    }
}

final class ExecutePendingOfflineActions: AsyncOperation {
    init(offlineRequestsRepository: OfflineRequestsRepository) {
        super.init(maxRetries: syncOperationsMaximumRetries) { [weak offlineRequestsRepository] _, done in
            log.info("5. Running offline actions requests", subsystems: .offlineSupport)
            offlineRequestsRepository?.runQueuedRequests {
                done(.continue)
            }
        }
    }
}

// An operation to get sticker pack infomation.
final class GetStickerPackOperation: BaseOperation, @unchecked Sendable {
    override var queueLabel: String {
        return "network.ermis.get-sticker-pack-operation"
    }

    let packName: String
    let packIndex: Int
    let apiClient: APIClient
    let database: DatabaseContainer
    let queue: OperationQueue
    let completion: (Result<StickerPackPayload, Error>) -> Void

    init(packName: String, packIndex: Int, apiClient: APIClient, database: DatabaseContainer, queue: OperationQueue, completion: @escaping (Result<StickerPackPayload, Error>) -> Void) {
        self.packName = packName
        self.packIndex = packIndex
        self.apiClient = apiClient
        self.database = database
        self.queue = queue
        self.completion = completion
    }

    override func start() {
        if isCancelled {
            isFinished = true
            return
        }
        isExecuting = true
        main()
    }

    override func main() {
        apiClient.request(endpoint: .stickerPackDetail(of: packName), completion: { [weak self] result in
            guard let self else {
                return
            }
            switch result {
            case .success(let payload):
                // Fetch data for all sticker.
                self.getStickersData(in: payload) { [weak self] updatedPayload in
                    guard let self else {
                        return
                    }
                    // Save final sticker pack version
                    self.database.write { session in
                        session.saveStickerPacks(payload: updatedPayload, at: self.packIndex)
                    } completion: { [weak self] error in
                        if let error = error {
                            self?.completion(.failure(error))
                        } else {
                            self?.completion(.success(updatedPayload))
                        }
                        self?.isFinished = true
                    }
                }
                // Save sticker pack version don't have sticker data first.
                self.database.write { session in
                    var updatedPack = payload
                    let baseURL = self.apiClient.encoder.stickerURL

                    for (index, sticker) in payload.stickers.enumerated() {
                        updatedPack.stickers[index].url = "\(baseURL)/\(sticker.url ?? "")"
                    }
                    session.saveStickerPacks(payload: updatedPack, at: self.packIndex)
                }
            case .failure(let error):
                self.completion(result)
                self.isFinished = true
            }
        })
    }
    // get sticker data inside a pack.
    final func getStickersData(in payload: StickerPackPayload, completion: @escaping (StickerPackPayload) -> Void) {
        var stickerPack = payload
        let operations = payload.stickers.enumerated().map { (index, sticker) in
            return GetStickerOperation(path: sticker.url ?? "", apiClient: apiClient) { [weak self] result in
                guard let self else {
                    return
                }
                switch result {
                case .success(let data):
                    // Update sticker url
                    let baseURL = self.apiClient.encoder.stickerURL
                    stickerPack.stickers[index].url = "\(baseURL)/\(sticker.url ?? "")"
                    if sticker.url?.hasSuffix(".tgs") == true {
                        stickerPack.stickers[index].data = gunzip(data: data)
                    } else {
                        stickerPack.stickers[index].data = downSampleImageData(data)
                    }
                case .failure(let error):
                    log.debug("[Sync] get sticker with id: \(sticker.id) failed with error: \(error)")
                }
            }
        }

        let completionOperation = BlockOperation {
            self.completion(.success(stickerPack))
            self.isFinished = true
        }

        for operation in operations {
            completionOperation.addDependency(operation)
        }

        queue.addOperations(operations, waitUntilFinished: false)
        queue.addOperation(completionOperation)
    }

    /// Uncompressed data of a `.tgs` file.
    /// - Parameter data: The `.tgs` file data.
    /// - Returns: The uncompressed data.
    func gunzip(data: Data) -> Data? {
        guard data.count > 0 else { return nil }
        var stream = z_stream()
        var status: Int32
        status = inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        var decompressed = Data()
        return data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) -> Data? in
            guard let srcPtr = rawBuffer.baseAddress?.assumingMemoryBound(to: Bytef.self) else { return nil }
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: srcPtr)
            stream.avail_in = uint(data.count)
            let bufferSize = 64 * 1024
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            repeat {
                stream.next_out = buffer
                stream.avail_out = uInt(bufferSize)
                status = inflate(&stream, Z_NO_FLUSH)
                let have = bufferSize - Int(stream.avail_out)
                if have > 0 {
                    decompressed.append(buffer, count: have)
                }
            } while status == Z_OK
            return status == Z_STREAM_END ? decompressed : nil
        }
    }

    /// Reduces the image size by downsampling the given data.
    /// - Parameter data: The image data to downsample.
    /// - Returns: The downsampled image data.
    private func downSampleImageData(_ data: Data) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false
        ]

        guard let source =  CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
            return nil
        }

        let scaleFactor = UIScreen.main.scale
        let dimention = 50 * scaleFactor
        let downsampledOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: dimention
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampledOptions as CFDictionary) else {
            return nil
        }

        return imageData(from: cgImage)
    }

    private func imageData(from cgImage: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, kUTTypePNG, 1, nil) else {
            return nil
        }

        let options: CFDictionary = [
            kCGImageDestinationLossyCompressionQuality: 0.5
        ] as CFDictionary

        CGImageDestinationAddImage(destination, cgImage, nil)

        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return data as? Data
    }
}
// An operation to get Sticker's Data.
final class GetStickerOperation: BaseOperation, @unchecked Sendable {
    override var queueLabel: String {
        return "network.ermis.get-sticker-operation"
    }

    let path: String
    let apiClient: APIClient
    let completion: (Result<Data, Error>) -> Void

    init(path: String, apiClient: APIClient, completion: @escaping (Result<Data, Error>) -> Void) {
        self.path = path
        self.apiClient = apiClient
        self.completion = completion
    }

    override func start() {
        if isCancelled {
            isFinished = true
            return
        }
        isExecuting = true
        main()
    }

    override func main() {
        apiClient.request(endpoint: .stickerData(path: path), completion: { [weak self] result in
            self?.completion(result)
            self?.isFinished = true
        })
    }
}
