////
////  Test.swift
////  ErmisChat
////
////  Created by VuongXuanTuyen on 10/3/26.
////
//
//import open_mls_ios
//import Foundation
//
//class Test {
//    func test() {
//
//    }
//
//
//    func initMlsDatabase() throws {
//        guard let documentDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
//            return
//        }
//
//        let dbPath = documentDir.appendingPathComponent("ermis_mls.db").path
//        let provider = try Provider.newWithPath(dbPath: dbPath)
//
//    }
//
//    func createIdentity(userId: String, provider: Provider) throws -> Identity {
//
//        let identity = try Identity(provider: provider, userId: userId)
//        ///
//        let identityBytes = try identity.toBytes()
//        ///
//        let restored = try Identity.fromBytes(provider: provider, data: identityBytes)
//
//        return identity
//    }
//
//    func createNewGroup(from provider: Provider, founder: Identity, cid: String) throws -> Group {
//        let group = try Group.createWithCid(provider: provider, founder: founder, cid: cid)
//        return group
//    }
//
//    func createKeyPackage(from identity: Identity, provider: Provider) -> Data {
//        let keyPackage = identity.keyPackage(provider: provider)
//        let kpBytes = keyPackage.toBytes()
//        return kpBytes
//    }
//
//    func encrypMessage(_ message: String) {
//        
//    }
//}
//
//
