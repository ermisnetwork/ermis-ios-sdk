//
// Copyright 2025 Ermis Inc.
//

import Foundation
/// The download client is responsible to download files.
public protocol DownloadClient {
    func downloadMessageAttachment(_ attachment: DownloadAttachmentPayload,
                                   progress: ((Double) -> Void)?,
                                   completion: @escaping (Result<DownloadedAttachment, Error>) -> Void)
}
/// Default implementation of `DownloadClient`.
public class ErmisDownloadClient: DownloadClient {
    private let session: URLSession
    /// Keeps track of downloading tasks progress
    @Atomic private var taskProgressObservers: [Int: NSKeyValueObservation] = [:]

    init(sessionConfiguration: URLSessionConfiguration) {
        self.session = URLSession(configuration: sessionConfiguration)
    }

    public func downloadMessageAttachment(_ attachment: DownloadAttachmentPayload,
                                          progress: ((Double) -> Void)?,
                                          completion: @escaping (Result<DownloadedAttachment, Error>) -> Void) {
        downloadFile(attachment.url, progress: progress) { result in
            switch result {
            case .success(let data):
                let downloadedAttachment = DownloadedAttachment(attachment: attachment,
                                                                data: data)
                completion(.success(downloadedAttachment))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func downloadFile(_ url: URL?,
                      progress: ((Double) -> Void)?,
                      completion: @escaping (Result<Data, Error>) -> Void) {
        guard let url else {
            completion(.failure(ClientError.InvalidURL()))
            return
        }
        let urlRequest = URLRequest(url: url)
        let task = session.dataTask(with: urlRequest) { (data, response, error) in
            if let error = error {
                completion(.failure(error))
            } else if let data = data {
                completion(.success(data))
            } else {
                completion(.failure(ClientError.ResponseBodyEmpty("No data from url: \(url)")))
            }
        }

        if let progressListener = progress {
            let taskID = task.taskIdentifier
            self._taskProgressObservers.mutate { observers in
                observers[taskID] = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                    progressListener(progress.fractionCompleted)
                    if progress.isFinished || progress.isCancelled {
                        self?._taskProgressObservers.mutate { observers in
                            observers[taskID]?.invalidate()
                            observers[taskID] = nil
                        }
                    }
                }
            }
        }

        task.resume()
    }
}
