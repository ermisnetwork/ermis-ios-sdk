//
// Copyright 2025 Ermis Inc.
//

import CoreData
import Foundation

@objc(StickerDTO)
class StickerDTO: NSManagedObject {
    @NSManaged var id: String
    @NSManaged var url: String?
    @NSManaged var body: String?
    @NSManaged var data: Data?

    static func loadOrCreate(id: String, context: NSManagedObjectContext, cache: PreWarmedCache?) -> StickerDTO {
        if let cachedObject = cache?.model(for: id, context: context, type: StickerDTO.self) {
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

    static func fetchRequest(for id: String) -> NSFetchRequest<StickerDTO> {
        let request = NSFetchRequest<StickerDTO>(entityName: StickerDTO.entityName)
        request.predicate = NSPredicate(format: "id == %@", id)
        request.fetchLimit = 1
        return request
    }
}

extension NSManagedObjectContext {
    func saveSticker(payload: StickerPayload, cache: PreWarmedCache?) -> StickerDTO {
        let dto = StickerDTO.loadOrCreate(id: payload.id, context: self, cache: cache)
        dto.url = payload.url
        dto.body = payload.body
        if let data = payload.data {
            dto.data = data
        }
        return dto
    }
}

extension StickerDTO {
    /// Snapshots the current state of `ChannelDTO` and returns an immutable model object from it.
    func asModel() throws -> Sticker { try .create(fromDTO: self) }
}

extension Sticker {
    fileprivate static func create(fromDTO dto: StickerDTO) throws -> Sticker {
        return Sticker(id: dto.id, url: dto.url, body: dto.body, data: dto.data)
    }
}
