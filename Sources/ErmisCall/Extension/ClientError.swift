//
// Copyright 2025 Ermis Inc.
//

import ErmisChat

extension ClientError {
    public final class SDPInvalid: ClientError {}
    public final class PeerConnectionCreatedFailed: ClientError {}
    public final class VideoCapturerInvalid: ClientError {}
    public final class DataChannelMessageBodyInvalid: ClientError {}
}

