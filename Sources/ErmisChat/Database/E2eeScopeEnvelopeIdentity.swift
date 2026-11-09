import Foundation

/// One application can occur in both the message index and its wrapper-event index.
/// They retain different ordering clocks while identifying the exact same message payload.
enum E2eeScopeEnvelopeIdentity {
    static func matches(_ stored: Data, _ incoming: Data) -> Bool {
        if stored == incoming { return true }
        guard case .dictionary(var a) = try? JSONDecoder().decode(RawJSON.self, from: stored),
              case .dictionary(var b) = try? JSONDecoder().decode(RawJSON.self, from: incoming),
              a["type"] == .string("application"), b["type"] == a["type"],
              let eventId = a["event_id"]?.stringValue, UUID(uuidString: eventId) != nil,
              b["event_id"] == a["event_id"],
              case .dictionary(let payload) = a["data"],
              payload["id"] == a["event_id"],
              let messageTime = payload["created_at"]?.stringValue,
              let firstTime = a["created_at"]?.stringValue,
              let secondTime = b["created_at"]?.stringValue,
              firstTime == messageTime || secondTime == messageTime,
              let messageDate = timestamp(messageTime),
              let firstDate = timestamp(firstTime), let secondDate = timestamp(secondTime),
              firstDate >= messageDate, secondDate >= messageDate else { return false }
        // Preserve every payload/routing/identity field, including the message's own clock.
        // Never replace the stored envelope or use this equality as a cursor/protocol proof.
        a.removeValue(forKey: "created_at")
        b.removeValue(forKey: "created_at")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let left = try? encoder.encode(RawJSON.dictionary(a)),
              let right = try? encoder.encode(RawJSON.dictionary(b)) else { return false }
        return left == right
    }

    private static func timestamp(_ value: String) -> String? {
        guard value.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{1,9})?Z$", options: .regularExpression) != nil else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = value.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        guard parser.date(from: value) != nil else { return nil }
        // Date/ISO8601DateFormatter can round submillisecond values. Preserve the full
        // wire precision when rejecting an index clock that predates the message.
        let parts = value.dropLast().split(separator: ".", omittingEmptySubsequences: false)
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        return String(parts[0]) + fraction + String(repeating: "0", count: 9 - fraction.count)
    }
}
