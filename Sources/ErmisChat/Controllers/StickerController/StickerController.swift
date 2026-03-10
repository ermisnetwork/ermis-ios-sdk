//
// Copyright 2025 Ermis Inc.
//

import Foundation
import CoreData

public extension ErmisClient {
    /// Creates a new `StickerController` instance.
    /// - Returns: A new instance of `StickerController`.
    func stickerController() -> StickerController {
        .init(client: self)
    }
}

/// `StickerController` is a controller class which allows to observe sticker
public class StickerController: DataController, DelegateCallable, DataStoreProvider {
    /// The `ErmisClient` instance this controller belongs to.
    public let client: ErmisClient

    private let environment: Environment

    /// A type-erased delegate.
    var multicastDelegate: MulticastDelegate<StickerControllerDelegate> = .init() {
        didSet {
            stateMulticastDelegate.set(mainDelegate: multicastDelegate.mainDelegate)
            stateMulticastDelegate.set(additionalDelegates: multicastDelegate.additionalDelegates)
            startObservingIfNeeded()
        }
    }

    /// The observer used to track the user changes in the database.
    private(set) lazy var stickerObserver: ListDatabaseObserverWrapper<StickerPack, StickerPackDTO> = {
        let observer = environment.createStickerPackListDatabaseObserver(
            ErmisRuntimeCheck.isBackgroundMappingEnabled,
            client.databaseContainer,
            StickerPackDTO.allStickerPack(),
            { try $0.asModel() },
            [SortValue(keyPath: \.orderIndex, isAscending: true)]
        )

        observer.onDidChange = { [weak self] changes in
            self?.delegateCallback { [weak self] in
                guard let self = self else {
                    log.warning("Callback called while self is nil")
                    return
                }
                $0.controller(self, didChangeStickerPacks: changes)
            }
        }

        observer.onWillChange = { [weak self] in
            self?.delegateCallback { [weak self] in
                guard let self = self else {
                    log.warning("Callback called while self is nil")
                    return
                }
                $0.controllerWillChangeStickerPack(self)
            }
        }

        return observer
    }()

    var _basePublishers: Any?
    /// An internal backing object for all publicly available Combine publishers. We use it to simplify the way we expose
    /// publishers. Instead of creating custom `Publisher` types, we use `CurrentValueSubject` and `PassthroughSubject` internally,
    /// and expose the published values by mapping them to a read-only `AnyPublisher` type.
    var basePublishers: BasePublishers {
        if let value = _basePublishers as? BasePublishers {
            return value
        }
        _basePublishers = BasePublishers(controller: self)
        return _basePublishers as? BasePublishers ?? .init(controller: self)
    }

    public var stickerPacks: LazyCachedMapCollection<StickerPack> {
        startObservingIfNeeded()
        return stickerObserver.items
    }

    init(client: ErmisClient, enviroment: Environment = .init()) {
        self.client = client
        self.environment = enviroment
    }

    public override func synchronize(_ completion: (((any Error)?) -> Void)? = nil) {
        startObservingIfNeeded()
        client.syncRepository.syncStickersIfNeeded()
    }

    public func addRecentSticker(_ sticker: Sticker) {
        client.databaseContainer.write { session in
            guard let recentStickerPack = try? session.getStickerPack(id: StickerPack.recentsPackId) else {
                return
            }
            var stickers = Array(recentStickerPack.stickers).compactMap({ $0 as? StickerDTO })
            if let index = stickers.firstIndex(where: { $0.id == sticker.id }) {
                stickers.move(fromOffsets: [index], toOffset: 0)
                recentStickerPack.stickers = NSOrderedSet(array: stickers)
                return
            }

            guard let stickerDTO = try? session.getSticker(id: sticker.id) else {
                return
            }

            stickers.insert(stickerDTO, at: 0)
            if stickers.count > 16 {
                stickers.removeLast()
            }
            recentStickerPack.stickers = NSOrderedSet(array: stickers)
        }
    }
    // MARK: - Observer
    private func startObservingIfNeeded() {
        guard state == .initialized else { return }

        do {
            try stickerObserver.startObserving()
            state = .localDataFetched
        } catch {
            log.error("Observing sticker pack failed: \(error).")
            state = .localDataFetchFailed(ClientError(with: error))
        }
    }
}

extension StickerController {
    struct Environment {
        var createStickerPackListDatabaseObserver: (
            _ isBackground: Bool,
            _ database: DatabaseContainer,
            _ fetchRequest: NSFetchRequest<StickerPackDTO>,
            _ itemCreator: @escaping (StickerPackDTO) throws -> StickerPack,
            _ sorting: [SortValue<StickerPack>]
        )
        -> ListDatabaseObserverWrapper<StickerPack, StickerPackDTO> = {
            ListDatabaseObserverWrapper(isBackground: $0, database: $1, fetchRequest: $2, itemCreator: $3, sorting: $4)
        }
    }
}

// MARK: - Delegate
public protocol StickerControllerDelegate: DataControllerStateDelegate {
    /// The controller will update the list of observed stickerPacks.
    ///
    /// - Parameter controller: The controller emitting the change callback.
    ///
    func controllerWillChangeStickerPack(_ controller: StickerController)

    /// The controller changed the list of observed stickerPacks.
    ///
    /// - Parameters:
    ///   - controller: The controller emitting the change callback.
    ///   - changes: The change to the list of StickerPack.
    ///
    func controller(
        _ controller: StickerController,
        didChangeStickerPacks changes: [ListChange<StickerPack>]
    )
}

public extension StickerControllerDelegate {
    func controllerWillChangeStickerPack(_ controller: StickerController) {}

    func controller(
        _ controller: StickerController,
        didChangeStickerPacks changes: [ListChange<StickerPack>]
    ) {}
}

extension StickerController {
    /// Set the delegate of `ChannelListController` to observe the changes in the system.
    public weak var delegate: StickerControllerDelegate? {
        get { multicastDelegate.mainDelegate }
        set { multicastDelegate.set(mainDelegate: newValue) }
    }
}
