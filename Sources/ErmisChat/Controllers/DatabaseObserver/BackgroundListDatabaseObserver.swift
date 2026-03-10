//
// Copyright 2025 Ermis Inc.
//

import CoreData
import Foundation
import ErmisShared

class ListDatabaseObserverWrapper<Item, DTO: NSManagedObject> {
    private var foreground: ListDatabaseObserver<Item, DTO>?
    private var background: BackgroundListDatabaseObserver<Item, DTO>?
    let isBackground: Bool

    var items: LazyCachedMapCollection<Item> {
        if isBackground, let background = background {
            return background.items
        } else if let foreground = foreground {
            return foreground.items
        } else {
            log.assertionFailure("Should have foreground or background observer")
            return []
        }
    }

    /// This function is only useful with background mapping enabled.
    /// Since DB updates now happen in a background thread, sometimes we need to
    /// wait for the updates to do some action, so this function is useful for that.
    func refreshItems(completion: @escaping () -> Void) {
        if let background = background {
            background.updateItems(changes: nil, completion: completion)
        } else {
            completion()
        }
    }

    /// Called with the aggregated changes after the internal `NSFetchResultsController` calls `controllerWillChangeContent`
    /// on its delegate.
    var onWillChange: (() -> Void)? {
        didSet {
            if isBackground {
                background?.onWillChange = onWillChange
            } else {
                foreground?.onWillChange = onWillChange
            }
        }
    }

    /// Called with the aggregated changes after the internal `NSFetchResultsController` calls `controllerDidChangeContent`
    /// on its delegate.
    var onDidChange: (([ListChange<Item>]) -> Void)? {
        didSet {
            if isBackground {
                background?.onDidChange = { [weak self] changes in
                    guard let self = self, let background = self.background else { return }
                    
                    // Check if changes contain only updates
                    let hasOnlyUpdates = changes.allSatisfy { $0.isUpdate }
                    
                    if hasOnlyUpdates {
                        // Only updates - invalidate specific cache entries
                        background.invalidateCacheForUpdates(changes)
                    } else {
                        // Has insertions, deletions, or moves - reset entire cache
                        background.resetCache()
                    }
                    
                    self.onDidChange?(changes)
                }
            } else {
                foreground?.onChange = onDidChange
            }
        }
    }

    init(
        isBackground: Bool,
        database: DatabaseContainer,
        fetchRequest: NSFetchRequest<DTO>,
        itemCreator: @escaping (DTO) throws -> Item,
        sorting: [SortValue<Item>] = [],
        fetchedResultsControllerType: NSFetchedResultsController<DTO>.Type = NSFetchedResultsController<DTO>.self
    ) {
        self.isBackground = isBackground
        if isBackground {
            background = BackgroundListDatabaseObserver(
                context: database.backgroundReadOnlyContext,
                fetchRequest: fetchRequest,
                itemCreator: itemCreator,
                sorting: sorting,
                fetchedResultsControllerType: fetchedResultsControllerType
            )
        } else {
            foreground = ListDatabaseObserver(
                context: database.viewContext,
                fetchRequest: fetchRequest,
                itemCreator: itemCreator,
                sorting: sorting,
                fetchedResultsControllerType: fetchedResultsControllerType
            )
        }
    }

    func startObserving() throws {
        if isBackground, let background = background {
            try background.startObserving()
        } else if let foreground = foreground {
            try foreground.startObserving()
        } else {
            log.assertionFailure("Should have foreground or background observer")
        }
    }
}

class BackgroundListDatabaseObserver<Item, DTO: NSManagedObject>: BackgroundDatabaseObserver<Item, DTO> {
    private var cachedCollection: LazyCachedMapCollection<Item>?

    var items: LazyCachedMapCollection<Item> {
        if let cached = cachedCollection {
            return cached
        }
        let collection = LazyCachedMapCollection(source: rawItems, map: { $0 }, context: nil)
        cachedCollection = collection
        return collection
    }

    /// Invalidates specific indices in the cached collection when items are updated
    func invalidateCacheForUpdates(_ changes: [ListChange<Item>]) {
        let updatedIndices = changes.compactMap { change -> Int? in
            guard case .update(_, let indexPath) = change else { return nil }
            return indexPath.row
        }

        if !updatedIndices.isEmpty, var collection = cachedCollection {
            collection.invalidateCache(at: updatedIndices)
            cachedCollection = collection
        }
    }

    /// Clears the entire cached collection, forcing it to be rebuilt on next access
    func resetCache() {
        cachedCollection = nil
    }

    override init(
        context: NSManagedObjectContext,
        fetchRequest: NSFetchRequest<DTO>,
        itemCreator: @escaping (DTO) throws -> Item,
        sorting: [SortValue<Item>],
        fetchedResultsControllerType: NSFetchedResultsController<DTO>.Type = NSFetchedResultsController<DTO>.self
    ) {
        super.init(
            context: context,
            fetchRequest: fetchRequest,
            itemCreator: itemCreator,
            sorting: sorting,
            fetchedResultsControllerType: fetchedResultsControllerType
        )
    }
}
