//
// Copyright 2026 Ermis Inc.
//

import Foundation

/// Process-wide rollback switch for E2EE video range playback.
///
/// Range playback is enabled when the environment override is absent. Existing development and
/// deployment configurations that explicitly set `ERMIS_E2EE_RANGE_STREAMING_ENABLED=1` remain
/// enabled, while any other explicit value disables the lane. Hosts can also disable range
/// playback per client through `ErmisClientConfig.isE2eeRangeStreamingEnabled`.
enum E2eeRangeStreamingFeatureFlag {
    static let environmentKey = "ERMIS_E2EE_RANGE_STREAMING_ENABLED"

    static var isEnabled: Bool {
        isEnabled(environment: ProcessInfo.processInfo.environment)
    }

    static func isEnabled(environment: [String: String]) -> Bool {
        guard let override = environment[environmentKey] else { return true }
        return override == "1"
    }
}

/// Central playback selector. File size and duration are intentionally absent: every opaque E2EE
/// video follows the same range policy, while non-video download/export paths stay unchanged.
enum E2eeVideoPlaybackPolicy {
    static func usesRangeStreaming(
        isOpaqueE2eeVideo: Bool,
        clientEnabled: Bool,
        processEnabled: Bool
    ) -> Bool {
        isOpaqueE2eeVideo && clientEnabled && processEnabled
    }
}

/// A Bellboy-issued, asset-scoped credential for ciphertext byte-range requests.
struct E2eeRangeStreamingGrant: Equatable, Sendable {
    let assetId: String
    let grantURL: URL
    /// Absolute expiry returned by Bellboy. The client never invents a TTL.
    let expiresAt: Date
    let issuedAt: Date

    init(assetId: String, grantURL: URL, expiresAt: Date, issuedAt: Date = Date()) {
        self.assetId = assetId
        self.grantURL = grantURL
        self.expiresAt = expiresAt
        self.issuedAt = issuedAt
    }

    func ttl(now: Date = Date()) -> TimeInterval {
        expiresAt.timeIntervalSince(now)
    }

    /// Renews early enough to avoid a seek landing on an expiring URL, while never consuming more
    /// than half of a short-lived grant's lifetime.
    static func renewalLead(for ttl: TimeInterval) -> TimeInterval {
        guard ttl > 0 else { return 0 }
        return min(ttl / 2, max(30, min(60, ttl * 0.20)))
    }

    func renewalDeadline() -> Date {
        let originalTTL = max(0, expiresAt.timeIntervalSince(issuedAt))
        return expiresAt.addingTimeInterval(-Self.renewalLead(for: originalTTL))
    }

    func isExpired(now: Date = Date(), slack: TimeInterval = 5) -> Bool {
        ttl(now: now) <= slack
    }
}
