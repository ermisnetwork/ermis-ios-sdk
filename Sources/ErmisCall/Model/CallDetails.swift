//
// Copyright 2025 Ermis Inc.
//

import Foundation
import ErmisChat

public struct CallDetails: Equatable, Sendable {
    public let uuid: UUID
    public var callId: String
    public let cid: ChannelId
    public let title: String
    public let imageURL: URL?
    public var isVideo: Bool
    public let isIncoming: Bool
    public let currentUser: ChannelMember?

    private var _state: CallState = .idle
    private let lock = NSLock()

    public var state: CallState {
        get {
            lock.withLock { _state }
        }

        set {
            lock.withLock { _state = newValue }
        }
    }

    public init(
        uuid: UUID,
        callId: String,
        cid: ChannelId,
        title: String,
        imageURL: URL?,
        isVideo: Bool,
        isIncoming: Bool,
        currentUser: ChannelMember?
    ) {
        self.uuid = uuid
        self.callId = callId
        self.cid = cid
        self.title = title
        self.imageURL = imageURL
        self.isVideo = isVideo
        self.isIncoming = isIncoming
        self.currentUser = currentUser
        if isIncoming {
            self.state = .ringing
        }
    }
}
