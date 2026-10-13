import Foundation
import CoreData
import XCTest
import open_mls_ios
@testable import ErmisChat

final class ArchiveRestoreValidationTests: XCTestCase {
    func testArchiveCostProjectionHasBoundedLabelsAndStripsIdentity() {
        let marker="archive_cost phase=http reason=success latency_us=1200 encoded_bytes=456 peak_rss_bytes=789"
        XCTAssertEqual(MlsFieldMarkerProjector.project(marker+" cid=private-fixture token=private-fixture"),marker)
        XCTAssertNil(MlsFieldMarkerProjector.project(marker.replacingOccurrences(of:"phase=http",with:"phase=private-fixture")))
        XCTAssertNil(MlsFieldMarkerProjector.project(marker.replacingOccurrences(of:"reason=success",with:"reason=private-fixture")))
    }
    private let cid = "messaging:project:archive"
    private let id = "12345678-1234-1234-1234-123456789abc"
    private var aad: E2eeMessageAADV1 { .init(cid: cid, e2eeGroupId: cid, messageId: id,
        forwardCid: "messaging:source", forwardMessageId: "source-id", forwardParentCid: "parent") }
    private func validate(_ payload: E2ePayload, aad: Data) throws -> E2ePayload {
        try E2eeArchiveMessageValidator.validate(payload, processedAAD: aad, messageId: id, cid: cid, groupCid: cid)
    }
    func testActualArchiveCryptoAuthenticatesForwardAndRejectsBindings() throws {
        let provider = Provider(); let sender = try Identity(provider: provider, userId: "fixture")
        let group = try Group.createWithCid(provider: provider, founder: sender, cid: cid)
        let archive = try group.archiveEpochV2()
        let ciphertext = try group.createMessageWithAad(provider: provider, sender: sender,
            plaintext: Data(#"{"text":"fixture","attachments":[]}"#.utf8), aad: aad.encoded())
        let result = try decryptEpochArchiveV2(provider: provider, archive: archive.archiveBytes,
            snapshot: archive.snapshotBytes, ciphertext: ciphertext, allowOwnMessages: true, maxForwardDistance: 0)
        let payload = try JSONDecoder().decode(E2ePayload.self, from: result.content)
        let decoded = try validate(payload, aad: result.aad)
        XCTAssertEqual(decoded.authenticatedMetadata?.forwardCid, "messaging:source")
        XCTAssertEqual(decoded.authenticatedMetadata?.forwardMessageId, "source-id")
        XCTAssertEqual(decoded.authenticatedMetadata?.forwardParentCid, "parent")
        for (route, groupCid, messageId) in [("wrong",cid,id),(cid,"wrong",id),(cid,cid,UUID().uuidString)] {
            XCTAssertThrowsError(try E2eeArchiveMessageValidator.validate(payload, processedAAD: result.aad,
                messageId: messageId, cid: route, groupCid: groupCid))
        }
        var tampered = ciphertext; tampered[tampered.count-1] ^= 1
        XCTAssertThrowsError(try decryptEpochArchiveV2(provider: provider, archive: archive.archiveBytes,
            snapshot: archive.snapshotBytes, ciphertext: tampered, allowOwnMessages: true, maxForwardDistance: 0))
    }
    func testLegacyDropsUnauthenticatedForwardFields() throws {
        let payload = E2ePayload(text: "fixture", attachments: [], stickerUrl: nil)
        let value = try E2eeArchiveMessageValidator.validate(payload, processedAAD: Data(), messageId: id,
            cid: cid, groupCid: cid, expectedEnvelope: .init(forwardCid: "untrusted", forwardMessageId: "untrusted",
                forwardParentCid: nil, attachmentIds: []))
        XCTAssertEqual(value.text,"fixture"); XCTAssertNil(value.authenticatedMetadata)
    }
    func testManifestDiscriminatorsAndMixedLanesRejectBeforeAad() throws {
        for manifest in [#"{"assets":[]}"#, #"{"version":null}"#, #"{"attachment_id":"12345678-1234-1234-1234-123456789abc"}"#] {
            let json = "{\"text\":\"fixture\",\"attachments\":[\(manifest)]}"
            XCTAssertThrowsError(try JSONDecoder().decode(E2ePayload.self, from: Data(json.utf8)))
        }
    }
    func testAadRejectsEveryTruncationAndUnsupportedFlagsVersionUtf8() throws {
        let data = try aad.encoded()
        for count in 0..<data.count { XCTAssertThrowsError(try E2eeMessageAADV1.decoded(from: data.prefix(count))) }
        let version = 2 + E2eeMessageAADV1.domain.utf8.count
        let cidOffset = version + 3
        let flag = cidOffset + cid.utf8.count + 2 + cid.utf8.count + 16
        for (offset, byte) in [(version,UInt8(2)),(cidOffset,UInt8(255)),(flag,UInt8(2))] {
            var bad=data;bad[offset]=byte;XCTAssertThrowsError(try E2eeMessageAADV1.decoded(from:bad))
        }
        XCTAssertThrowsError(try E2eeMessageAADV1.decoded(from: data + Data([0])))
        XCTAssertThrowsError(try E2eeMessageAADV1.decoded(from: Data(repeating: 0,count:1_376_290)))
    }
    private func database(_ url: URL) throws -> DatabaseContainer {
        let db=DatabaseContainer(kind: .onDisk(databaseFileURL:url),shouldResetEphemeralValuesOnStart:false)
        let loaded=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in !db.persistentStoreCoordinator.persistentStores.isEmpty },object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[loaded],timeout:5),.completed)
        return db
    }
    private func close(_ db: DatabaseContainer) throws {
        for context in db.allContext { context.performAndWait { context.reset() } }
        for store in db.persistentStoreCoordinator.persistentStores { try db.persistentStoreCoordinator.remove(store) }
    }
    func testAuthenticatedMetadataPersistsAcrossActualDatabaseReopenAndUnprovenManifestQuarantines() throws {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("apin-\(UUID().uuidString).sqlite")
        let payload=try validate(E2ePayload(text:"fixture",attachments:[],stickerUrl:nil),aad:aad.encoded())
        let first=try database(url)
        try first.writeAndWait { session in
            try session.saveMessageDecrypt(payload:payload,messageId:id,ciphertextHash:Data([1,2,3]))
        }
        try close(first)
        let reopened=try database(url);defer { try? close(reopened) }
        try reopened.writeAndWait { session in
            let dto=try XCTUnwrap(MessageDecryptDTO.load(messageId:id,context:session as! NSManagedObjectContext))
            XCTAssertEqual(try dto.asPayload().authenticatedMetadata,payload.authenticatedMetadata)
            XCTAssertEqual(dto.ciphertextHash,Data([1,2,3]))
            let manifest=E2eeAttachmentManifestV1(attachmentId:id,assets:[])
            dto.attachmentsData=try JSONEncoder.default.encode(E2eCachedAttachments(e2ee:[manifest]))
            XCTAssertTrue(try dto.asPayload().e2eeAttachments.isEmpty)
            XCTAssertNil(try dto.asPayload().authenticatedMetadata)
            XCTAssertEqual(dto.ciphertextHash,Data([1,2,3]))
        }
    }
    func testBoundedAadBenchmark() throws {
        let input=try E2eeMessageAADV1(cid:String(repeating:"c",count:60_000),e2eeGroupId:cid,messageId:id,
            forwardCid:"messaging:source").encoded()
        for _ in 0..<20 { _=try E2eeMessageAADV1.decoded(from:input) }
        var samples=[Double]()
        for _ in 0..<200 { let start=CFAbsoluteTimeGetCurrent();_=try E2eeMessageAADV1.decoded(from:input);samples.append((CFAbsoluteTimeGetCurrent()-start)*1000) }
        samples.sort()
        print("apin_benchmark aad_bytes=\(input.count) p95_ms=\(samples[189]) p99_ms=\(samples[197])")
        XCTAssertLessThan(samples[189],10);XCTAssertLessThan(samples[197],25)
    }
    func testActualDatabaseArchivePublishGuardRejectsEditedDeletedAndCrossRoute() throws {
        let db=try database(FileManager.default.temporaryDirectory.appendingPathComponent("apin-guard-\(UUID().uuidString).sqlite"))
        defer {try? close(db)}
        try db.writeAndWait { session in
            let context=session as! NSManagedObjectContext
            let row=MessageDTO.loadOrCreate(id:id,context:context,cache:nil)
            row.cid=cid;row.encryptedData=Data([1]);row.type="regular"
            row.createdAt=DBDate();row.updatedAt=DBDate();row.text="fixture"
            row.isSilent=false;row.mentionedAll=false;row.reactionCounts=[:];row.reactionScores=[:]
            XCTAssertTrue(context.canPublishArchivedCiphertext(messageId:id,ciphertext:Data([1]),cid:cid))
            XCTAssertFalse(context.canPublishArchivedCiphertext(messageId:id,ciphertext:Data([2]),cid:cid))
            XCTAssertFalse(context.canPublishArchivedCiphertext(messageId:id,ciphertext:Data([1]),cid:"messaging:other"))
            row.deletedAt=DBDate();XCTAssertFalse(context.canPublishArchivedCiphertext(messageId:id,ciphertext:Data([1]),cid:cid))
            row.deletedAt=nil;row.isHardDeleted=true;XCTAssertFalse(context.canPublishArchivedCiphertext(messageId:id,ciphertext:Data([1]),cid:cid))
        }
    }
}
