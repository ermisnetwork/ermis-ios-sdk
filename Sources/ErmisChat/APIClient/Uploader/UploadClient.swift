//
// Copyright 2025 Ermis Inc.
//

import Foundation
import ErmisShared

/// An uploaded file model.
public struct UploadedFile: Decodable {
    public let fileURL: URL
    public let thumbnailURL: URL?

    public init(fileURL: URL, thumbnailURL: URL? = nil) {
        self.fileURL = fileURL
        self.thumbnailURL = thumbnailURL
    }
}

/// The upload client is responsible to upload files.
public protocol UploadClient {

    /// Uploads an attachment and returns only the uploaded remote file.
    /// - Parameters:
    ///   - attachment: An attachment to upload.
    ///   - progress: A closure that broadcasts upload progress.
    ///   - completion: Returns the uploaded file's information.
    func uploadAttachment(
        _ attachment: AnyMessageAttachment,
        progress: ((Double) -> Void)?,
        completion: @escaping (Result<URL, Error>) -> Void
    )

    /// Uploads an attachment and returns the uploaded remote file and its thumbnail.
    /// - Parameters:
    ///   - attachment: An attachment to upload.
    ///   - progress: A closure that broadcasts upload progress.
    ///   - completion: Returns the uploaded file's information.
    func uploadAttachment(
        _ attachment: AnyMessageAttachment,
        progress: ((Double) -> Void)?,
        completion: @escaping (Result<UploadedFile, Error>) -> Void
    )

    /// Uploads user avatar as a multipart/form-data and returns the avatar remote url.
    /// - Parameters:
    ///   - data: Data of avatar image to upload.
    ///   - progress: A closure that broadcasts upload progress.
    ///   - completion: Returns the remote url.
    func uploadUserAvatar(
        _ data: Data,
        progress: ((Double) -> Void)?,
        completion: @escaping (Result<AvatarUploadPayload, Error>) -> Void
    )
}

public extension UploadClient {
    func uploadAttachment(
        _ attachment: AnyMessageAttachment,
        progress: ((Double) -> Void)?,
        completion: @escaping (Result<UploadedFile, Error>) -> Void
    ) {
        uploadAttachment(attachment, progress: progress, completion: { (result: Result<URL, Error>) in
            switch result {
            case let .success(url):
                completion(.success(UploadedFile(fileURL: url, thumbnailURL: nil)))
            case let .failure(error):
                completion(.failure(error))
            }
        })
    }
}

/// Default implementation of UploadClient.
class ErmisUploadClient: NSObject, UploadClient, URLSessionDataDelegate {
    typealias UploadedFileCompletionHandler = (Result<UploadedFile, Error>) -> Void
    private let decoder: RequestDecoder
    private let encoder: RequestEncoder
    private let sessionConfiguration: URLSessionConfiguration
    private let allowsLegacyStandardUploadFallback: Bool
    private var presignedUploadClient: StandardPresignedAttachmentUploadClient?

    private lazy var session: URLSession = URLSession(configuration: sessionConfiguration,
                                                      delegate: self,
                                                      delegateQueue: nil)
    // A dictionary that stores the inputstream for each task, keyed by taskIdentifier
    @Atomic private var streams: [Int: MultipartInputStream] = [:]
    // A dictionary that stores the uploading completion handler for each task, keyed by taskIdentifier
    @Atomic private var uploadCompletionHandlers: [Int: UploadedFileCompletionHandler] = [:]
    // A dictionary that stores the uploading data for each task, keyed by taskIdentifier
    @Atomic private var uploadingBufferDatas: [Int: Data] = [:]

    /// Keeps track of uploading tasks progress
    @Atomic private var taskProgressObservers: [Int: NSKeyValueObservation] = [:]

    init(
        encoder: RequestEncoder,
        decoder: RequestDecoder,
        sessionConfiguration: URLSessionConfiguration,
        isStandardPresignedUploadEnabled: Bool = false,
        allowsLegacyStandardUploadFallback: Bool = true
    ) {
        self.encoder = encoder
        self.decoder = decoder
        self.sessionConfiguration = sessionConfiguration
        self.allowsLegacyStandardUploadFallback = allowsLegacyStandardUploadFallback
        if isStandardPresignedUploadEnabled {
            presignedUploadClient = StandardPresignedAttachmentUploadClient(
                encoder: encoder,
                decoder: decoder,
                sessionConfiguration: sessionConfiguration
            )
        }
    }

    func uploadAttachment(
        _ attachment: AnyMessageAttachment,
        progress: ((Double) -> Void)? = nil,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        uploadAttachment(attachment, progress: progress, completion: { (result: Result<UploadedFile, Error>) in
            switch result {
            case let .success(file):
                completion(.success(file.fileURL))
            case let .failure(error):
                completion(.failure(error))
            }
        })
    }

    func uploadAttachment(
        _ attachment: AnyMessageAttachment,
        progress: ((Double) -> Void)? = nil,
        completion: @escaping (Result<UploadedFile, Error>) -> Void
    ) {
        guard let presignedUploadClient else {
            uploadAttachmentThroughLegacyProxy(
                attachment,
                progress: progress,
                completion: completion
            )
            return
        }
        presignedUploadClient.upload(
            attachment,
            progress: progress
        ) { [weak self] result in
            guard case let .failure(error) = result,
                  error.permitsLegacyFallback,
                  self?.allowsLegacyStandardUploadFallback == true else {
                completion(result.mapError { $0 as Error })
                return
            }
            self?.uploadAttachmentThroughLegacyProxy(
                attachment,
                progress: progress,
                completion: completion
            )
        }
    }

    private func uploadAttachmentThroughLegacyProxy(
        _ attachment: AnyMessageAttachment,
        progress: ((Double) -> Void)?,
        completion: @escaping (Result<UploadedFile, Error>) -> Void
    ) {
        guard
            let uploadingState = attachment.uploadingState else {
            return completion(.failure(ClientError.AttachmentUploading(id: attachment.id)))
        }

        let stream = MultipartInputStream(fileURL: uploadingState.localFileURL,
                                          fieldName: "file",
                                          fileName: uploadingState.localFileURL.lastPathComponent,
                                          mimeType: uploadingState.file.type.mimeType)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: uploadingState.localFileURL.path)[.size] as! Int) ?? 0
        let headerSize = stream.headerData.count
        let footerSize = stream.footerData.count
        let totalSize = headerSize + fileSize + footerSize

        let endpoint = Endpoint<FileUploadPayload>.uploadAttachment(with: attachment.id.cid, type: attachment.type)

        encoder.encodeRequest(for: endpoint) { [weak self] (requestResult) in
            var urlRequest: URLRequest
            do {
                urlRequest = try requestResult.get()
            } catch {
                log.error(error, subsystems: .httpRequests)
                completion(.failure(error))
                return
            }
            urlRequest.setHTTPHeaders(HTTPHeader(key: .contentType, value: "multipart/form-data; boundary=\(MultipartInputStream.boundary)"))
            urlRequest.httpBody = nil
            urlRequest.setHTTPHeaders(HTTPHeader(key: .contentLength, value: String(totalSize)))

            guard let self = self else {
                log.warning("Callback called while self is nil", subsystems: .httpRequests)
                return
            }
            let task = self.session.uploadTask(withStreamedRequest: urlRequest)
            self._streams.mutate({ value in
                value[task.taskIdentifier] = stream
            })
            self._uploadCompletionHandlers.mutate({ value in
                value[task.taskIdentifier] = completion
            })
            self._uploadingBufferDatas.mutate({ value in
                value[task.taskIdentifier] = Data()
            })

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

    func uploadUserAvatar(
        _ data: Data,
        progress: ((Double) -> Void)? = nil,
        completion: @escaping (Result<AvatarUploadPayload, Error>) -> Void
    ) {
        let avatarMultipartFormData = AvatarMultipartFormData(data, fileName: "avatar.jpeg", mimeType: "image/jpeg")
        let endpoint = Endpoint<AvatarUploadPayload>.uploadUserAvatar()

        encoder.encodeRequest(for: endpoint) { [weak self] (requestResult) in
            var urlRequest: URLRequest
            do {
                urlRequest = try requestResult.get()
            } catch {
                log.error(error, subsystems: .httpRequests)
                completion(.failure(error))
                return
            }

            let multilpartFormData = avatarMultipartFormData.getMultipartFormData()
            urlRequest.setHTTPHeaders(HTTPHeader(key: .contentType, value: "multipart/form-data; boundary=\(AvatarMultipartFormData.boundary)"))
            urlRequest.httpBody = multilpartFormData
            urlRequest.setHTTPHeaders(HTTPHeader(key: .contentLength, value: String(data.count)))
            guard let self = self else {
                log.warning("Callback called while self is nil", subsystems: .httpRequests)
                return
            }

            let task = self.session.dataTask(with: urlRequest) { [decoder = self.decoder] (data, response, error) in
                do {
                    let response: AvatarUploadPayload = try decoder.decodeRequestResponse(
                        data: data,
                        response: response,
                        error: error
                    )
                    completion(.success(response))
                } catch {
                    completion(.failure(error))
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
    // MARK: - URLSessionDelegate
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    needNewBodyStreamFrom offset: Int64,
                    completionHandler: @escaping (InputStream?) -> Void) {
        completionHandler(streams[task.taskIdentifier])
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        uploadingBufferDatas[dataTask.taskIdentifier, default: Data()].append(data)
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        let taskId = task.taskIdentifier
        let response = task.response as? HTTPURLResponse
        let data = uploadingBufferDatas[taskId]
        do {
            let response: FileUploadPayload = try decoder.decodeRequestResponse(
                data: data,
                response: response,
                error: error
            )
            let file = UploadedFile(fileURL: response.fileURL, thumbnailURL: response.thumbURL)

            uploadCompletionHandlers[taskId]?(.success(file))
        } catch {
            uploadCompletionHandlers[taskId]?(.failure(error))
        }

        // cleanup
        _streams.mutate({ value in
            value[taskId] = nil
        })

        _uploadCompletionHandlers.mutate({ value in
            value[taskId] = nil
        })

        _uploadingBufferDatas.mutate({ value in
            value[taskId] = nil
        })
    }
}
