//
// Copyright 2025 Ermis Inc.
//

import Foundation

class MultipartInputStream: InputStream {
    private static let crlf = "\r\n"
    static let boundary: String = String(
        format: "chat-%08x%08x",
        UInt32.random(in: 0...UInt32.max),
        UInt32.random(in: 0...UInt32.max)
    )

    let fileURL: URL
    let fieldName: String
    let fileName: String
    let mimeType: String?

    let headerData: Data
    let footerData: Data
    private var headerOffset = 0
    private var footerOffset = 0
    private var fileStream: InputStream?
    private var phase: Phase = .header

    private var _streamStatus: Stream.Status = .notOpen
    private var _streamError: Error?
    private var _delegate: StreamDelegate?

    override var streamStatus: Stream.Status { _streamStatus }
    override var streamError: Error? { _streamError }
    override var delegate: (any StreamDelegate)? {
        get { _delegate }
        set { _delegate = newValue }
    }

    override var hasBytesAvailable: Bool {
        switch phase {
        case .header: return true
        case .file: return true
        case .footer: return true
        case .done: return false
        }
    }

    init(fileURL: URL, fieldName: String, fileName: String, mimeType: String?) {
        self.fileURL = fileURL
        self.fieldName = fieldName
        self.fileName = fileName
        self.mimeType = mimeType

        var header = "--\(Self.boundary)\(Self.crlf)".data(using: .utf8, allowLossyConversion: false)!
        header.append("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(fileName)\"\(Self.crlf)")
        if let mimeType = mimeType {
            header.append("Content-Type: \(mimeType)\(Self.crlf)")
        }
        header.append(Self.crlf)
        self.headerData = header

        self.footerData = "\(Self.crlf)--\(Self.boundary)--\(Self.crlf)".data(using: .utf8, allowLossyConversion: false )!

        super.init(data: Data())
    }

    override func open() {
        guard _streamStatus == .notOpen else { return }
        _streamStatus = .opening
        fileStream = InputStream(url: fileURL)
        fileStream?.open()
        _streamStatus = .open
    }

    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        _streamStatus = .reading
        switch phase {
        case .header:
            let remainingByteCount = headerData.count - headerOffset
            if remainingByteCount > 0 {
                let chunkSize = min(len, remainingByteCount)
                headerData.copyBytes(to: buffer, from: headerOffset..<(headerOffset + chunkSize))
                headerOffset += chunkSize
                return chunkSize
            } else {
                phase = .file
                return self.read(buffer, maxLength: len)
            }
        case .file:
            guard let fileStream = fileStream else {
                phase = .footer
                return read(buffer, maxLength: len)
            }
            let chunkSize = fileStream.read(buffer, maxLength: len)
            if chunkSize > 0 {
                return chunkSize
            } else {
                phase = .footer
                fileStream.close()
                return read(buffer, maxLength: len)
            }
        case .footer:
            let remainingByteCount = footerData.count - footerOffset
            if remainingByteCount > 0 {
                let chunkSize = min(remainingByteCount, len)
                footerData.copyBytes(to: buffer, count: chunkSize)
                footerOffset += chunkSize
                return chunkSize
            } else {
                phase = .done
                return read(buffer, maxLength: len)
            }
        case .done:
            _streamStatus = .atEnd
            return 0
        }
    }

    override func close() {
        fileStream?.close()
        _streamStatus = .closed
    }

    override func property(forKey key: Stream.PropertyKey) -> Any? { nil }
    override func setProperty(_ property: Any?, forKey key: Stream.PropertyKey) -> Bool { false }

    override func schedule(in aRunLoop: RunLoop, forMode mode: RunLoop.Mode) {}
    override func remove(from aRunLoop: RunLoop, forMode mode: RunLoop.Mode) {}

    enum Phase {
        case header
        case file
        case footer
        case done
    }
}

struct AvatarMultipartFormData {
    private static let crlf = "\r\n"
    static let boundary: String = String(
        format: "chat-%08x%08x",
        UInt32.random(in: 0...UInt32.max),
        UInt32.random(in: 0...UInt32.max)
    )
    
    let data: Data
    let fileName: String
    let mimeType: String?
    let filedName = "avatar"
    private let separator: String = "\r\n"

    init(_ data: Data, fileName: String, mimeType: String? = nil) {
        self.data = data
        self.fileName = fileName
        self.mimeType = mimeType
    }

    func getMultipartFormData() -> Data {
        var data = "--\(Self.boundary)\(AvatarMultipartFormData.crlf)".data(using: .utf8, allowLossyConversion: false)!
        data.append("Content-Disposition: form-data; name=\"avatar\"; filename=\"\(fileName)\"\(AvatarMultipartFormData.crlf)")

        if let mimeType = mimeType {
            data.append("Content-Type: \(mimeType)\(AvatarMultipartFormData.crlf)")
        }

        data.append(AvatarMultipartFormData.crlf)
        data.append(self.data)
        data.append("\(AvatarMultipartFormData.crlf)--\(Self.boundary)--\(AvatarMultipartFormData.crlf)")

        return data
    }
}

private extension Data {
    mutating func append(_ string: String, encoding: String.Encoding = .utf8) {
        append(string.data(using: encoding)!)
    }
}
