// Copyright 2026 Ermis Inc.

import CoreData
import ObjectiveC

private var encryptedMessageStateOwnerKey: UInt8 = 0

extension NSPersistentStoreCoordinator {
    /// Associated lifetime prevents messages from another account/database sharing errors.
    var encryptedMessageStates: EncryptedMessageStateStore {
        objc_sync_enter(self); defer { objc_sync_exit(self) }
        if let store = objc_getAssociatedObject(self, &encryptedMessageStateOwnerKey) as? EncryptedMessageStateStore { return store }
        let store = EncryptedMessageStateStore()
        objc_setAssociatedObject(self, &encryptedMessageStateOwnerKey, store, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return store
    }
}
