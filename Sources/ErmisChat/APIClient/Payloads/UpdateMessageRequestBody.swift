//
// Copyright 2025 Ermis Inc.
//

import Foundation

public
struct UpdateMessageRequestBody: Encodable {
    let oldMessage: MessageRequestBody

    init(oldMessage: MessageRequestBody) {
        self.oldMessage = oldMessage
    }

    init(chatMessage: ChatMessage) {
        self.oldMessage = .init(with: chatMessage)
    }

    enum CodingKeys: String, CodingKey {
        case oldMessage = "old_message"
    }

    public
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(oldMessage, forKey: .oldMessage)
    }
}

