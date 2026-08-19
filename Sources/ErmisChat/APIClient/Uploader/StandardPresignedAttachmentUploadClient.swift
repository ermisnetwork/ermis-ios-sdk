//
// Copyright 2026 Ermis Inc.
//

import Foundation
import ErmisShared

struct StandardPresignedUploadFailure: Error {
    enum Stage {
        case presign
        case storage
        case confirmation
        case ambiguousStorageResult
    }

    let stage: Stage
    let underlyingError: Error

    var permitsLegacyFallback: Bool { stage == .presign }
}

enum StandardPresignedUploadContractError: Error, Equatable {
    case missingSourceFile
    case invalidAttachmentId
    case invalidUploadURL
    case invalidExpiry
    case storageRejected(Int)
    case ambiguousStorageResult
}

final class StandardPresignedAttachmentUploadClient {
    private enum StorageResult {
        case success
        case authorizationFailure
        case definitiveFailure(Error)
        case ambiguousFailure(Error)
    }

    private let encoder: RequestEncoder
    private let decoder: RequestDecoder
    private let controlSession: URLSession
    private let storageSession: URLSession
    @Atomic private var progressObservers: [UUID: NSKeyValueObservation] = [:]

    init(
        encoder: RequestEncoder,
        decoder: RequestDecoder,
        sessionConfiguration: URLSessionConfiguration
    ) {
        self.encoder = encoder
        self.decoder = decoder
        controlSession = URLSession(configuration: sessionConfiguration)
        storageSession = URLSession(
            configuration: Self.storageConfiguration(from: sessionConfiguration)
        )
    }

    deinit {
        controlSession.invalidateAndCancel()
        storageSession.invalidateAndCancel()
    }

    func upload(
        _ attachment: AnyMessageAttachment,
        progress: ((Double) -> Void)?,
        completion: @escaping (Result<UploadedFile, StandardPresignedUploadFailure>) -> Void
    ) {
        guard let uploading = attachment.uploadingState,
              uploading.localFileURL.isFileURL,
              FileManager.default.fileExists(atPath: uploading.localFileURL.path) else {
            completion(.failure(.init(
                stage: .presign,
                underlyingError: StandardPresignedUploadContractError.missingSourceFile
            )))
            return
        }
        let fileName = uploading.localFileURL.lastPathComponent
        let contentType = attachment.mimetype ?? uploading.file.type.mimeType
        beginAttempt(
            cid: attachment.id.cid,
            sourceURL: uploading.localFileURL,
            fileName: fileName,
            contentType: contentType,
            renewalCount: 0,
            progress: progress,
            completion: completion
        )
    }

    private func beginAttempt(
        cid: ChannelId,
        sourceURL: URL,
        fileName: String,
        contentType: String,
        renewalCount: Int,
        progress: ((Double) -> Void)?,
        completion: @escaping (Result<UploadedFile, StandardPresignedUploadFailure>) -> Void
    ) {
        let request = StandardAttachmentPresignRequest(
            fileName: fileName,
            contentType: contentType
        )
        perform(
            Endpoint<StandardAttachmentPresignPayload>.presignStandardAttachment(
                with: cid,
                body: request
            )
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(.init(stage: .presign, underlyingError: error)))
            case .success(let payload):
                do {
                    try self.validate(payload)
                } catch {
                    completion(.failure(.init(stage: .presign, underlyingError: error)))
                    return
                }
                self.put(
                    sourceURL: sourceURL,
                    uploadURL: payload.uploadURL,
                    contentType: contentType,
                    progress: progress
                ) { result in
                    self.handleStorageResult(
                        result,
                        payload: payload,
                        cid: cid,
                        sourceURL: sourceURL,
                        fileName: fileName,
                        contentType: contentType,
                        renewalCount: renewalCount,
                        progress: progress,
                        completion: completion
                    )
                }
            }
        }
    }

    private func handleStorageResult(
        _ result: StorageResult,
        payload: StandardAttachmentPresignPayload,
        cid: ChannelId,
        sourceURL: URL,
        fileName: String,
        contentType: String,
        renewalCount: Int,
        progress: ((Double) -> Void)?,
        completion: @escaping (Result<UploadedFile, StandardPresignedUploadFailure>) -> Void
    ) {
        switch result {
        case .success:
            confirm(
                cid: cid,
                payload: payload,
                fileName: fileName,
                contentType: contentType,
                retriesRemaining: 1,
                progress: progress,
                completion: completion
            )
        case .authorizationFailure where renewalCount == 0:
            beginAttempt(
                cid: cid,
                sourceURL: sourceURL,
                fileName: fileName,
                contentType: contentType,
                renewalCount: 1,
                progress: progress,
                completion: completion
            )
        case .authorizationFailure:
            completion(.failure(.init(
                stage: .storage,
                underlyingError: StandardPresignedUploadContractError.storageRejected(403)
            )))
        case .definitiveFailure(let error):
            completion(.failure(.init(stage: .storage, underlyingError: error)))
        case .ambiguousFailure:
            confirmAfterAmbiguousStorageResult(
                cid: cid,
                payload: payload,
                fileName: fileName,
                contentType: contentType,
                progress: progress,
                completion: completion
            )
        }
    }

    private func confirmAfterAmbiguousStorageResult(
        cid: ChannelId,
        payload: StandardAttachmentPresignPayload,
        fileName: String,
        contentType: String,
        progress: ((Double) -> Void)?,
        completion: @escaping (Result<UploadedFile, StandardPresignedUploadFailure>) -> Void
    ) {
        confirm(
            cid: cid,
            payload: payload,
            fileName: fileName,
            contentType: contentType,
            retriesRemaining: 1,
            progress: progress
        ) { result in
            switch result {
            case .success:
                completion(result)
            case .failure:
                completion(.failure(.init(
                    stage: .ambiguousStorageResult,
                    underlyingError: StandardPresignedUploadContractError.ambiguousStorageResult
                )))
            }
        }
    }

    private func confirm(
        cid: ChannelId,
        payload: StandardAttachmentPresignPayload,
        fileName: String,
        contentType: String,
        retriesRemaining: Int,
        progress: ((Double) -> Void)?,
        completion: @escaping (Result<UploadedFile, StandardPresignedUploadFailure>) -> Void
    ) {
        let body = StandardAttachmentConfirmRequest(
            attachmentId: payload.attachmentId,
            fileName: fileName,
            contentType: contentType
        )
        perform(
            Endpoint<StandardAttachmentConfirmPayload>.confirmStandardAttachment(
                with: cid,
                body: body
            )
        ) { [weak self] result in
            switch result {
            case .success(let response):
                progress?(1)
                completion(.success(UploadedFile(fileURL: response.fileURL)))
            case .failure(let error) where retriesRemaining > 0
                && ClientError.isEphemeral(error: error):
                self?.confirm(
                    cid: cid,
                    payload: payload,
                    fileName: fileName,
                    contentType: contentType,
                    retriesRemaining: retriesRemaining - 1,
                    progress: progress,
                    completion: completion
                )
            case .failure(let error):
                completion(.failure(.init(stage: .confirmation, underlyingError: error)))
            }
        }
    }

    private func put(
        sourceURL: URL,
        uploadURL: URL,
        contentType: String,
        progress: ((Double) -> Void)?,
        completion: @escaping (StorageResult) -> Void
    ) {
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.httpShouldHandleCookies = false
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        if let size = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)[.size]
            as? NSNumber {
            request.setValue(size.stringValue, forHTTPHeaderField: "Content-Length")
        }
        let progressObserverId = UUID()
        let task = storageSession.uploadTask(with: request, fromFile: sourceURL) {
            [weak self] _, response, error in
            guard let self else { return }
            self.removeProgressObserver(id: progressObserverId)
            if let error {
                completion(.ambiguousFailure(error))
                return
            }
            guard let response = response as? HTTPURLResponse else {
                completion(.ambiguousFailure(StandardPresignedUploadContractError.ambiguousStorageResult))
                return
            }
            switch response.statusCode {
            case 200..<300:
                completion(.success)
            case 403:
                completion(.authorizationFailure)
            case 400..<500:
                completion(.definitiveFailure(
                    StandardPresignedUploadContractError.storageRejected(response.statusCode)
                ))
            default:
                completion(.ambiguousFailure(
                    StandardPresignedUploadContractError.storageRejected(response.statusCode)
                ))
            }
        }
        if let progress {
            _progressObservers.mutate { observers in
                observers[progressObserverId] = task.progress.observe(\.fractionCompleted) {
                    observed, _ in
                    progress(min(0.95, max(0, observed.fractionCompleted * 0.95)))
                }
            }
        }
        task.resume()
    }

    private func removeProgressObserver(id: UUID) {
        _progressObservers.mutate { observers in
            observers[id]?.invalidate()
            observers[id] = nil
        }
    }

    private func perform<Response: Decodable>(
        _ endpoint: Endpoint<Response>,
        completion: @escaping (Result<Response, Error>) -> Void
    ) {
        encoder.encodeRequest(for: endpoint) { [weak self] requestResult in
            guard let self else { return }
            switch requestResult {
            case .failure(let error):
                completion(.failure(error))
            case .success(let request):
                self.controlSession.dataTask(with: request) { data, response, error in
                    do {
                        let payload: Response = try self.decoder.decodeRequestResponse(
                            data: data,
                            response: response,
                            error: error
                        )
                        completion(.success(payload))
                    } catch {
                        completion(.failure(error))
                    }
                }.resume()
            }
        }
    }

    private func validate(_ payload: StandardAttachmentPresignPayload) throws {
        guard UUID(uuidString: payload.attachmentId) != nil else {
            throw StandardPresignedUploadContractError.invalidAttachmentId
        }
        guard payload.uploadURL.scheme?.lowercased() == "https",
              payload.uploadURL.host?.isEmpty == false else {
            throw StandardPresignedUploadContractError.invalidUploadURL
        }
        guard payload.expiresInSeconds > 0 else {
            throw StandardPresignedUploadContractError.invalidExpiry
        }
    }

    private static func storageConfiguration(
        from source: URLSessionConfiguration
    ) -> URLSessionConfiguration {
        let configuration = (source.copy() as? URLSessionConfiguration) ?? .ephemeral
        configuration.httpAdditionalHeaders = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }
}
