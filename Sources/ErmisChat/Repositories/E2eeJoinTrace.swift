//
// Copyright 2026 Ermis Inc.
//

import Foundation
import open_mls_ios

/// Privacy-safe diagnostics for Welcome/external-join and scope-sync lifecycle races.
///
/// Channel, user, device, event, commit, receipt identifiers and identity-derived aliases never
/// enter the rendered line.
enum E2eeJoinTrace {
    struct Context {
        init(cid: String) {
            _ = cid
        }

        func info(
            stage: String,
            source: String,
            protocolType: String? = nil,
            result: String? = nil,
            reason: String? = nil,
            receipt: String? = nil,
            readiness: String? = nil,
            groupLoaded: Bool? = nil,
            targetedAtCurrentUser: Bool? = nil,
            externalJoinScheduled: Bool? = nil,
            deferredSync: Bool? = nil,
            eventEpoch: Int? = nil,
            localEpoch: UInt64? = nil,
            firstDecryptableEpoch: Int64? = nil,
            retriesRemaining: Int? = nil,
            delaySeconds: Int? = nil
        ) {
            log.info(
                E2eeJoinTrace.makeLine(
                    stage: stage,
                    source: source,
                    context: self,
                    protocolType: protocolType,
                    result: result,
                    reason: reason,
                    receipt: receipt,
                    readiness: readiness,
                    groupLoaded: groupLoaded,
                    targetedAtCurrentUser: targetedAtCurrentUser,
                    externalJoinScheduled: externalJoinScheduled,
                    deferredSync: deferredSync,
                    eventEpoch: eventEpoch,
                    localEpoch: localEpoch,
                    firstDecryptableEpoch: firstDecryptableEpoch,
                    retriesRemaining: retriesRemaining,
                    delaySeconds: delaySeconds
                ),
                subsystems: .mls
            )
        }

        func failure(
            stage: String,
            source: String,
            error: Error,
            protocolType: String? = nil,
            receipt: String? = nil,
            groupLoaded: Bool? = nil,
            eventEpoch: Int? = nil,
            localEpoch: UInt64? = nil
        ) {
            log.error(
                E2eeJoinTrace.makeLine(
                    stage: stage,
                    source: source,
                    context: self,
                    protocolType: protocolType,
                    receipt: receipt,
                    groupLoaded: groupLoaded,
                    eventEpoch: eventEpoch,
                    localEpoch: localEpoch,
                    error: error
                ),
                subsystems: .mls
            )
        }
    }

    private static let lock = NSLock()
    private static var nextTraceSequence: UInt64 = 0

    private static func traceSequence() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        nextTraceSequence &+= 1
        return nextTraceSequence
    }

    static func makeLine(
        stage: String,
        source: String,
        context: Context,
        traceSequence: UInt64? = nil,
        protocolType: String? = nil,
        result: String? = nil,
        reason: String? = nil,
        receipt: String? = nil,
        readiness: String? = nil,
        groupLoaded: Bool? = nil,
        targetedAtCurrentUser: Bool? = nil,
        externalJoinScheduled: Bool? = nil,
        deferredSync: Bool? = nil,
        eventEpoch: Int? = nil,
        localEpoch: UInt64? = nil,
        firstDecryptableEpoch: Int64? = nil,
        retriesRemaining: Int? = nil,
        delaySeconds: Int? = nil,
        error: Error? = nil
    ) -> String {
        var fields = [
            "[E2EE_JOIN]",
            "stage=\(safeToken(stage))",
            "source=\(safeToken(source))",
            "trace_seq=\(traceSequence ?? self.traceSequence())",
        ]
        _ = context
        appendToken(protocolType, name: "protocol_type", to: &fields)
        appendToken(result, name: "result", to: &fields)
        appendToken(reason, name: "reason", to: &fields)
        appendToken(receipt, name: "receipt", to: &fields)
        appendToken(readiness, name: "readiness", to: &fields)
        if let groupLoaded { fields.append("group_loaded=\(groupLoaded)") }
        if let targetedAtCurrentUser { fields.append("targeted_current_user=\(targetedAtCurrentUser)") }
        if let externalJoinScheduled { fields.append("external_join_scheduled=\(externalJoinScheduled)") }
        if let deferredSync { fields.append("deferred_sync=\(deferredSync)") }
        if let eventEpoch { fields.append("event_epoch=\(eventEpoch)") }
        if let localEpoch { fields.append("local_epoch=\(localEpoch)") }
        if let firstDecryptableEpoch { fields.append("first_decryptable_epoch=\(firstDecryptableEpoch)") }
        if let retriesRemaining { fields.append("retries_remaining=\(retriesRemaining)") }
        if let delaySeconds { fields.append("delay_seconds=\(delaySeconds)") }
        if let error { fields.append("error_category=\(errorCategory(error))") }
        return fields.joined(separator: " ")
    }

    private static func appendToken(_ value: String?, name: String, to fields: inout [String]) {
        guard let value else { return }
        fields.append("\(name)=\(safeToken(value))")
    }

    private static func safeToken(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let token = String(value.unicodeScalars.prefix(64).map {
            allowed.contains($0) ? Character(String($0)) : "_"
        })
        return token.isEmpty ? "unknown" : token
    }

    private static func errorCategory(_ error: Error) -> String {
        if error is MlsError { return "mls" }
        if error is ErmisApiError { return "api" }
        switch (error as NSError).domain {
        case NSURLErrorDomain:
            return "transport"
        case NSCocoaErrorDomain:
            return "storage"
        default:
            return "other"
        }
    }
}
