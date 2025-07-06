//
// Copyright 2025 Ermis Inc.
//

import CoreData
import Foundation

typealias DatabaseType = String
typealias DatabaseId = String
typealias PreWarmedCache = [DatabaseType: [DatabaseId: NSManagedObjectID]]
typealias IdentifiableDatabaseObject = NSManagedObject & IdentifiableModel

extension PreWarmedCache {
    func model<T: IdentifiableDatabaseObject>(for id: DatabaseId, context: NSManagedObjectContext, type: T.Type) -> T? {
        guard let objectId = self[T.className]?[id] else { return nil }
        return try? context.existingObject(with: objectId) as? T
    }
}

protocol IdentifiableModel {
    static var className: DatabaseType { get }
    static var idKeyPath: String? { get }
    static func id(for model: NSManagedObject) -> DatabaseId?
}

private extension IdentifiableModel {
    static var _className: String { String(describing: self) }
}

extension ChannelDTO: IdentifiableModel {
    static let className: DatabaseType = _className
    static let idKeyPath: String? = #keyPath(ChannelDTO.cid)
    static func id(for model: NSManagedObject) -> DatabaseId? { (model as? Self)?.cid }
}

extension UserDTO: IdentifiableModel {
    static let className: DatabaseType = _className
    static let idKeyPath: String? = #keyPath(UserDTO.id)
    static func id(for model: NSManagedObject) -> DatabaseId? { (model as? Self)?.id }
}

extension MessageDTO: IdentifiableModel {
    static let className: DatabaseType = _className
    static let idKeyPath: String? = #keyPath(MessageDTO.id)
    static func id(for model: NSManagedObject) -> DatabaseId? { (model as? Self)?.id }
}

extension MessageReactionDTO: IdentifiableModel {
    static let className: DatabaseType = _className
    static let idKeyPath: String? = #keyPath(MessageReactionDTO.id)
    static func id(for model: NSManagedObject) -> DatabaseId? { (model as? Self)?.id }
}

extension MemberDTO: IdentifiableModel {
    static let className: DatabaseType = _className
    static let idKeyPath: String? = #keyPath(MemberDTO.id)
    static func id(for model: NSManagedObject) -> DatabaseId? { (model as? Self)?.id }
}

extension ChannelReadDTO: IdentifiableModel {
    static let className: DatabaseType = _className
    static let idKeyPath: String? = nil
    static func id(for model: NSManagedObject) -> DatabaseId? { nil } // Does not have id
}

extension ChainDTO: IdentifiableModel {
    static let className: DatabaseType = _className
    static let idKeyPath: String? = #keyPath(ChainDTO.chainId)
    static func id(for model: NSManagedObject) -> DatabaseId? { (model as? Self)?.chainId }
}

extension ClientDTO: IdentifiableModel {
    static let className: DatabaseType = _className
    static let idKeyPath: String? = #keyPath(ClientDTO.clientId)
    static func id(for model: NSManagedObject) -> DatabaseId? { (model as? Self)?.clientId }
}

extension ProjectDTO: IdentifiableModel {
    static let className: DatabaseType = _className
    static let idKeyPath: String? = #keyPath(ProjectDTO.projectId)
    static func id(for model: NSManagedObject) -> DatabaseId? { (model as? Self)?.projectId }
}
