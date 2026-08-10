//
// Copyright 2026 Ermis Inc.
//

import CryptoKit
import Foundation
import Security

enum E2eeAttachmentFrameCryptoError: Error, Equatable {
    case invalidFrameSize(Int)
    case invalidKeySize(Int)
    case invalidNoncePrefixSize(Int)
    case frameIndexOverflow
    case sizeOverflow
    case outputAlreadyExists
    case inputAndOutputMatch
    case invalidFrameHeader
    case invalidPlaintextLength(UInt32)
    case invalidCiphertextLength(UInt32)
    case shortFrameBeforeEnd
    case emptyCiphertext
    case randomGenerationFailed(OSStatus)
}

struct E2eeAttachmentFrameCryptoResult: Equatable {
    let plaintextSize: UInt64
    let plaintextSha256: String
    let ciphertextSize: UInt64
    let ciphertextSha256: String
    let frameCount: UInt32
    let frameSize: UInt32
}

/// Web-compatible V1 attachment framing.
///
/// Each frame is encoded as `u32 plaintextLength`, `u32 ciphertextLength`, followed by AES-GCM
/// ciphertext and its 16-byte tag. The 12-byte nonce is an 8-byte random prefix followed by the
/// big-endian u32 frame index. No per-frame additional authenticated data is supplied because the
/// deployed Web wire contract does not supply any.
enum E2eeAttachmentFrameCryptoV1 {
    static let defaultFrameSize = 256 * 1024
    static let keySize = 32
    static let noncePrefixSize = 8
    static let nonceSize = 12
    static let headerSize = 8
    static let tagSize = 16
    static let emptyCiphertextSize = headerSize + tagSize
    static let originalCiphertextLimit: UInt64 = 2 * 1024 * 1024 * 1024
    static let previewCiphertextLimit: UInt64 = 1024 * 1024

    static func estimatedCiphertextSize(
        plaintextSize: UInt64,
        frameSize: Int = defaultFrameSize
    ) throws -> UInt64 {
        guard frameSize > 0, frameSize <= Int(UInt32.max) else {
            throw E2eeAttachmentFrameCryptoError.invalidFrameSize(frameSize)
        }
        let frameSize = UInt64(frameSize)
        let frameCount: UInt64
        if plaintextSize == 0 {
            frameCount = 1
        } else {
            let adjusted = try addingWithoutOverflow(plaintextSize, frameSize - 1)
            frameCount = adjusted / frameSize
        }
        let overhead = try multiplyingWithoutOverflow(frameCount, UInt64(headerSize + tagSize))
        return try addingWithoutOverflow(plaintextSize, overhead)
    }

    static func maximumPlaintextSize(
        ciphertextLimit: UInt64 = originalCiphertextLimit,
        frameSize: Int = defaultFrameSize
    ) throws -> UInt64 {
        guard frameSize > 0, frameSize <= Int(UInt32.max) else {
            throw E2eeAttachmentFrameCryptoError.invalidFrameSize(frameSize)
        }
        var lower: UInt64 = 0
        var upper = ciphertextLimit
        while lower < upper {
            let midpoint = lower + (upper - lower + 1) / 2
            if try estimatedCiphertextSize(plaintextSize: midpoint, frameSize: frameSize) <= ciphertextLimit {
                lower = midpoint
            } else {
                upper = midpoint - 1
            }
        }
        return lower
    }

    static func makeKeyMaterial() throws -> (contentKey: Data, noncePrefix: Data) {
        let key = SymmetricKey(size: .bits256)
        let contentKey = key.withUnsafeBytes { Data($0) }
        var noncePrefix = Data(count: noncePrefixSize)
        let status = noncePrefix.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, noncePrefixSize, bytes.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw E2eeAttachmentFrameCryptoError.randomGenerationFailed(status)
        }
        return (contentKey, noncePrefix)
    }

    static func nonceData(prefix: Data, frameIndex: UInt32) throws -> Data {
        guard prefix.count == noncePrefixSize else {
            throw E2eeAttachmentFrameCryptoError.invalidNoncePrefixSize(prefix.count)
        }
        var nonce = Data(prefix)
        nonce.append(UInt8((frameIndex >> 24) & 0xff))
        nonce.append(UInt8((frameIndex >> 16) & 0xff))
        nonce.append(UInt8((frameIndex >> 8) & 0xff))
        nonce.append(UInt8(frameIndex & 0xff))
        return nonce
    }

    static func encryptFile(
        at inputURL: URL,
        to outputURL: URL,
        contentKey: Data,
        noncePrefix: Data,
        frameSize: Int = defaultFrameSize
    ) throws -> E2eeAttachmentFrameCryptoResult {
        try validateParameters(
            inputURL: inputURL,
            outputURL: outputURL,
            contentKey: contentKey,
            noncePrefix: noncePrefix,
            frameSize: frameSize
        )
        let partialURL = partialOutputURL(for: outputURL)
        let input = try FileHandle(forReadingFrom: inputURL)
        try createOutputFile(at: partialURL)
        let output = try FileHandle(forWritingTo: partialURL)
        var succeeded = false
        defer {
            try? input.close()
            try? output.close()
            if !succeeded {
                try? FileManager.default.removeItem(at: partialURL)
            }
        }

        let key = SymmetricKey(data: contentKey)
        var plaintextHasher = SHA256()
        var ciphertextHasher = SHA256()
        var plaintextSize: UInt64 = 0
        var ciphertextSize: UInt64 = 0
        var frameIndex: UInt32 = 0
        var frameCount: UInt32 = 0
        var wroteFrame = false

        while true {
            let plaintext = try input.read(upToCount: frameSize) ?? Data()
            if plaintext.isEmpty, wroteFrame {
                break
            }
            let nonce = try AES.GCM.Nonce(data: nonceData(prefix: noncePrefix, frameIndex: frameIndex))
            let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
            var body = Data(sealed.ciphertext)
            body.append(sealed.tag)
            let header = try frameHeader(plaintextLength: plaintext.count, ciphertextLength: body.count)

            try output.write(contentsOf: header)
            try output.write(contentsOf: body)
            plaintextHasher.update(data: plaintext)
            ciphertextHasher.update(data: header)
            ciphertextHasher.update(data: body)
            plaintextSize = try addingWithoutOverflow(plaintextSize, UInt64(plaintext.count))
            ciphertextSize = try addingWithoutOverflow(ciphertextSize, UInt64(header.count + body.count))
            wroteFrame = true
            frameCount += 1

            if plaintext.isEmpty {
                break
            }
            guard frameIndex < UInt32.max else {
                throw E2eeAttachmentFrameCryptoError.frameIndexOverflow
            }
            frameIndex += 1
        }

        try output.synchronize()
        try output.close()
        try input.close()
        try FileManager.default.moveItem(at: partialURL, to: outputURL)
        succeeded = true
        return E2eeAttachmentFrameCryptoResult(
            plaintextSize: plaintextSize,
            plaintextSha256: hex(Data(plaintextHasher.finalize())),
            ciphertextSize: ciphertextSize,
            ciphertextSha256: hex(Data(ciphertextHasher.finalize())),
            frameCount: frameCount,
            frameSize: UInt32(frameSize)
        )
    }

    static func decryptFile(
        at inputURL: URL,
        to outputURL: URL,
        contentKey: Data,
        noncePrefix: Data,
        frameSize: Int = defaultFrameSize
    ) throws -> E2eeAttachmentFrameCryptoResult {
        try validateParameters(
            inputURL: inputURL,
            outputURL: outputURL,
            contentKey: contentKey,
            noncePrefix: noncePrefix,
            frameSize: frameSize
        )
        let partialURL = partialOutputURL(for: outputURL)
        let input = try FileHandle(forReadingFrom: inputURL)
        try createOutputFile(at: partialURL)
        let output = try FileHandle(forWritingTo: partialURL)
        var succeeded = false
        defer {
            try? input.close()
            try? output.close()
            if !succeeded {
                try? FileManager.default.removeItem(at: partialURL)
            }
        }

        let key = SymmetricKey(data: contentKey)
        var plaintextHasher = SHA256()
        var ciphertextHasher = SHA256()
        var plaintextSize: UInt64 = 0
        var ciphertextSize: UInt64 = 0
        var frameIndex: UInt32 = 0
        var frameCount: UInt32 = 0
        var sawShortFrame = false

        while let header = try readExactly(headerSize, from: input, allowCleanEOF: true) {
            if sawShortFrame {
                throw E2eeAttachmentFrameCryptoError.shortFrameBeforeEnd
            }
            let plaintextLength = readUInt32(header, offset: 0)
            let ciphertextLength = readUInt32(header, offset: 4)
            guard plaintextLength <= UInt32(frameSize) else {
                throw E2eeAttachmentFrameCryptoError.invalidPlaintextLength(plaintextLength)
            }
            guard UInt64(ciphertextLength) == UInt64(plaintextLength) + UInt64(tagSize),
                  ciphertextLength <= UInt32(frameSize + tagSize) else {
                throw E2eeAttachmentFrameCryptoError.invalidCiphertextLength(ciphertextLength)
            }
            guard let body = try readExactly(Int(ciphertextLength), from: input, allowCleanEOF: false) else {
                throw E2eeAttachmentFrameCryptoError.invalidFrameHeader
            }
            let split = body.count - tagSize
            let nonce = try AES.GCM.Nonce(data: nonceData(prefix: noncePrefix, frameIndex: frameIndex))
            let box = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: body.prefix(split),
                tag: body.suffix(tagSize)
            )
            let plaintext = try AES.GCM.open(box, using: key)
            guard plaintext.count == Int(plaintextLength) else {
                throw E2eeAttachmentFrameCryptoError.invalidPlaintextLength(plaintextLength)
            }
            try output.write(contentsOf: plaintext)
            plaintextHasher.update(data: plaintext)
            ciphertextHasher.update(data: header)
            ciphertextHasher.update(data: body)
            plaintextSize = try addingWithoutOverflow(plaintextSize, UInt64(plaintext.count))
            ciphertextSize = try addingWithoutOverflow(ciphertextSize, UInt64(header.count + body.count))
            frameCount += 1
            sawShortFrame = plaintextLength < UInt32(frameSize)

            guard frameIndex < UInt32.max else {
                throw E2eeAttachmentFrameCryptoError.frameIndexOverflow
            }
            frameIndex += 1
        }

        guard frameCount > 0 else {
            throw E2eeAttachmentFrameCryptoError.emptyCiphertext
        }
        try output.synchronize()
        try output.close()
        try input.close()
        try FileManager.default.moveItem(at: partialURL, to: outputURL)
        succeeded = true
        return E2eeAttachmentFrameCryptoResult(
            plaintextSize: plaintextSize,
            plaintextSha256: hex(Data(plaintextHasher.finalize())),
            ciphertextSize: ciphertextSize,
            ciphertextSha256: hex(Data(ciphertextHasher.finalize())),
            frameCount: frameCount,
            frameSize: UInt32(frameSize)
        )
    }

    private static func validateParameters(
        inputURL: URL,
        outputURL: URL,
        contentKey: Data,
        noncePrefix: Data,
        frameSize: Int
    ) throws {
        guard inputURL.standardizedFileURL != outputURL.standardizedFileURL else {
            throw E2eeAttachmentFrameCryptoError.inputAndOutputMatch
        }
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw E2eeAttachmentFrameCryptoError.outputAlreadyExists
        }
        guard contentKey.count == keySize else {
            throw E2eeAttachmentFrameCryptoError.invalidKeySize(contentKey.count)
        }
        guard noncePrefix.count == noncePrefixSize else {
            throw E2eeAttachmentFrameCryptoError.invalidNoncePrefixSize(noncePrefix.count)
        }
        guard frameSize > 0, frameSize <= Int(UInt32.max) - tagSize else {
            throw E2eeAttachmentFrameCryptoError.invalidFrameSize(frameSize)
        }
    }

    private static func createOutputFile(at url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func partialOutputURL(for outputURL: URL) -> URL {
        outputURL.deletingLastPathComponent().appendingPathComponent(
            ".\(outputURL.lastPathComponent).\(UUID().uuidString).partial"
        )
    }

    private static func frameHeader(plaintextLength: Int, ciphertextLength: Int) throws -> Data {
        guard let plaintextLength = UInt32(exactly: plaintextLength) else {
            throw E2eeAttachmentFrameCryptoError.invalidPlaintextLength(UInt32.max)
        }
        guard let ciphertextLength = UInt32(exactly: ciphertextLength) else {
            throw E2eeAttachmentFrameCryptoError.invalidCiphertextLength(UInt32.max)
        }
        var header = Data()
        appendUInt32(plaintextLength, to: &header)
        appendUInt32(ciphertextLength, to: &header)
        return header
    }

    private static func appendUInt32(_ value: UInt32, to output: inout Data) {
        output.append(UInt8((value >> 24) & 0xff))
        output.append(UInt8((value >> 16) & 0xff))
        output.append(UInt8((value >> 8) & 0xff))
        output.append(UInt8(value & 0xff))
    }

    private static func readUInt32(_ data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24 |
            UInt32(data[offset + 1]) << 16 |
            UInt32(data[offset + 2]) << 8 |
            UInt32(data[offset + 3])
    }

    private static func readExactly(
        _ count: Int,
        from handle: FileHandle,
        allowCleanEOF: Bool
    ) throws -> Data? {
        var result = Data()
        while result.count < count {
            let chunk = try handle.read(upToCount: count - result.count) ?? Data()
            if chunk.isEmpty {
                if result.isEmpty, allowCleanEOF {
                    return nil
                }
                throw E2eeAttachmentFrameCryptoError.invalidFrameHeader
            }
            result.append(chunk)
        }
        return result
    }

    private static func addingWithoutOverflow(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw E2eeAttachmentFrameCryptoError.sizeOverflow }
        return result
    }

    private static func multiplyingWithoutOverflow(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow else { throw E2eeAttachmentFrameCryptoError.sizeOverflow }
        return result
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
