import Foundation
import XCTest
import ErmisShared
@testable import ErmisChat

final class MlsFieldLogDestinationTests: XCTestCase {
    func testReadinessProgressContainsOnlyCycleCountsStatusAndDuration() {
        let marker = "session_readiness cycle=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa status=partial total=10 ready=8 blocked=1 failed=1 settled=10 scopes=10 elapsed_ms=123"
        XCTAssertTrue(MlsFieldMarkerProjector.isCanonical(marker))
        XCTAssertEqual(MlsFieldMarkerProjector.project(marker + " token=private-fixture plaintext=private-fixture"), marker)
        XCTAssertNil(MlsFieldMarkerProjector.project(marker.replacingOccurrences(of: "status=partial", with: "status=private-fixture")))
    }
    func testBootstrapCostMarkersExcludeIdentityBodiesAndUnboundedDimensions() {
        let id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let markers = ["session_http category=join_receipt stage=response_received request_id=\(id) status=200 bytes=128 elapsed_ms=15",
            "session_native request_id=\(id) stage=finished scopes=1 elapsed_ms=14",
            "session_bootstrap scope_sha256=" + String(repeating: "a", count: 64) + " stage=settled result=blocked elapsed_ms=100",
            "session_join operation_id=\(id) stage=accepted"]
        for marker in markers {
            XCTAssertTrue(MlsFieldMarkerProjector.isCanonical(marker))
            XCTAssertEqual(MlsFieldMarkerProjector.project(marker + " token=private-fixture provider=private-fixture plaintext=private-fixture"), marker)
        }
        XCTAssertNil(MlsFieldMarkerProjector.project("session_http category=private-fixture stage=response_received request_id=\(id) status=200 bytes=128 elapsed_ms=15"))
    }
    func testReadinessGuardMarkerKeepsOnlyScopeAliasAndFixedReason() {
        let prefix = "session_readiness_guard scope_sha256=" + String(repeating: "a", count: 64) + " reason="
        for reason in ["membership", "live_sync", "protocol", "membership_mutation", "group_missing", "group_nonoperational", "join_receipt"] {
            XCTAssertEqual(MlsFieldMarkerProjector.project(prefix + reason + " token=private-fixture"), prefix + reason)
        }
        XCTAssertNil(MlsFieldMarkerProjector.project(prefix + "private-fixture"))
    }
    func testProfileTimingMarkersProjectOnlyCountsAndDurations() {
        let id = "00000000-0000-4000-8000-000000000001"
        let markers = [
            "user_profile_load stage=store_finished request_id=\(id) count=7 elapsed_ms=123",
            "user_profile_http stage=network_admitted request_id=\(id) status=0 bytes=0 elapsed_ms=42",
            "user_profile_view scope=channels stage=bound request_id=\(id) count=7 loaded=7 elapsed_ms=125"
        ]
        for marker in markers {
            XCTAssertTrue(MlsFieldMarkerProjector.isCanonical(marker))
            XCTAssertEqual(MlsFieldMarkerProjector.project(marker + " name=private-fixture token=private-fixture"), marker)
            XCTAssertFalse(MlsFieldMarkerProjector.isCanonical(marker + " name=private-fixture"))
        }
        XCTAssertNil(MlsFieldMarkerProjector.project("user_profile_load stage=raw_profile name=private-fixture"))
    }
    func testRootChannelListViewMarkersKeepOnlyCountsAndTiming() {
        let marker = "channel_list_view scope=channels stage=bound request_id=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa count=94 elapsed_ms=143"
        XCTAssertEqual(MlsFieldMarkerProjector.project(marker + " plaintext=private-fixture"), marker)
        XCTAssertNil(MlsFieldMarkerProjector.project(marker.replacingOccurrences(of: "scope=channels", with: "scope=private-fixture")))
    }

    func testChannelListHttpMarkersKeepOnlyStatusSizeAndTiming() {
        let marker = "channel_list_http stage=response_received request_id=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa status=200 bytes=5428 elapsed_ms=63"
        XCTAssertEqual(MlsFieldMarkerProjector.project(marker + " Authorization=private-fixture body=private-fixture"), marker)
        XCTAssertTrue(MlsFieldMarkerProjector.isCanonical(marker))
        XCTAssertNil(MlsFieldMarkerProjector.project(marker.replacingOccurrences(of: "response_received", with: "private-fixture")))
        XCTAssertNil(MlsFieldMarkerProjector.project(marker.replacingOccurrences(of: "status=200", with: "status=private-fixture")))
    }

    func testChannelListTimingMarkersExcludePayloadAndUnboundedDimensions() {
        let marker = "channel_list_load stage=query_received request_id=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa count=3 elapsed_ms=182"
        XCTAssertEqual(MlsFieldMarkerProjector.project(marker + " token=private-fixture plaintext=private-fixture"), marker)
        XCTAssertTrue(MlsFieldMarkerProjector.isCanonical(marker))
        XCTAssertNil(MlsFieldMarkerProjector.project(marker.replacingOccurrences(of: "query_received", with: "private-fixture")))
        XCTAssertNil(MlsFieldMarkerProjector.project(marker.replacingOccurrences(of: "elapsed_ms=182", with: "elapsed_ms=1234567890123")))
    }

    func testKeyPackageContinuationMarkersKeepOnlyPublicMetadata() {
        let prefix = "keypackage_work operation=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa scope_sha256=" + String(repeating: "a", count: 64)
        let markers = ["keypackage_refill phase=started trigger=connection",
            "keypackage_refill phase=deferred delay_ms=60000",
            prefix + " phase=count remaining=0 target=100 delta=100 generation=1",
            prefix + " phase=upload batch_id=bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb count=100 attempt=1",
            prefix + " phase=ack batch_id=bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb stored=100",
            prefix + " phase=finished pending_batch=false"]
        for marker in markers {
            XCTAssertEqual(MlsFieldMarkerProjector.project(marker + " token=private-fixture plaintext=private-fixture"), marker)
            XCTAssertTrue(MlsFieldMarkerProjector.isCanonical(marker))
        }
        XCTAssertNil(MlsFieldMarkerProjector.project("keypackage_refill phase=started trigger=private-fixture"))
        XCTAssertNil(MlsFieldMarkerProjector.project(prefix.replacingOccurrences(of: String(repeating: "a", count: 64), with: "private-fixture") + " phase=finished pending_batch=false"))
    }
    func testTransportStagesKeepOnlyClosedMetadataAndBoundedCounters() {
        let marker = "mls_transport stage=read_failed operation_id=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa count=32 code=-1005"
        XCTAssertEqual(MlsFieldMarkerProjector.project(marker + " token=private-fixture url=private-fixture"), marker)
        XCTAssertTrue(MlsFieldMarkerProjector.isCanonical(marker))
        XCTAssertNil(MlsFieldMarkerProjector.project(marker.replacingOccurrences(of: "read_failed", with: "private-fixture")))
        XCTAssertNil(MlsFieldMarkerProjector.project(marker.replacingOccurrences(of: "count=32", with: "count=1234567890")))
        XCTAssertNil(MlsFieldMarkerProjector.project(marker.replacingOccurrences(of: "code=-1005", with: "code=-1234567")))
        XCTAssertNil(MlsFieldMarkerProjector.project(marker.replacingOccurrences(of: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", with: "private-fixture")))
    }
    private let marker = "mls_application_checkpoint stage=provider_saved result=stored"
    private let date = Date(timeIntervalSince1970: 1_791_184_000)

    private func withDirectory(_ test: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try test(directory)
    }

    func testIncomingStagesRemainCorrelatedAndExcludePrivateErrors() {
        for stage in ["socket_decoded", "event_queued", "event_persisted", "event_posted", "decrypt_started", "decrypt_succeeded", "decrypt_failed", "decoded_cache_saved", "ui_rendered", "ui_encrypted", "scope_blocked", "scope_page_failed"] {
            let marker = "mls_incoming stage=\(stage) uuid=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa cipher_sha256=" + String(repeating: "a", count: 64) + " error=crypto"
            XCTAssertEqual(MlsFieldMarkerProjector.project(marker + " plaintext=private-fixture token=private-fixture"), marker)
            XCTAssertTrue(MlsFieldMarkerProjector.isCanonical(marker))
            XCTAssertNil(MlsFieldMarkerProjector.project(marker.replacingOccurrences(of: "error=crypto", with: "error=private-fixture")))
        }
        XCTAssertEqual(MlsIncomingTrace.errorClass(NSError(domain: "private-fixture", code: 7)), "other")
    }

    func testComposerSubmissionKeepsOnlyClosedStageAndBooleans() {
        for stage in ["tap_received", "draft_busy", "draft_started", "draft_saved", "draft_failed", "controls_updated"] {
            let marker = "mls_composer_submit stage=\(stage) nonempty=true send_enabled=true send_hidden=false draft_pending=false"
            XCTAssertEqual(MlsFieldMarkerProjector.project(marker + " plaintext=private-fixture token=private-fixture"), marker)
            XCTAssertTrue(MlsFieldMarkerProjector.isCanonical(marker))
            XCTAssertNil(MlsFieldMarkerProjector.project(marker.replacingOccurrences(of: "nonempty=true", with: "nonempty=private-fixture")))
        }
        XCTAssertNil(MlsFieldMarkerProjector.project("mls_composer_submit stage=private-fixture nonempty=true send_enabled=true send_hidden=false draft_pending=false"))
    }

    func testBundledContractAndKnownMarker() throws {
        let contract = try XCTUnwrap(MlsFieldMarkerProjector.contract)
        XCTAssertEqual(contract.version, 1)
        XCTAssertEqual(Set(contract.plain_patterns).count, contract.plain_patterns.count)
        XCTAssertEqual(MlsFieldMarkerProjector.project(marker), marker)
    }

    func testJoinHttpStagesKeepOnlyStatusAndClosedEnums() {
        for stage in ["registration", "receipt", "commit"] {
            let marker = "mls_join_http stage=\(stage) result=response status=401"
            XCTAssertEqual(MlsFieldMarkerProjector.project(marker + " token=private-fixture"), marker)
            XCTAssertTrue(MlsFieldMarkerProjector.isCanonical(marker))
            XCTAssertFalse(MlsFieldMarkerProjector.isCanonical(marker + " token=private-fixture"))
        }
        XCTAssertNil(MlsFieldMarkerProjector.project("mls_join_http stage=arbitrary result=response status=401"))
        XCTAssertNil(MlsFieldMarkerProjector.project("mls_join_http stage=registration result=response status=2000"))
    }

    func testReadinessMarkersUseActualLifecycleRawValues() {
        for state in [E2eeChannelReadiness.restoring, .recovered, .historyIncomplete,
                      .waitingForRepair, .clientUpgradeRequired, .infrastructureRetryable] {
            let marker = "join_checkpoint stage=readiness_changed source=readiness readiness=\(state.rawValue)"
            XCTAssertEqual(MlsFieldMarkerProjector.project("[E2EE_JOIN] stage=readiness_changed source=readiness readiness=\(state.rawValue)"), marker)
            XCTAssertTrue(MlsFieldMarkerProjector.isCanonical(marker))
        }
    }

    func testMembershipBoundariesKeepOnlyBoundedMetadata() {
        let ack = "mls_membership_trace stage=ack action=add epoch=9 commit_hash=5715069c36b1"
        let leave = "mls_self_leave stage=group_deleted cid=team:project:qa-channel"
        let roster = "[MLS] state=ghost_roster_verified member_count=3 queued_count=2 inactive_count=1"
        for value in [ack, leave, roster] {
            XCTAssertEqual(MlsFieldMarkerProjector.project(value + " token=private-fixture plaintext=private-fixture"), value)
            XCTAssertFalse(MlsFieldMarkerProjector.isCanonical(value + " token=private-fixture"))
        }
        XCTAssertNil(MlsFieldMarkerProjector.project("mls_self_leave stage=unknown cid=team:project:qa-channel"))
        XCTAssertNil(MlsFieldMarkerProjector.project("mls_self_leave stage=ack cid=" + String(repeating: "a", count: 193)))
        XCTAssertNil(MlsFieldMarkerProjector.project(ack + "abcdef"))
    }

    func testSentinelAndIdentityFieldsNeverReachProjection() {
        let input = "[E2EE_JOIN] stage=welcome_fallback_requested source=scope_sync reason=no_matching_keypackage group_loaded=false cid=private-fixture user=private-fixture device=private-fixture trace_seq=123 epoch=123 error=private-fixture"
        XCTAssertEqual(MlsFieldMarkerProjector.project(input), "join_checkpoint stage=welcome_fallback_requested source=scope_sync reason=no_matching_keypackage group_loaded=false")
        XCTAssertEqual(MlsFieldMarkerProjector.project(marker + " token=private-fixture plaintext=private-fixture"), marker)
        XCTAssertNil(MlsFieldMarkerProjector.project("raw plaintext private-fixture"))
    }

    func testScopeCursorAndLongAndroidDeviceMarkersRemainBounded() {
        let device = "Android-device_0x166a7a6a11c0cd147a4e39ee81831b8b9253c412_1b2643e5-46c4-4db2-baef-2489ca56872b"
        let protocolMarker = "mls_membership_trace stage=protocol event_id=bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb epoch=4 sender_user=0x166a7a6a11c0cd147a4e39ee81831b8b9253c412 sender_device=\(device) commit_hash=7c6ed5eb9fbd"
        let cursor = "mls_scope_trace stage=removed_ignored cid=team:project:qa event_id=bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb created_at=2026-08-06T10:01:00.123456789Z"
        for marker in [protocolMarker, cursor] {
            XCTAssertEqual(MlsFieldMarkerProjector.project(marker + " token=private-fixture"), marker)
            XCTAssertTrue(MlsFieldMarkerProjector.isCanonical(marker))
            XCTAssertFalse(MlsFieldMarkerProjector.isCanonical(marker + " token=private-fixture"))
        }
        XCTAssertNil(MlsFieldMarkerProjector.project(cursor.replacingOccurrences(of: "removed_ignored", with: "unknown")))
        XCTAssertNil(MlsFieldMarkerProjector.project(protocolMarker.replacingOccurrences(of: device, with: String(repeating: "a", count: 193))))
    }

    func testStorageAndApplicationReadbackMarkersExcludePayloads() {
        let storage = "mls_storage_readback disk=true file_exists=true description_matches=true"
        let application = "mls_application_readback uuid=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa cipher_sha256=" + String(repeating: "a", count: 64) + " result=committed"
        for marker in [storage, application] {
            XCTAssertEqual(MlsFieldMarkerProjector.project(marker + " plaintext=private-fixture"), marker)
            XCTAssertTrue(MlsFieldMarkerProjector.isCanonical(marker))
            XCTAssertFalse(MlsFieldMarkerProjector.isCanonical(marker + " token=private-fixture"))
        }
        XCTAssertNil(MlsFieldMarkerProjector.project(application.replacingOccurrences(of: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", with: "private-fixture")))
        XCTAssertNil(MlsFieldMarkerProjector.project(storage.replacingOccurrences(of: "disk=true", with: "disk=unknown")))
    }

    func testUnknownEnumsAndDuplicateJoinFieldsRejected() {
        XCTAssertNil(MlsFieldMarkerProjector.project("[E2EE_JOIN] stage=unknown source=scope_sync"))
        XCTAssertNil(MlsFieldMarkerProjector.project("[E2EE_JOIN] stage=welcome_joined source=websocket source=scope_sync"))
        XCTAssertNil(MlsFieldMarkerProjector.project("mls_connection_failure category=offline_suffix"))
        XCTAssertEqual(MlsFieldMarkerProjector.project("[E2EE_JOIN] stage=welcome_joined source=websocket reason=private-fixture group_loaded=false_suffix"), "join_checkpoint stage=welcome_joined source=websocket")
    }

    func testNewlineAndOversizedMessagesRejected() {
        XCTAssertNil(MlsFieldMarkerProjector.project(marker + "\nprivate-fixture"))
        XCTAssertNil(MlsFieldMarkerProjector.project(marker + "\rprivate-fixture"))
        XCTAssertNil(MlsFieldMarkerProjector.project(marker + String(repeating: "a", count: 4096)))
        XCTAssertNil(MlsFieldMarkerProjector.project(String(repeating: "💜", count: 1025)))
    }

    func testCanonicalValidatorRejectsUnprojectedPayloads() {
        XCTAssertTrue(MlsFieldMarkerProjector.isCanonical("join_checkpoint stage=welcome_joined source=websocket group_loaded=true"))
        XCTAssertFalse(MlsFieldMarkerProjector.isCanonical(marker + " token=private-fixture"))
        XCTAssertFalse(MlsFieldMarkerProjector.isCanonical("join_checkpoint stage=welcome_joined source=websocket cid=private-fixture"))
    }

    func testDiskWriterPreservesEarlierMarkersAcrossReopen() throws {
        try withDirectory { directory in
            try MlsFieldLogWriter(directoryURL: directory).append(marker: marker, date: date)
            try MlsFieldLogWriter(directoryURL: directory).append(marker: "mls_cached_session_checkpoint result=admitted", date: date.addingTimeInterval(1))
            let content = try String(contentsOf: directory.appendingPathComponent("current.log"), encoding: .utf8)
            XCTAssertEqual(content.split(separator: "\n").count, 2)
            XCTAssertTrue(content.contains(marker))
            XCTAssertTrue(content.contains("mls_cached_session_checkpoint result=admitted"))
            XCTAssertTrue(content.hasSuffix("\n"))
        }
    }

    func testRotationBoundsBothFilesAndKeepsCompleteLines() throws {
        try withDirectory { directory in
            let writer = try MlsFieldLogWriter(directoryURL: directory, maximumBytes: 512)
            for index in 0..<20 { try writer.append(marker: marker, date: date.addingTimeInterval(Double(index))) }
            for name in ["current.log", "previous.log"] {
                let content = try Data(contentsOf: directory.appendingPathComponent(name))
                XCTAssertLessThanOrEqual(content.count, 512)
                let lines = try XCTUnwrap(String(data: content, encoding: .utf8))
                XCTAssertTrue(lines.hasSuffix("\n"))
                for line in lines.split(separator: "\n") {
                    XCTAssertTrue(line.hasSuffix(marker))
                }
            }
        }
    }

    func testOversizedPreexistingDiagnosticFileIsNotRetained() throws {
        try withDirectory { directory in
            let writer = try MlsFieldLogWriter(directoryURL: directory, maximumBytes: 512)
            try Data(repeating: 65, count: 1024).write(to: directory.appendingPathComponent("current.log"))
            try writer.append(marker: marker, date: date)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("previous.log").path))
            XCTAssertLessThan(try Data(contentsOf: directory.appendingPathComponent("current.log")).count, 512)
        }
    }

    func testConcurrentWritesKeepEveryCompleteMarker() throws {
        try withDirectory { directory in
            let writers = try (0..<3).map { _ in try MlsFieldLogWriter(directoryURL: directory) }
            DispatchQueue.concurrentPerform(iterations: 100) { index in
                do { try writers[index % writers.count].append(marker: self.marker, date: self.date.addingTimeInterval(Double(index))) }
                catch { XCTFail("Diagnostic append unexpectedly failed") }
            }
            let content = try String(contentsOf: directory.appendingPathComponent("current.log"), encoding: .utf8)
            XCTAssertEqual(content.split(separator: "\n").count, 100)
            XCTAssertEqual(content.components(separatedBy: marker).count, 101)
        }
    }

    func testInvalidMarkerAndFilesystemTargetFailWithoutWritingRawData() throws {
        try withDirectory { directory in
            let writer = try MlsFieldLogWriter(directoryURL: directory)
            XCTAssertThrowsError(try writer.append(marker: marker + " token=private-fixture", date: date))
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("current.log").path))
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("current.log"), withIntermediateDirectories: true)
            XCTAssertThrowsError(try writer.append(marker: marker, date: date))
        }
    }

    func testActualLoggerDestinationPersistsOnlyProjectedMessage() throws {
        try withDirectory { directory in
            let destination = MlsFieldLogDestination(directoryURL: directory)
            let logger = Logger(identifier: "private-fixture", destinations: [destination])
            logger.info("raw private-fixture", subsystems: .mls)
            logger.info(marker + " token=private-fixture", subsystems: .mls)
            let output = directory.appendingPathComponent("current.log")
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                (try? String(contentsOf: output, encoding: .utf8))?.contains(self.marker) == true
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
            let content = try String(contentsOf: output, encoding: .utf8)
            XCTAssertFalse(content.contains("private-fixture"))
            XCTAssertEqual(content.split(separator: "\n").count, 2)
            XCTAssertTrue(content.contains("mls_field_log_checkpoint result=started"))
        }
    }

    func testFailedWriteThenRecoveryLeavesFixedFailureMarker() throws {
        try withDirectory { directory in
            XCTAssertTrue(FileManager.default.createFile(atPath: directory.path, contents: Data()))
            let logger = Logger(destinations: [MlsFieldLogDestination(directoryURL: directory)])
            logger.info(marker, subsystems: .mls)
            _ = logger.destinations // Wait for the serialized destination callback to finish.
            try FileManager.default.removeItem(at: directory)
            logger.info(marker, subsystems: .mls)
            _ = logger.destinations
            let content = try String(contentsOf: directory.appendingPathComponent("current.log"), encoding: .utf8)
            XCTAssertTrue(content.contains("mls_field_log_checkpoint result=write_failed"))
            XCTAssertTrue(content.contains(marker))
        }
    }
}
