import XCTest
@testable import ErmisChat

final class MlsRecoveryControlTests: XCTestCase {
    private func control(_ revision: Any = "1", action: String = "repair",
                         deadline: Any = "2026-11-02T00:15:00.123456789Z") -> [String: Any] {
        ["incident_id": "00000000-0000-4000-8000-000000000001", "recovery_action": action,
         "recovery_revision": revision, "repair_retry_until": deadline]
    }

    private func generation(_ control: [String: Any]) throws -> Data {
        var json: [String: Any] = ["group_generation": 1, "group_id": "AQID", "current_epoch": 2,
            "membership_version": "fixture", "state": "activated", "reason": "delivery_pending",
            "retryable": true, "first_unresolved_at": NSNull(), "incident_deadline_at": NSNull(),
            "capability": ["protocol_version": 1, "automatic_enabled": true, "repair_timeout_seconds": 900,
                           "max_group_info_bytes": 1048576, "max_ratchet_tree_bytes": 1048576,
                           "max_welcome_recipients": 200, "max_welcome_bytes": 6291456]]
        json.merge(control) { _, next in next }
        return try JSONSerialization.data(withJSONObject: json)
    }

    func testGenerationRejectsMalformedControlsInsteadOfIgnoringAuthority() throws {
        for invalid: Any in [1, -1, NSNull(), "", "01", "+1", "-1", "1.0", " 1", "18446744073709551616"] {
            XCTAssertThrowsError(try JSONDecoder().decode(MlsGenerationStatePayload.self,
                                                          from: generation(control(invalid))), "revision \(invalid)")
        }
        var partial = control()
        partial.removeValue(forKey: "repair_retry_until")
        XCTAssertThrowsError(try JSONDecoder().decode(MlsGenerationStatePayload.self, from: generation(partial)))
        var missingIncident = control()
        missingIncident["incident_id"] = NSNull()
        XCTAssertThrowsError(try JSONDecoder().decode(MlsGenerationStatePayload.self, from: generation(missingIncident)))
        XCTAssertThrowsError(try JSONDecoder().decode(MlsGenerationStatePayload.self,
                                                      from: generation(control(action: "unknown"))))
    }

    private func checkpoint(_ revision: String = "1", generation: UInt64 = 1,
                            action: String = "repair", device: String = "ios-fixture",
                            groupId: Data = Data([1, 2, 3]), deadline: String = "2026-11-02T00:15:00Z") throws -> MlsRecoveryControlCheckpoint {
        let payload = try JSONDecoder().decode(MlsRecoveryControl.self,
            from: JSONSerialization.data(withJSONObject: control(revision, action: action, deadline: deadline)))
        return .init(userId: "fixture", deviceId: device, signerSha256: String(repeating: "a", count: 64),
                     cid: "team:fixture", generation: generation, groupId: groupId, control: payload)
    }

    func testRevisionPreservesFullUnsignedDomainAndCanonicalSpelling() throws {
        for revision in ["0", "1", "9223372036854775808", "18446744073709551615"] {
            let state = try JSONDecoder().decode(MlsGenerationStatePayload.self, from: generation(control(revision)))
            // Full payload must validate; revision never passes through an NSNumber or Int64.
            XCTAssertEqual(state.groupGeneration, 1)
            XCTAssertEqual(try checkpoint(revision).control.revision, revision)
        }
    }

    func testMonotoneRevisionAndGenerationRejectImmutableConflicts() throws {
        let current = try checkpoint("18446744073709551615")
        XCTAssertEqual(try checkpoint("1").selected(after: current), current)
        XCTAssertEqual(try checkpoint("1", generation: 2).selected(after: current).generation, 2)
    }

    func testSameRevisionControlAndGroupBindingCannotChange() throws {
        let previous = try checkpoint()
        XCTAssertThrowsError(try checkpoint(action: "manual_intervention_required").selected(after: previous))
        XCTAssertThrowsError(try checkpoint(deadline: "2026-11-02T00:16:00Z").selected(after: previous))
        XCTAssertThrowsError(try checkpoint("2", groupId: Data([9])).selected(after: previous))
        XCTAssertEqual(try checkpoint("0", generation: 2).selected(after: previous).generation, 2)
        XCTAssertEqual(try checkpoint(device: "replacement").selected(after: previous).deviceId, "replacement")
    }

    func testEvidenceRemainsAdmissibleAfterImmutableDeadline() throws {
        XCTAssertTrue(try checkpoint(action: "repair").control.acceptsEvidence)
        XCTAssertTrue(try checkpoint(action: "waiting_for_evidence").control.acceptsEvidence)
        XCTAssertFalse(try checkpoint(action: "manual_intervention_required").control.acceptsEvidence)
        XCTAssertFalse(try checkpoint(action: "none").control.acceptsEvidence)
        for deadline in ["tomorrow", "2026-11-02", "2026-11-02T00:15:00+07:00", "1970-01-01T00:00:00Z"] {
            XCTAssertThrowsError(try checkpoint(deadline: deadline))
        }
    }

    func testSqliteReopenStaleConflictAndOwnerIsolation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".db")
        defer { try? FileManager.default.removeItem(at: url) }
        let current = try checkpoint("18446744073709551615")
        do {
            let store = try MlsRecoveryControlStore(url: url)
            XCTAssertEqual(try store.observe(current, assertCurrent: {}), current)
        }
        let store = try MlsRecoveryControlStore(url: url)
        XCTAssertEqual(try store.observe(checkpoint("1"), assertCurrent: {}), current)
        XCTAssertThrowsError(try store.observe(checkpoint("18446744073709551615", action: "manual_intervention_required"), assertCurrent: {}))
        let replacement = try checkpoint(device: "replacement")
        XCTAssertEqual(try store.observe(replacement, assertCurrent: {}), replacement)
        XCTAssertEqual(try store.load(userId: current.userId, deviceId: current.deviceId,
                                      signerSha256: current.signerSha256, cid: current.cid), current)
    }

    func testOwnerReplacementBeforeCommitRollsBack() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".db")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try MlsRecoveryControlStore(url: url)
        let original = try checkpoint()
        _ = try store.observe(original, assertCurrent: {})
        var checks = 0
        XCTAssertThrowsError(try store.observe(checkpoint("2"), assertCurrent: {
            checks += 1
            if checks == 2 { throw MlsRecoveryControlError.invalidMetadata }
        }))
        XCTAssertEqual(try store.load(userId: original.userId, deviceId: original.deviceId,
                                      signerSha256: original.signerSha256, cid: original.cid), original)
    }
    func testNullableAuthorityKeysSurviveSqliteCommitAndReopen() throws {
        let data = try JSONSerialization.data(withJSONObject: ["incident_id": NSNull(), "recovery_action": "none",
            "recovery_revision": "0", "repair_retry_until": NSNull()])
        let authority = try JSONDecoder().decode(MlsRecoveryControl.self, from: data)
        let record = MlsRecoveryControlCheckpoint(userId: "fixture", deviceId: "ios-fixture",
            signerSha256: String(repeating: "a", count: 64), cid: "team:project:null-control",
            generation: 0, groupId: nil, control: authority)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".db")
        defer { try? FileManager.default.removeItem(at: url) }
        do { XCTAssertEqual(try MlsRecoveryControlStore(url: url).observe(record, assertCurrent: {}), record) }
        XCTAssertEqual(try MlsRecoveryControlStore(url: url).load(userId: record.userId, deviceId: record.deviceId,
            signerSha256: record.signerSha256, cid: record.cid), record)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(authority)) as! [String: Any]
        XCTAssertTrue(encoded["incident_id"] is NSNull)
        XCTAssertTrue(encoded["repair_retry_until"] is NSNull)
    }

}
