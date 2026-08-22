//
// Copyright 2026 Ermis Inc.
//

#if DEBUG
import Foundation

enum E2eeR2RangeProofError: Error, Equatable {
    case invalidCiphertextSize
    case invalidResponse
    case invalidStatus
    case invalidContentLength
    case invalidContentRange
    case localReadFailed
    case bodyMismatch

    var category: String {
        switch self {
        case .invalidCiphertextSize: return "invalid_ciphertext_size"
        case .invalidResponse: return "invalid_response"
        case .invalidStatus: return "invalid_status"
        case .invalidContentLength: return "invalid_content_length"
        case .invalidContentRange: return "invalid_content_range"
        case .localReadFailed: return "local_read_failed"
        case .bodyMismatch: return "body_mismatch"
        }
    }
}

/// Process-scoped opt-in for collecting one real Bellboy/R2 byte-equivalence proof. The probe is
/// deliberately absent from Release and never records the grant URL, asset identity, byte offset,
/// filename, or local path.
final class E2eeR2RangeProofGate: @unchecked Sendable {
    static let environmentKey = "ERMIS_E2EE_RANGE_DEBUG_VERIFY_R2_RANGE_ONCE"
    static let shared = E2eeR2RangeProofGate()

    private let lock = NSLock()
    private let isEnabled: Bool
    private var hasClaimed = false

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        isEnabled = environment[Self.environmentKey] == "1"
    }

    func claim() -> Bool {
        guard isEnabled else { return false }
        return lock.withLock {
            guard !hasClaimed else { return false }
            hasClaimed = true
            return true
        }
    }
}

enum E2eeR2RangeProofVerifier {
    struct Result: Equatable, Sendable {
        let byteCount: Int
    }

    static let maximumProofBytes: UInt64 = 64 * 1024

    static func proofRange(totalCiphertextSize: UInt64) throws -> Range<UInt64> {
        guard totalCiphertextSize > 0 else {
            throw E2eeR2RangeProofError.invalidCiphertextSize
        }
        let byteCount = min(maximumProofBytes, totalCiphertextSize)
        let lowerBound = (totalCiphertextSize - byteCount) / 2
        return lowerBound..<(lowerBound + byteCount)
    }

    static func verify(
        grantURL: URL,
        verifiedCiphertextURL: URL,
        totalCiphertextSize: UInt64,
        sessionConfiguration: URLSessionConfiguration = .ephemeral
    ) async throws -> Result {
        let range = try proofRange(totalCiphertextSize: totalCiphertextSize)
        let expectedByteCount = range.upperBound - range.lowerBound
        guard expectedByteCount <= UInt64(Int.max) else {
            throw E2eeR2RangeProofError.invalidCiphertextSize
        }

        let configuration = (sessionConfiguration.copy() as? URLSessionConfiguration)
            ?? sessionConfiguration
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = true
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: grantURL)
        request.httpMethod = "GET"
        request.setValue(
            "bytes=\(range.lowerBound)-\(range.upperBound - 1)",
            forHTTPHeaderField: "Range"
        )
        let (remoteBytes, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw E2eeR2RangeProofError.invalidResponse
        }
        guard http.statusCode == 206 else {
            throw E2eeR2RangeProofError.invalidStatus
        }
        guard hasExactContentLength(http, expected: expectedByteCount) else {
            throw E2eeR2RangeProofError.invalidContentLength
        }
        guard hasExactContentRange(
            http,
            expected: range,
            totalCiphertextSize: totalCiphertextSize
        ) else {
            throw E2eeR2RangeProofError.invalidContentRange
        }
        guard remoteBytes.count == Int(expectedByteCount) else {
            throw E2eeR2RangeProofError.invalidContentLength
        }

        let localBytes: Data
        do {
            let handle = try FileHandle(forReadingFrom: verifiedCiphertextURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: range.lowerBound)
            localBytes = try handle.read(upToCount: Int(expectedByteCount)) ?? Data()
        } catch {
            throw E2eeR2RangeProofError.localReadFailed
        }
        guard localBytes.count == Int(expectedByteCount) else {
            throw E2eeR2RangeProofError.localReadFailed
        }
        guard remoteBytes == localBytes else {
            throw E2eeR2RangeProofError.bodyMismatch
        }
        return Result(byteCount: remoteBytes.count)
    }

    private static func hasExactContentLength(
        _ response: HTTPURLResponse,
        expected: UInt64
    ) -> Bool {
        guard let raw = response.value(forHTTPHeaderField: "Content-Length"),
              let value = UInt64(raw.trimmingCharacters(in: .whitespaces)) else {
            return false
        }
        return value == expected
    }

    private static func hasExactContentRange(
        _ response: HTTPURLResponse,
        expected: Range<UInt64>,
        totalCiphertextSize: UInt64
    ) -> Bool {
        guard let raw = response.value(forHTTPHeaderField: "Content-Range") else {
            return false
        }
        let components = raw.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard components.count == 2, components[0].lowercased() == "bytes" else {
            return false
        }
        let rangeAndTotal = components[1].split(
            separator: "/",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard rangeAndTotal.count == 2,
              UInt64(rangeAndTotal[1]) == totalCiphertextSize else {
            return false
        }
        let bounds = rangeAndTotal[0].split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard bounds.count == 2,
              UInt64(bounds[0]) == expected.lowerBound,
              UInt64(bounds[1]) == expected.upperBound - 1 else {
            return false
        }
        return true
    }
}
#endif
