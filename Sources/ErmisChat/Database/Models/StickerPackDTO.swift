//
// Copyright 2025 Ermis Inc.
//

import CoreData
import Foundation

@objc(StickerPackDTO)
class StickerPackDTO: NSManagedObject {
    @NSManaged var id: String
    @NSManaged var title: String
    @NSManaged var stickers: NSOrderedSet
    @NSManaged var orderIndex: Int64

    static func loadOrCreate(id: String, context: NSManagedObjectContext, cache: PreWarmedCache?) -> StickerPackDTO {
        if let cachedObject = cache?.model(for: id, context: context, type: StickerPackDTO.self) {
            return cachedObject
        }

        let request = fetchRequest(for: id)

        if let existing = load(by: request, context: context).first {
            return existing
        }

        let new = NSEntityDescription.insertNewObject(into: context, for: request)
        new.id = id
        return new
    }

    static func fetchRequest(for id: String) -> NSFetchRequest<StickerPackDTO> {
        let request = NSFetchRequest<StickerPackDTO>(entityName: StickerPackDTO.entityName)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \StickerPackDTO.orderIndex, ascending: false)]
        request.predicate = NSPredicate(format: "id == %@", id)
        return request
    }
}

extension NSManagedObjectContext: StickerDataBaseSession {
    func getSticker(id: String) throws -> StickerDTO? {
        let request = StickerDTO.fetchRequest(for: id)
        return try fetch(request).first
    }
    
    func deleteStickerPack(_ pack: StickerPackDTO) {
        delete(pack)
    }
    
    func getStickerPack(id: String) throws -> StickerPackDTO? {
        let request = NSFetchRequest<StickerPackDTO>(entityName: "StickerPackDTO")
        request.predicate = NSPredicate(format: "id == %@", id)
        request.fetchLimit = 1
        let stickerPacks = try fetch(request)
        return stickerPacks.first
    }
    
    func getStickerPacks() throws -> [StickerPackDTO] {
        let request = NSFetchRequest<StickerPackDTO>(entityName: "StickerPackDTO")
        let stickerPacks = try fetch(request)
        return stickerPacks
    }

    func saveStickerPacks(
        payload: StickerPackPayload,
        at orderIndex: Int
    ) -> StickerPackDTO {
        let cache = payload.getPayloadToModelIdMappings(context: self)

        let dto = StickerPackDTO.loadOrCreate(id: payload.id, context: self, cache: cache)
        dto.orderIndex = Int64(orderIndex)
        dto.title = payload.title
        let stickers = payload.stickers.compactMap({
            saveSticker(payload: $0, cache: cache)
        })
        dto.stickers = NSOrderedSet(array: stickers)

        return dto
    }
}

extension StickerPackDTO {
    /// Snapshots the current state of `ChannelDTO` and returns an immutable model object from it.
    func asModel() throws -> StickerPack { try .create(fromDTO: self) }
}

extension StickerPack {
    fileprivate static func create(fromDTO dto: StickerPackDTO) throws -> StickerPack {
        let stickers = dto.stickers
            .compactMap { $0 as? StickerDTO}
            .compactMap { try? $0.asModel() }
        return .init(id: dto.id, title: dto.title, stickers: stickers, orderIndex: Int(dto.orderIndex))
    }
}
// MARK: - Fetch request
extension StickerPackDTO {
    static func allStickerPack() -> NSFetchRequest<StickerPackDTO> {
        let request = NSFetchRequest<StickerPackDTO>(entityName: "StickerPackDTO")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \StickerPackDTO.orderIndex, ascending: true)]
        request.predicate = NSPredicate(format: "stickers.@count > 0")
        return request
    }
}
