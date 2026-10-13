import Foundation
import XCTest
import open_mls_ios
@testable import ErmisChat

final class ArchiveRestorePagingTests: XCTestCase {
    func testInterruptedEpochPageResumesSameCycleAndExactIds() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("apin-resume-\(UUID().uuidString)")
        let namespace="resume-\(UUID().uuidString)";let cid="messaging:project:resume-fixture"
        let keys=try generateRecoveryKeys();let vault=try createRecoveryVault(pin:"12345678",keys:keys)
        var first:E2eeArchiveRecovery?;var interrupted=false;var epochOffsets=[Int]()
        let respond:(Endpoint<E2eeArchiveWire>) async throws -> E2eeArchiveWire = { endpoint in
            switch endpoint.path {
            case .recoveryVault:return .object(["vault_bytes":.bytes(vault),"revision":.uint(1),"recovery_key_id":.string(keys.keyId)])
            case .epochArchive(_, .availability):return .object(["epochs":.array([]),"has_more":.bool(false)])
            case .epochArchive(_, .material):return .object(["blobs":.array([]),"wraps":.array([]),"snapshots":.object([:])])
            case .epochArchive(_, .ciphertexts):
                let query=try XCTUnwrap(endpoint.body as? E2eeArchiveWire)
                let offset=Int(query["cursor"]["last_event_key"].string ?? "0") ?? 0
                if query["epoch_to"].number==0 {
                    epochOffsets.append(offset)
                    if offset==100 && !interrupted {interrupted=true;try first?.stop(clearUnlock:false);throw E2eeArchiveError.sessionEnded}
                }
                let end=min(offset+100,620)
                return .object(["ciphertexts":.array((offset..<end).map { .object(["message_id":.string(String(format:"00000000-0000-4000-8000-%012d",$0)),"cid":.string(cid),"group_generation":.uint(3),"mls_epoch":.uint(0),"mls_ciphertext":.bytes(Data([1]))]) }),"has_more":.bool(end<620),"next_cursor":end<620 ? .object(["last_event_key":.string(String(end))]) : .null])
            default:throw E2eeArchiveError.invalidData
            }
        }
        func owner() throws -> E2eeArchiveRecovery {try E2eeArchiveRecovery(namespace:namespace,root:root,userId:"fixture",api:nil,isCurrentAccount:{true},generation:{_ in 3},apply:{_,_,_,_,_ in XCTFail("No material cannot invoke crypto")},requestOverride:respond)}
        first=try owner();try await first!.unlockRecoveryVault("12345678");try await first!.enqueueRestoreDurably(cid:cid,fromEpoch:0,toEpoch:5)
        let journal=try RecoveryJournal(path:root.appendingPathComponent("MLSArchive/\(namespace)/journal.db").path)
        let deadline=Date().addingTimeInterval(15)
        while !interrupted {guard Date()<deadline else {XCTFail("Did not interrupt page2");return};try await Task.sleep(nanoseconds:50_000_000)}
        let key="restore_epoch:\(cid):3:0"
        let partial=try XCTUnwrap(JSONSerialization.jsonObject(with:XCTUnwrap(journal.get(key:key)?.payload)) as? [String:Any])
        XCTAssertEqual((partial["outcomes"] as? [String:String])?.count,100);let cycle=partial["cycle"] as? String
        first=nil
        let second=try owner();defer {try? second.stop(clearUnlock:false)}
        try await second.unlockRecoveryVault("12345678")
        while try journal.get(key:"restore:\(cid):3")?.status != "done_with_gaps" {guard Date()<deadline else {XCTFail("Resume timed out");return};try await Task.sleep(nanoseconds:50_000_000)}
        let final=try XCTUnwrap(JSONSerialization.jsonObject(with:XCTUnwrap(journal.get(key:key)?.payload)) as? [String:Any])
        XCTAssertEqual(final["cycle"] as? String,cycle)
        XCTAssertEqual(Set((final["outcomes"] as? [String:String] ?? [:]).keys),Set((0..<620).map {String(format:"00000000-0000-4000-8000-%012d",$0)}))
        XCTAssertEqual(epochOffsets,[0,100,100,200,300,400,500,600])
    }
    func testLargeAdvertisedHistoryStopsAtDurableBudgetWithoutRetry() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("apin-cap-\(UUID().uuidString)")
        let namespace="cap-\(UUID().uuidString)";let cid="messaging:project:large-fixture"
        let keys=try generateRecoveryKeys();let vault=try createRecoveryVault(pin:"12345678",keys:keys)
        var calls=0;var bytes=0;let started=Date()
        let recovery=try E2eeArchiveRecovery(namespace:namespace,root:root,userId:"fixture",api:nil,isCurrentAccount:{true},generation:{_ in 3},apply:{_,_,_,_,_ in XCTFail("No material cannot invoke crypto")},requestOverride:{endpoint in
            switch endpoint.path {
            case .recoveryVault:return .object(["vault_bytes":.bytes(vault),"revision":.uint(1),"recovery_key_id":.string(keys.keyId)])
            case .epochArchive(_, .availability):return .object(["epochs":.array([]),"has_more":.bool(false)])
            case .epochArchive(_, .material):return .object(["blobs":.array([]),"wraps":.array([]),"snapshots":.object([:])])
            case .epochArchive(_, .ciphertexts):
                let query=try XCTUnwrap(endpoint.body as? E2eeArchiveWire)
                let offset=Int(query["cursor"]["last_event_key"].string ?? "0") ?? 0
                let page:E2eeArchiveWire = .object(["ciphertexts":.array((offset..<offset+100).map { .object(["message_id":.string(String(format:"00000000-0000-4000-8000-%012d",$0)),"cid":.string(cid),"group_generation":.uint(3),"mls_epoch":.uint(0),"mls_ciphertext":.bytes(Data([1]))]) }),"has_more":.bool(offset+100<100_000),"next_cursor":.object(["last_event_key":.string(String(offset+100))])])
                calls += 1;bytes += try JSONEncoder().encode(page).count;return page
            default:throw E2eeArchiveError.invalidData
            }
        })
        defer {try? recovery.stop(clearUnlock:false)}
        try await recovery.unlockRecoveryVault("12345678");try await recovery.enqueueRestoreDurably(cid:cid,fromEpoch:0,toEpoch:5,requestId:"fixture-login")
        let journal=try RecoveryJournal(path:root.appendingPathComponent("MLSArchive/\(namespace)/journal.db").path)
        while try journal.get(key:"restore:\(cid):3")?.lastError != "discovery_budget" {
            guard Date().timeIntervalSince(started)<30 else {XCTFail("Large fixture exceeded gate");return}
            try await Task.sleep(nanoseconds:50_000_000)
        }
        let payload=try XCTUnwrap(journal.get(key:"restore_epoch:\(cid):3:0")?.payload)
        let proof=try XCTUnwrap(JSONSerialization.jsonObject(with:payload) as? [String:Any])
        let outcomes=try XCTUnwrap(proof["outcomes"] as? [String:String])
        XCTAssertEqual(Set(outcomes.keys),Set((0..<5000).map {String(format:"00000000-0000-4000-8000-%012d",$0)}))
        XCTAssertEqual(proof["coverage"] as? String,"coverage_unknown");XCTAssertEqual(calls,100)
        let stoppedCalls=calls;try await Task.sleep(nanoseconds:1_500_000_000);XCTAssertEqual(calls,stoppedCalls)
        let status=try await recovery.getRecoveryStatus();XCTAssertEqual(status.historyState,"coverage_unknown")
        print("ARCHIVE_COST platform=ios advertised=100000 visited=5000 calls=\(calls) encoded_bytes=\(bytes) seconds=\(Date().timeIntervalSince(started)) checkpoint_bytes=\(payload.count)")
    }
    private final class Scope { var generation:UInt64=3;var current=true;var calls=0 }
    func testGenerationSwitchAfterHttpCannotWriteNewGenerationJob() async throws { try await guardScenario("generation") }
    func testAccountSwitchStopsOldOwnerWithoutNetworkRetry() async throws { try await guardScenario("account") }
    func testRepeatedCursorPersistsProgressAndStopsWithoutRetryLoop() async throws { try await guardScenario("cursor") }
    func testStaleCursorHttpRejectionKeepsDurableScope() async throws { try await guardScenario("stale") }
    func testCrossScopeCursorHttpRejectionKeepsDurableScope() async throws { try await guardScenario("cross_scope") }
    func testRestoreCode6RemainsPausedAcrossAutomaticEnqueue() async throws { try await guardScenario("denied") }
    private func guardScenario(_ mode:String) async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("apin-guard-\(UUID().uuidString)")
        let namespace="guard-\(UUID().uuidString)";let cid="messaging:project:paging-fixture";let scope=Scope()
        let keys=try generateRecoveryKeys();let vault=try createRecoveryVault(pin:"12345678",keys:keys)
        let recovery=try E2eeArchiveRecovery(namespace:namespace,root:root,userId:"fixture",api:nil,isCurrentAccount:{scope.current},generation:{_ in scope.generation},apply:{_,_,_,_,_ in XCTFail("No crypto without material")},requestOverride:{endpoint in
            switch endpoint.path {
            case .recoveryVault:return .object(["vault_bytes":.bytes(vault),"revision":.uint(1),"recovery_key_id":.string(keys.keyId)])
            case .epochArchive(_, .availability):
                if mode=="denied" {throw ClientError(with:ErmisApiError(type:.noPermission,statusCode:403,message:"fixture denied"))}
                return .object(["epochs":.array([]),"has_more":.bool(false)])
            case .epochArchive(_, .material):return .object(["blobs":.array([]),"wraps":.array([]),"snapshots":.object([:])])
            case .epochArchive(_, .ciphertexts):
                scope.calls += 1
                if mode=="generation" {scope.generation=4}
                if mode=="account" {scope.current=false}
                let cursorMode=["cursor","stale","cross_scope"].contains(mode)
                let query=try XCTUnwrap(endpoint.body as? E2eeArchiveWire)
                if ["stale","cross_scope"].contains(mode),let cursor=query["cursor"]["last_event_key"].string {
                    XCTAssertEqual(cursor,"reused-opaque+/=")
                    throw ClientError(with:ErmisApiError(type:.inputNotCorrect,statusCode:400,message:"fixture cursor rejected"))
                }
                let messages:[E2eeArchiveWire]=cursorMode ? [.object(["message_id":.string("00000000-0000-4000-8000-000000000001"),"cid":.string(cid),"group_generation":.uint(3),"mls_epoch":.uint(0),"mls_ciphertext":.bytes(Data([1]))])] : []
                return .object(["ciphertexts":.array(messages),"has_more":.bool(cursorMode),"next_cursor":cursorMode ? .object(["last_event_key":.string("reused-opaque+/=")]) : .null])
            default:throw E2eeArchiveError.invalidData
            }
        })
        defer {try? recovery.stop(clearUnlock:false)}
        try await recovery.unlockRecoveryVault("12345678");try await recovery.enqueueRestoreDurably(cid:cid,fromEpoch:0,toEpoch:5,requestId:"fixture-login")
        let journal=try RecoveryJournal(path:root.appendingPathComponent("MLSArchive/\(namespace)/journal.db").path)
        let deadline=Date().addingTimeInterval(10)
        func finished() throws -> Bool {
            if mode=="account" {return !scope.current}
            return try journal.get(key:"restore:\(cid):3")?.status == (mode=="generation" ? "superseded" : mode=="denied" ? "permission_denied" : "coverage_unknown")
        }
        while try !finished() {
            guard Date()<deadline else {XCTFail("Scoped guard timed out");return}
            try await Task.sleep(nanoseconds:50_000_000)
        }
        XCTAssertNil(try journal.get(key:"restore:\(cid):4"))
        if mode=="account" {
            do {try await recovery.enqueueRestoreDurably(cid:cid);XCTFail("Ended account cannot acknowledge enqueue")} catch {}
        }
        if ["cursor","stale","cross_scope"].contains(mode) {
            let payload=try XCTUnwrap(journal.get(key:"restore_epoch:\(cid):3:0")?.payload)
            let progress=try XCTUnwrap(JSONSerialization.jsonObject(with:payload) as? [String:Any])
            XCTAssertEqual(progress["discovered"] as? Int,1)
            XCTAssertEqual((progress["outcomes"] as? [String:String])?.count,1)
            XCTAssertEqual((progress["reasons"] as? [String:Int])?["cursor_rejected"],1)
            XCTAssertEqual(try journal.get(key:"restore:\(cid):3")?.lastError,"cursor_rejected")
        }
        let calls=scope.calls
        if mode=="denied" {
            try await recovery.enqueueRestoreDurably(cid:cid,fromEpoch:0,toEpoch:5)
            let paused=try XCTUnwrap(journal.get(key:"restore:\(cid):3"));XCTAssertEqual(paused.status,"permission_denied")
            let status=await recovery.currentStatus();XCTAssertFalse(status.requiresPinChannels.contains(cid))
        }
        if ["cursor","stale","cross_scope"].contains(mode) {
            let before=try XCTUnwrap(journal.get(key:"restore:\(cid):3")?.payload)
            try await recovery.enqueueRestoreDurably(cid:cid,fromEpoch:0,toEpoch:5,requestId:"fixture-login")
            try await recovery.enqueueRestoreDurably(cid:cid,fromEpoch:0,toEpoch:5)
            try await recovery.enqueueRestoreDurably(cid:cid,fromEpoch:1,toEpoch:3)
            XCTAssertEqual(try journal.get(key:"restore:\(cid):3")?.payload,before)
        }
        try await Task.sleep(nanoseconds:1_500_000_000)
        XCTAssertEqual(scope.calls,calls);XCTAssertEqual(calls,["cursor","stale","cross_scope"].contains(mode) ? 4 : mode=="denied" ? 0 : 1)
    }
    func testSixHundredIdsOpaqueCursorAndOldCheckpointUpgrade() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("apin-\(UUID().uuidString)")
        let namespace="test-\(UUID().uuidString)"; let cid="messaging:project:paging-fixture"; let user="fixture"
        let keys=try generateRecoveryKeys();let vault=try createRecoveryVault(pin:"12345678",keys:keys)
        let ids=(0..<620).map { String(format:"00000000-0000-4000-8000-%012d",$0) }
        let recovery=try E2eeArchiveRecovery(namespace:namespace,root:root,userId:user,api:nil,isCurrentAccount:{true},generation:{_ in 3},
            apply:{_,_,_,_,_ in XCTFail("Missing material cannot invoke crypto")},requestOverride:{endpoint in
                switch endpoint.path {
                case .recoveryVault:return .object(["vault_bytes":.bytes(vault),"revision":.uint(1),"recovery_key_id":.string(keys.keyId)])
                case .epochArchive(_, .availability):return .object(["epochs":.array([]),"has_more":.bool(false)])
                case .epochArchive(_, .material):return .object(["blobs":.array([]),"wraps":.array([]),"snapshots":.object([:])])
                case .epochArchive(_, .ciphertexts):
                    let query=try XCTUnwrap(endpoint.body as? E2eeArchiveWire)
                    XCTAssertEqual(query["limit"].number,100);XCTAssertEqual(query["group_generation"].number,3)
                    let token=query["cursor"]["last_event_key"].string
                    let offset=token.flatMap { Int($0.split(separator:":").last ?? "") } ?? 0
                    if let token { XCTAssertEqual(token,"opaque+/=scope:\(query["epoch_to"].number ?? 99):\(offset)") }
                    let selected=Array(ids.dropFirst(offset).prefix(100));let more=offset+selected.count<ids.count
                    return .object(["ciphertexts":.array(selected.map { .object(["message_id":.string($0),"cid":.string(cid),"group_generation":.uint(3),"mls_epoch":.uint(0),"mls_ciphertext":.bytes(Data([1]))]) }),
                        "has_more":.bool(more),"next_cursor":more ? .object(["last_event_key":.string("opaque+/=scope:\(query["epoch_to"].number ?? 99):\(offset+selected.count)")]) : .null])
                default:throw E2eeArchiveError.invalidData
                }
            })
        defer { try? recovery.stop() }
        let journal=try RecoveryJournal(path:root.appendingPathComponent("MLSArchive/\(namespace)/journal.db").path)
        func row(_ key:String,kind:String,payload:String,status:String)->RecoveryJournalEntry {
            .init(key:key,kind:kind,cid:cid,groupGeneration:3,epoch:0,scope:"",payload:Data(payload.utf8),status:status,retryCount:0,createdAt:1,nextRetryAt:0,lastError:nil)
        }
        try journal.put(entry:row("restore:\(cid):3",kind:"restore",payload:#"{"from":0,"to":5,"cycle":"old-cycle"}"#,status:"queued"))
        try journal.put(entry:row("restore_epoch:\(cid):3:0",kind:"restore_epoch",payload:#"{"restored":620,"hasGaps":false,"cycle":"old-cycle"}"#,status:"done"))
        try await recovery.unlockRecoveryVault("12345678")
        let deadline=Date().addingTimeInterval(20)
        while try journal.get(key:"restore:\(cid):3")?.status != "done_with_gaps" {
            guard Date()<deadline else { XCTFail("Paging fixture timed out");return }
            try await Task.sleep(nanoseconds:50_000_000)
        }
        let payload=try XCTUnwrap(journal.get(key:"restore_epoch:\(cid):3:0")?.payload)
        let progress=try XCTUnwrap(JSONSerialization.jsonObject(with:payload) as? [String:Any])
        XCTAssertEqual(progress["validatorVersion"] as? Int,2)
        XCTAssertEqual(progress["restored"] as? Int,0);XCTAssertEqual(progress["discovered"] as? Int,620)
        let outcomes=try XCTUnwrap(progress["outcomes"] as? [String:String])
        XCTAssertEqual(Set(outcomes.keys),Set(ids));XCTAssertTrue(outcomes.values.allSatisfy {$0=="material_unavailable"})
        XCTAssertEqual((progress["reasons"] as? [String:Int])?["material_unavailable"],620)
        let reopened=try RecoveryJournal(path:root.appendingPathComponent("MLSArchive/\(namespace)/journal.db").path)
        XCTAssertEqual(try reopened.get(key:"restore_epoch:\(cid):3:0")?.payload,payload)
    }
}
