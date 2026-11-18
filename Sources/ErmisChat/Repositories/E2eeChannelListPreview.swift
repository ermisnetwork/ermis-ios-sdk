import Foundation

/// One authoritative head per route; preview demand never expands to full history.
enum E2eeChannelListPreview {
    typealias Preview = (cid: ChannelId, message: MessagePayload)

    static func select(_ channels: [ChannelPayload], retaining previous: [Preview] = []) -> [Preview] {
        var heads = Dictionary(uniqueKeysWithValues: previous.map { ($0.cid, $0.message) })
        for payload in channels {
            let cid = payload.channel.cid
            guard payload.channel.mlsEnabled, payload.membership?.role?.isJoined == true,
                  payload.membership?.isBanned != true, payload.membership?.isBlocked != true else {
                heads.removeValue(forKey: cid); continue
            }
            // A metadata-only page must not erase a head waiting for admission.
            guard let message = payload.newestMessage else { continue }
            if let prior = heads[cid], prior.createdAt > message.createdAt { continue }
            guard message.encryptedData?.isEmpty == false,
                  message.hasAuthoritativeGroupGeneration, message.mlsEpoch != nil else {
                heads.removeValue(forKey: cid); continue
            }
            heads[cid] = message
        }
        return heads.map { (cid: $0.key, message: $0.value) }
            .sorted { $0.message.createdAt > $1.message.createdAt }.prefix(5).map { $0 }
    }
}
