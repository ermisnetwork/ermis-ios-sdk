//
// Copyright 2025 Ermis Inc.
//

import Foundation



/// This class is in charge of the synchronization of our local storage with the remote.
/// When executing a sync, it will remove outdated elements, and will refresh the content to always show the latest data.
class SyncRepository {
    private let config: ErmisClientConfig
    private let database: DatabaseContainer
    private let apiClient: APIClient

    private let syncStickerQueue = DispatchQueue(label: "network.ermis.sync-sticker-queue", qos: .unspecified)

    // Operation queue for fetching sticker packs.
    private lazy var fetchStickerPacksOperationQueue = {
        let operationQueue = OperationQueue()
        operationQueue.maxConcurrentOperationCount = 1
        operationQueue.qualityOfService = .default
        operationQueue.name = "network.ermis.fetch-sticker-pack"
        operationQueue.underlyingQueue = self.syncStickerQueue
        return operationQueue
    }()

    // Operation queue for fetching sticker pack.
    private lazy var fetchStickerPackDetailOperationQueue: OperationQueue = {
        let operationQueue = OperationQueue()
        operationQueue.maxConcurrentOperationCount = 5
        operationQueue.qualityOfService = .default
        operationQueue.name = "network.ermis.fetch-sticker"
        return operationQueue
    }()

    private var stickerPackList: StickerPackListPayload?
    // A boolean value that determines whether the sticker sync operation is in progress.
    // `true` if the sync operation is inprogress.
    private var isSyncingSticker: Bool = false
    // A boolean value that indicates whether the sticker has fully synced.
    // `true` if the sticker is fully synced
    private var hasSyncSticker: Bool = false

    let offlineRequestsRepository: OfflineRequestsRepository

    init(
        config: ErmisClientConfig,
        offlineRequestsRepository: OfflineRequestsRepository,
        database: DatabaseContainer,
        apiClient: APIClient
    ) {
        self.config = config
        self.offlineRequestsRepository = offlineRequestsRepository
        self.database = database
        self.apiClient = apiClient
    }

    deinit {
        apiClient.exitRecoveryMode()
    }

    func subscribe() {
        apiClient.sseRequest(endpoint: .subscribe(), completion: { [weak self] ssePayload, error in
            if let ssePayload, let userPayload = ssePayload.user {
                self?.database.write { session in
                    try? session.saveUser(payload: userPayload, projectId: userPayload.projectId)
                }
            }
        })
    }

    package func syncStickersIfNeeded() {
        guard !hasSyncSticker, !isSyncingSticker else {
            return
        }
        isSyncingSticker = true
        syncStickerQueue.sync {
            syncStickers()
        }
    }

    /// Sync with lastest version of all sticker packs.
    func syncStickers(completion: (() -> Void)? = nil) {
        apiClient.request(endpoint: .stickerPacks()) { [weak self] result in
            guard let self else {
                completion?()
                return
            }
            switch result {
            case .success(let stickerPackListPayload):
                self.stickerPackList = stickerPackListPayload

                self.database.write({ [weak self] session in
                    guard let self else { return }
                    do {
                        var stickerPacks = try session.getStickerPacks()
                        // Add recents pack if needed
                        if !stickerPacks.contains(where: { $0.id == StickerPack.recentsPackId}) {
                            let recentStickerPack = StickerPackPayload(id: StickerPack.recentsPackId, title: "Recents", stickers: [])
                            session.saveStickerPacks(payload: recentStickerPack, at: -1)
                        }

                        stickerPacks.removeAll(where: { $0.id == StickerPack.recentsPackId})
                        // Compare the new set with the old set to identify differences,
                        // then update using the new set.
                        let oldPackSet = Set(stickerPacks.map({ $0.id}))
                        let newPackSet = Set(stickerPackListPayload.packs)

                        let packsNeedToRemove = oldPackSet.subtracting(newPackSet)
                        var packsNeedToAdd = newPackSet.subtracting(oldPackSet)
                        let commonPacks = oldPackSet.intersection(newPackSet)
                        
                        if !packsNeedToRemove.isEmpty {
                            let removedPackDTOList = stickerPacks.filter({ pack in
                                return packsNeedToRemove.contains(pack.id)
                            })

                            for removedPackDTO in removedPackDTOList {
                                session.deleteStickerPack(removedPackDTO)
                            }
                        }

                        if !commonPacks.isEmpty {
                            let commonPackDTOList = stickerPacks.filter({ pack in
                                return commonPacks.contains(pack.id)
                            })
                            for commonPackDTO in commonPackDTOList {
                                if let index = stickerPackListPayload.packs.firstIndex(of: commonPackDTO.id), commonPackDTO.orderIndex != index {
                                    commonPackDTO.orderIndex = Int64(index)
                                }
                                if !commonPackDTO.stickers.compactMap{ $0 as? StickerDTO }.allSatisfy({ $0.data != nil}) {
                                    packsNeedToAdd.insert(commonPackDTO.id)
                                }
                            }
                        }                                                                                                                                             
                        // Fetch pack that is missing, or not get full data of sticker.
                        if !packsNeedToAdd.isEmpty {
                            self.fetchStickerPacks(packsNeedToAdd, completion: { [weak self] in
                                self?.isSyncingSticker = false
                            })
                        } else {
                            self.hasSyncSticker = true
                            self.isSyncingSticker = false
                        }
                    }
                    catch (let error) {
                        log.warning("[Database] Failed to get sticker packes with error: \(error)")
                        self.isSyncingSticker = false
                    }
                }, completion: { error in
                    if let error {
                        log.error("[Sync] sync stickers finished with error:\(error)")
                    }
                })
            case .failure(let error):
                log.warning("[Sync] Failed to sync stickers with error: \(error)")
                self.isSyncingSticker = false
            }
        }
    }

    /// Fetch all sticker packs by their IDs
    /// - Parameters:
    ///  - packs: The list of pack id.
    ///  - completion: The completion closure.
    func fetchStickerPacks(_ packs: Set<String>, completion: (() -> Void)?) {
        var loadedPacks: Array<StickerPackPayload> = []

        let operations = packs.map({ pack in
            let index = stickerPackList?.packs.firstIndex(of: pack) ?? 0
            return GetStickerPackOperation(packName: pack,
                                           packIndex: index,
                                           apiClient: apiClient,
                                           database: database,
                                           queue: fetchStickerPackDetailOperationQueue) { result in
                switch result {
                case .success(let stickerPayload):
                    log.debug("[Sync] Got sticker pack: \(pack)")
                    loadedPacks.append(stickerPayload)
                case .failure(let error):
                    log.debug("[Sync] Failed to get sticker pack: \(pack) with error: \(error)")
                }
            }
        })

        let completeOperation = BlockOperation {
            self.database.write ({ [weak self] session in
                for packPayload in loadedPacks {
                    let index = self?.stickerPackList?.packs.firstIndex(of: packPayload.id) ?? 0
                    session.saveStickerPacks(payload: packPayload, at: index)
                }
            }, completion: { [weak self] error in
                if loadedPacks.count == packs.count,
                   loadedPacks.allSatisfy { pack in
                    return pack.stickers.allSatisfy({ $0.data != nil })
                },
                error == nil {
                    // Mark hasSyncSticker when all packs are synced to skip re-sync."
                    self?.hasSyncSticker = true
                }
                completion?()
            })
        }

        for operation in operations {
            completeOperation.addDependency(operation)
        }

        fetchStickerPacksOperationQueue.addOperations(operations, waitUntilFinished: false)
        fetchStickerPacksOperationQueue.addOperation(completeOperation)
    }

    func queueOfflineRequest(endpoint: DataEndpoint) {
        guard config.isLocalStorageEnabled else { return }
        offlineRequestsRepository.queueOfflineRequest(endpoint: endpoint)
    }
}
