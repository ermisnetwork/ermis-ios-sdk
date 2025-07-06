//
// Copyright 2025 Ermis Inc.
//

import CoreData
import Foundation

@objc(ProjectDTO)
class ProjectDTO: NSManagedObject {
    @NSManaged var projectId: String
    @NSManaged var projectName: String
    @NSManaged var userProjectId: String
    @NSManaged var client: ClientDTO?

    static func fetchRequest(for projectId: String) -> NSFetchRequest<ProjectDTO> {
        let request = NSFetchRequest<ProjectDTO>(entityName: ProjectDTO.entityName)
        request.predicate = NSPredicate(format: "projectId == %@", projectId)
        return request
    }

    static func load(projectId: String, context: NSManagedObjectContext) -> ProjectDTO? {
        let request = fetchRequest(for: projectId)
        return load(by: request, context: context).first
    }

    static func load(projectIds: [String], context: NSManagedObjectContext) -> [ProjectDTO] {
        guard !projectIds.isEmpty else { return [] }
        let request = NSFetchRequest<ProjectDTO>(entityName: ProjectDTO.entityName)
        request.predicate = NSPredicate(format: "projectId IN %@", projectIds)
        return load(by: request, context: context)
    }


    static func loadOrCreate(id: String, context: NSManagedObjectContext, cache: PreWarmedCache?) -> ProjectDTO {
        if let cachedObject = cache?.model(for: id, context: context, type: ProjectDTO.self) {
            return cachedObject
        }

        if let existing = load(projectId: id, context: context) {
            return existing
        }

        let request = fetchRequest(id: id)
        let new = NSEntityDescription.insertNewObject(into: context, for: request)
        new.projectId = id
        return new
    }
}

extension NSManagedObjectContext {
    func saveProject(payload projectPayload: ProjectDTO, with client: ClientDTO?, cache: PreWarmedCache?) throws -> ProjectDTO {
        guard let client else {
            throw ClientError.ProjectPayloadSavingFailure("""
            Client nil when save client.
            - `project.projectId` value: \(String(describing: projectPayload.projectId))
            """)
        }
        let dto = ProjectDTO.loadOrCreate(id: projectPayload.projectId,
                                          context: self,
                                          cache: cache)
        dto.projectId = projectPayload.projectId
        dto.projectName = projectPayload.projectName
        dto.userProjectId = projectPayload.userProjectId
        dto.client = client
        return dto
    }

    func saveProject(payload projectPayload: ProjectDTO,
                     with clientId: String,
                     cache: PreWarmedCache?) throws -> ProjectDTO {
        let clientDTO = ClientDTO.load(clientId: clientId, context: self)
        let dto = try saveProject(payload: projectPayload, with: clientDTO, cache: cache)
        return dto
    }
}

extension ClientError {
    class ProjectPayloadSavingFailure: ClientError {}
}
