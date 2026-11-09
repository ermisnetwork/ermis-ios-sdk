import Foundation

enum MlsRecoveryControlError: Error, Equatable {
    case invalidMetadata
    case revisionConflict
    case generationBindingConflict
}

/// Server authority, separate from a successful operation receipt. Keep the wire revision as
/// a decimal string: JSON numbers and signed integers cannot represent its complete domain.
struct MlsRecoveryControl: Codable, Equatable {
    enum Action: String, Codable {
        case none, repair
        case waitingForEvidence = "waiting_for_evidence"
        case manualInterventionRequired = "manual_intervention_required"
    }

    let incidentId: String?
    let action: Action
    let revision: String
    let repairRetryUntil: String?

    enum CodingKeys: String, CodingKey {
        case incidentId = "incident_id"
        case action = "recovery_action"
        case revision = "recovery_revision"
        case repairRetryUntil = "repair_retry_until"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Nullable keys are still required. Partial controls must never become legacy absence.
        incidentId = try container.decode(String?.self, forKey: .incidentId)
        action = try container.decode(Action.self, forKey: .action)
        revision = try container.decode(String.self, forKey: .revision)
        repairRetryUntil = try container.decode(String?.self, forKey: .repairRetryUntil)
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // These nullable wire keys remain required in durable records as well. Synthesized
        // Encodable would omit nil, producing a checkpoint that our strict decoder rejects.
        try container.encode(incidentId, forKey: .incidentId)
        try container.encode(action, forKey: .action)
        try container.encode(revision, forKey: .revision)
        try container.encode(repairRetryUntil, forKey: .repairRetryUntil)
    }

    static func decodeIfPresent(from decoder: Decoder) throws -> MlsRecoveryControl? {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard [CodingKeys.incidentId, .action, .revision, .repairRetryUntil].contains(where: container.contains) else {
            return nil
        }
        return try MlsRecoveryControl(from: decoder)
    }

    func validate() throws {
        guard let value = UInt64(revision), String(value) == revision,
              revision.utf8.allSatisfy({ (48...57).contains($0) }),
              incidentId.map({ UUID(uuidString: $0) != nil }) ?? (action == .none) else {
            throw MlsRecoveryControlError.invalidMetadata
        }
        if let deadline = repairRetryUntil {
            guard deadline.utf8.count <= 40,
                  deadline.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|\+00:00)$"#,
                                 options: .regularExpression) != nil else {
                throw MlsRecoveryControlError.invalidMetadata
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let fractional = formatter.date(from: deadline)
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = fractional ?? formatter.date(from: deadline), date.timeIntervalSince1970 > 0 else {
                throw MlsRecoveryControlError.invalidMetadata
            }
        }
    }

    var acceptsEvidence: Bool { action == .repair || action == .waitingForEvidence }
}

/// The owner and canonical group binding are part of the durable control identity.
struct MlsRecoveryControlCheckpoint: Codable, Equatable {
    let userId: String
    let deviceId: String
    let signerSha256: String
    let cid: String
    let generation: UInt64
    let groupId: Data?
    let control: MlsRecoveryControl

    func validate() throws {
        func validText(_ value: String, limit: Int) -> Bool {
            !value.isEmpty && value.utf8.count <= limit
                && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
        guard validText(userId, limit: 512), validText(deviceId, limit: 256), validText(cid, limit: 512),
              signerSha256.utf8.count == 64,
              signerSha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              generation == 0 ? groupId == nil : groupId.map({ (1...255).contains($0.count) }) == true else {
            throw MlsRecoveryControlError.invalidMetadata
        }
        try control.validate()
    }

    func selected(after previous: Self?) throws -> Self {
        try validate()
        guard let previous else { return self }
        try previous.validate()
        guard previous.userId == userId, previous.deviceId == deviceId,
              previous.signerSha256 == signerSha256, previous.cid == cid else { return self }
        let revision = UInt64(control.revision)!
        let oldRevision = UInt64(previous.control.revision)!
        if generation < previous.generation || (generation == previous.generation && revision < oldRevision) {
            return previous
        }
        if generation == previous.generation {
            guard groupId == previous.groupId else { throw MlsRecoveryControlError.generationBindingConflict }
            if revision == oldRevision {
                guard control == previous.control else { throw MlsRecoveryControlError.revisionConflict }
                return previous
            }
        }
        return self
    }
}
