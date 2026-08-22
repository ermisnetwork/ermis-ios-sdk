//
// Copyright 2025 Ermis Inc.
//

import Foundation
import ErmisShared

private struct ElementWrapper<T: Decodable>: Decodable {
    let value: T?
    var error: Error?
    init(from decoder: Decoder) throws {
        do {
            value = try T(from: decoder)
        } catch {
            value = nil
            self.error = error
        }
    }
}

// MARK: - Helpers to decode arrays and not discard the full array when there are parsing issues.

extension KeyedDecodingContainer {
    func decodeArrayIgnoringFailures<T: Decodable>(_ type: [T].Type, forKey key: KeyedDecodingContainer<K>.Key) throws -> [T] {
        let wrappers = try decode([ElementWrapper<T>].self, forKey: key)
        for wrapper in wrappers where wrapper.error != nil {
            logError(forWrapper: wrapper)
        }
        return wrappers.compactMap(\.value)
    }

    func decodeArrayIfPresentIgnoringFailures<T: Decodable>(_ type: [T].Type, forKey key: KeyedDecodingContainer<K>.Key) throws -> [T]? {
        guard let wrappers = try decodeIfPresent([ElementWrapper<T>].self, forKey: key) else {
            return nil
        }
        for wrapper in wrappers where wrapper.error != nil {
            logError(forWrapper: wrapper)
        }
        return wrappers.compactMap(\.value)
    }

    private func logError<T: Decodable>(forWrapper wrapper: ElementWrapper<T>) {
        guard let error = wrapper.error else { return }
        log.error(
            "[DECODING] state=array_element_failed model=\(T.self) "
                + PrivacySafeLogMetadata.errorFields(error)
        )
    }
}

private extension DecodingError {
    var prettyPrintedDescription: String {
        var errorDescription = String(describing: self)
        switch self {
        case let .typeMismatch(any, context):
            errorDescription = "typeMismatch for value \(any), path: \(context.prettyPrintedCodingPath), debugDescription: \(context.debugDescription)"
            if let underlyingError = context.underlyingError {
                errorDescription.append(", underlyingError: \(underlyingError)")
            }
        case let .valueNotFound(any, context):
            errorDescription = "valueNotFound for value \(any), path: \(context.prettyPrintedCodingPath), debugDescription: \(context.debugDescription)"
            if let underlyingError = context.underlyingError {
                errorDescription.append(", underlyingError: \(underlyingError)")
            }
        case let .keyNotFound(codingKey, context):
            errorDescription = "valueNotFound for key \(codingKey), path: \(context.prettyPrintedCodingPath), debugDescription: \(context.debugDescription)"
            if let underlyingError = context.underlyingError {
                errorDescription.append(", underlyingError: \(underlyingError)")
            }
        case let .dataCorrupted(context):
            errorDescription = "dataCorrupted, path: \(context.prettyPrintedCodingPath), debugDescription: \(context.debugDescription)"
            if let underlyingError = context.underlyingError {
                errorDescription.append(", underlyingError: \(underlyingError)")
            }
        @unknown default:
            break
        }
        return errorDescription
    }
}

private extension DecodingError.Context {
    var prettyPrintedCodingPath: String {
        var lastCodingKey: CodingKey?
        var description = "<"
        for key in codingPath {
            if let intValue = key.intValue, lastCodingKey?.intValue == nil {
                description.append("[\(intValue)]")
            } else {
                if lastCodingKey != nil {
                    description.append(".")
                }
                description.append("\(key.stringValue)")
            }
            lastCodingKey = key
        }
        description.append(">")
        return description
    }
}
