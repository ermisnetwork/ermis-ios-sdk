//
// Copyright 2025 Ermis Inc.
//

import CoreData
import Foundation

@objc(ChainDTO)
class ChainDTO: NSManagedObject {
    @NSManaged var chainId: String
    @NSManaged var clients: Set<ClientDTO>

    static func fetchRequest(for chainId: String) -> NSFetchRequest<ChainDTO> {
        let request = NSFetchRequest<ChainDTO>(entityName: ChainDTO.entityName)
        request.predicate = NSPredicate(format: "chainId == %@", chainId)
        return request
    }

    static func load(chainId: String, context: NSManagedObjectContext) -> ChainDTO? {
        let request = fetchRequest(for: chainId)
        return load(by: request, context: context).first
    }

    static func load(chainIds: [String], context: NSManagedObjectContext) -> [ChainDTO] {
        guard !chainIds.isEmpty else { return [] }
        let request = NSFetchRequest<ChainDTO>(entityName: ChainDTO.entityName)
        request.predicate = NSPredicate(format: "chainId IN %@", chainIds)
        return load(by: request, context: context)
    }

    static func loadOrCreate(chainId: String,
                             context: NSManagedObjectContext,
                             cache: PreWarmedCache?) -> ChainDTO {
        if let cachedObject = cache?.model(for: chainId, context: context, type: ChainDTO.self) {
            return cachedObject
        }

        let request = fetchRequest(for: chainId)
        if let existing = load(by: request, context: context).first {
            return existing
        }

        let new = NSEntityDescription.insertNewObject(into: context, for: request)
        new.chainId = chainId
        return new
    }
}

// MARK: Saving and loading the data

extension NSManagedObjectContext {
    func saveChain(payload chainPayload: ChainPayload, cache: PreWarmedCache?) throws -> ChainDTO {
        let dto = ChainDTO.loadOrCreate(chainId: String(chainPayload.chainId),
                                        context: self,
                                        cache: cache)
        dto.chainId = String(chainPayload.chainId)
        let clientDtoList = try chainPayload.clients.map({
            try saveClient(payload: $0, with: dto, cache: cache)
        })
        return dto
    }

    func saveClients(_ clients: [ErmisClientPayload],
                     to chain: ChainDTO,
                     cache: PreWarmedCache) throws {
        let currentClients = chain.clients
        let clientDtoList = try clients.map({
            try saveClient(payload: $0, with: chain, cache: cache)
        })
        let removedList = currentClients.filter { currentClient in
            return clientDtoList.contains(where: { $0.clientId == currentClient.clientId })
        }
        removedList.forEach({
            delete($0)
        })
    }
}
