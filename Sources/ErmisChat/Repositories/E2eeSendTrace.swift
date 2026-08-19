//
// Copyright 2026 Ermis Inc.
//

import ErmisShared
import Foundation

/// Privacy-safe, correlated diagnostics for the outbound E2EE message pipeline.
///
/// Keep this deliberately metadata-only. In particular, never add plaintext,
/// ciphertext, AAD, keys, attachment URLs, sticker URLs, grant URLs, or server
/// error messages to this trace.
enum E2eeSendTrace {
    struct Context {
        let messageId: MessageId
        let cid: ChannelId
        let groupCid: String?
        let startedAtNanoseconds: UInt64

        init(
            messageId: MessageId,
            cid: ChannelId,
            groupCid: String? = nil,
            startedAtNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
        ) {
            self.messageId = messageId
            self.cid = cid
            self.groupCid = groupCid
            self.startedAtNanoseconds = startedAtNanoseconds
        }

        func scoped(to groupCid: String) -> Context {
            Context(
                messageId: messageId,
                cid: cid,
                groupCid: groupCid,
                startedAtNanoseconds: startedAtNanoseconds
            )
        }

        func info(
            stage: String,
            epoch: UInt64? = nil,
            payloadBytes: Int? = nil,
            ciphertextBytes: Int? = nil,
            queueWaitMilliseconds: UInt64? = nil,
            operationMilliseconds: UInt64? = nil,
            httpStatus: Int? = nil,
            apiCode: Int? = nil,
            reusedIntent: Bool? = nil,
            authenticatedAAD: Bool? = nil
        ) {
            log.info(
                E2eeSendTrace.makeLine(
                    stage: stage,
                    context: self,
                    epoch: epoch,
                    payloadBytes: payloadBytes,
                    ciphertextBytes: ciphertextBytes,
                    queueWaitMilliseconds: queueWaitMilliseconds,
                    operationMilliseconds: operationMilliseconds,
                    httpStatus: httpStatus,
                    apiCode: apiCode,
                    reusedIntent: reusedIntent,
                    authenticatedAAD: authenticatedAAD
                ),
                subsystems: .mls
            )
        }

        func failure(
            stage: String,
            error: Error,
            epoch: UInt64? = nil,
            operationMilliseconds: UInt64? = nil
        ) {
            log.error(
                E2eeSendTrace.makeLine(
                    stage: stage,
                    context: self,
                    epoch: epoch,
                    operationMilliseconds: operationMilliseconds,
                    error: error
                ),
                subsystems: .mls
            )
        }
    }

    static func nowNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    static func elapsedMilliseconds(since start: UInt64) -> UInt64 {
        let now = nowNanoseconds()
        guard now >= start else { return 0 }
        return (now - start) / 1_000_000
    }

    /// Builds a deterministic line so diagnostics can be filtered in Console or
    /// an exported TestFlight log using `[E2EE_SEND] message_id=<id>`.
    static func makeLine(
        stage: String,
        context: Context,
        epoch: UInt64? = nil,
        payloadBytes: Int? = nil,
        ciphertextBytes: Int? = nil,
        queueWaitMilliseconds: UInt64? = nil,
        operationMilliseconds: UInt64? = nil,
        httpStatus: Int? = nil,
        apiCode: Int? = nil,
        reusedIntent: Bool? = nil,
        authenticatedAAD: Bool? = nil,
        error: Error? = nil
    ) -> String {
        var fields = [
            "[E2EE_SEND]",
            "stage=\(safeToken(stage))",
            "message_id=\(safeToken(context.messageId))",
            "cid=\(safeToken(context.cid.rawValue))",
        ]

        if let groupCid = context.groupCid {
            fields.append("group_cid=\(safeToken(groupCid))")
        }
        if let epoch {
            fields.append("epoch=\(epoch)")
        }
        if let payloadBytes {
            fields.append("payload_bytes=\(payloadBytes)")
        }
        if let ciphertextBytes {
            fields.append("ciphertext_bytes=\(ciphertextBytes)")
        }
        if let queueWaitMilliseconds {
            fields.append("queue_wait_ms=\(queueWaitMilliseconds)")
        }
        if let operationMilliseconds {
            fields.append("operation_ms=\(operationMilliseconds)")
        }
        if let httpStatus {
            fields.append("http_status=\(httpStatus)")
        }
        if let apiCode {
            fields.append("api_code=\(apiCode)")
        }
        if let reusedIntent {
            fields.append("reused_intent=\(reusedIntent)")
        }
        if let authenticatedAAD {
            fields.append("authenticated_aad=\(authenticatedAAD)")
        }

        if let error {
            let nsError = error as NSError
            fields.append("error_type=\(safeToken(String(reflecting: type(of: error))))")
            fields.append("error_domain=\(safeToken(nsError.domain))")
            fields.append("error_code=\(nsError.code)")
            if let apiError = error as? ErmisApiError {
                fields.append("http_status=\(apiError.httpStatusCode)")
                fields.append("api_code=\(apiError.code)")
            }
        }

        fields.append("elapsed_ms=\(elapsedMilliseconds(since: context.startedAtNanoseconds))")
        return fields.joined(separator: " ")
    }

    private static func safeToken(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:/"))
        return String(value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" })
    }
}
