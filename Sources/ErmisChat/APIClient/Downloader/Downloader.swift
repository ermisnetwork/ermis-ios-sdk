//
// Copyright 2025 Ermis Inc.
//

import Foundation
/// The protocol responsible to download files.
public protocol Downloader {
    func downloadMessageAttachment(_ attachment: AnyMessageAttachment,
                                         progress: ((Double) -> Void)?,
                                         completion: @escaping (Result<DownloadedAttachment, Error>) -> Void)
    
    func downloadChannelAttachment(_ channelAttachment: ChannelAttachmentPayload,
                            progress: ((Double) -> Void)?,
                            completion: @escaping (Result<DownloadedAttachment, Error>) -> Void)
}

public class ErmisDownloader: Downloader {
    let client: DownloadClient

    init(client: DownloadClient) {
        self.client = client
    }

    public func downloadMessageAttachment(_ attachment: AnyMessageAttachment,
                                          progress: ((Double) -> Void)?,
                                          completion: @escaping (Result<DownloadedAttachment, Error>) -> Void) {
        client.downloadMessageAttachment(.messageAttachment(attachment),
                                         progress: progress,
                                         completion: completion)
    }

    public func downloadChannelAttachment(_ channelAttachment: ChannelAttachmentPayload,
                                          progress: ((Double) -> Void)?,
                                          completion: @escaping (Result<DownloadedAttachment, Error>) -> Void) {
        client.downloadMessageAttachment(.channelAttachment(channelAttachment),
                                         progress: progress,
                                         completion: completion)
    }
}

