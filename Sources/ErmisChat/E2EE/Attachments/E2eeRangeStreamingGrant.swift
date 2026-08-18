//
// Copyright 2026 Ermis Inc.
//

import Foundation

/// Range playback is an independent rollback lane. It remains off unless a host process opts in
/// explicitly; ordinary SDK and production builds therefore keep using verified full downloads.
enum E2eeRangeStreamingFeatureFlag {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["ERMIS_E2EE_RANGE_STREAMING_ENABLED"] == "1"
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
