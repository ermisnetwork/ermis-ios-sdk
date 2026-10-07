import Foundation
import XCTest
import ErmisShared
@testable import ErmisChat

final class MlsFieldLogDestinationTests: XCTestCase {
    private let marker = "mls_application_checkpoint stage=provider_saved result=stored"
    private let date = Date(timeIntervalSince1970: 1_791_184_000)

    private func withDirectory(_ test: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try test(directory)
    }

    func testBundledContractAndKnownMarker() throws {
        let contract = try XCTUnwrap(MlsFieldMarkerProjector.contract)
        XCTAssertEqual(contract.version, 1)
        XCTAssertEqual(contract.plain_patterns.count, 21)
        XCTAssertEqual(MlsFieldMarkerProjector.project(marker), marker)
    }

    func testSentinelAndIdentityFieldsNeverReachProjection() {
        let input = "[E2EE_JOIN] stage=welcome_fallback_requested source=scope_sync reason=no_matching_keypackage group_loaded=false cid=private-fixture user=private-fixture device=private-fixture trace_seq=123 epoch=123 error=private-fixture"
        XCTAssertEqual(MlsFieldMarkerProjector.project(input), "join_checkpoint stage=welcome_fallback_requested source=scope_sync reason=no_matching_keypackage group_loaded=false")
        XCTAssertEqual(MlsFieldMarkerProjector.project(marker + " token=private-fixture plaintext=private-fixture"), marker)
        XCTAssertNil(MlsFieldMarkerProjector.project("raw plaintext private-fixture"))
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
