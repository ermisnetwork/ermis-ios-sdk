//
// Copyright 2025 Ermis Inc.
//

import CoreData
import Foundation

@objc(ClientDTO)
class ClientDTO: NSManagedObject {
    @NSManaged var clientId: String
    @NSManaged var clientName: String
    @NSManaged var chain: ChainDTO?
    @NSManaged var projects: Set<ProjectDTO>

    static func fetchRequest(for clientId: String) -> NSFetchRequest<ClientDTO> {
        let request = NSFetchRequest<ClientDTO>(entityName: ClientDTO.entityName)
        request.predicate = NSPredicate(format: "clientId == %@", clientId)
        return request
    }

    static func load(clientId: String, context: NSManagedObjectContext) -> ClientDTO? {
        let request = fetchRequest(for: clientId)
        return load(by: request, context: context).first
    }

    static func load(clientIds: [String], context: NSManagedObjectContext) -> [ClientDTO] {
        guard !clientIds.isEmpty else { return [] }
        let request = NSFetchRequest<ClientDTO>(entityName: ClientDTO.entityName)
        request.predicate = NSPredicate(format: "clientId IN %@", clientIds)
        return load(by: request, context: context)
    }

    static func loadOrCreate(id: String, context: NSManagedObjectContext, cache: PreWarmedCache?) -> ClientDTO {
        if let cachedObject = cache?.model(for: id, context: context, type: ClientDTO.self) {
            return cachedObject
        }

        if let existing = load(clientId: id, context: context) {
            return existing
        }

        let request = fetchRequest(id: id)
        let new = NSEntityDescription.insertNewObject(into: context, for: request)
        new.clientId = id
        return new
    }
}

extension NSManagedObjectContext {
    func saveClient(payload clientPayload: ErmisClientPayload,
                    with chain: ChainDTO?,
                    cache: PreWarmedCache?) throws -> ClientDTO {
        guard let chain else {
            throw ClientError.ClientPayloadSavingFailure("""
            Chain nil when save client.
            - `client.clientId` value: \(String(describing: clientPayload.clientId))
            """)
        }

        let client = ClientDTO.loadOrCreate(id: clientPayload.clientId,
                                            context: self,
                                            cache: cache)
        client.clientName = clientPayload.clientName
        client.clientId = clientPayload.clientId
        client.chain = chain
        return client
    }

    func saveClient(payload clientPayload: ErmisClientPayload,
                    with chain: String,
                    cache: PreWarmedCache?) throws -> ClientDTO {
        let chain = ChainDTO.load(chainId: chain, context: self)
        let client = try saveClient(payload: clientPayload, with: chain, cache: cache)
        return client
    }
}

extension ClientError {
    class ClientPayloadSavingFailure: ClientError {}
}
