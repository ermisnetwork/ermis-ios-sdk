//
// Copyright 2025 Ermis Inc.
//

import Foundation

public enum OtpLanguage: String, Codable {
    case en = "En"
    case vi = "Vi"
}

public enum OtpMethod: String, Codable {
    case email = "Email"
    case sms = "Sms"
    case voice = "Voice"
}

public enum OtpType: String, Codable {
    case login = "Login"
    case delete = "Delete"
}


public struct GetOtpRequestBody: Codable {
    let apiKey: String
    let identifier: String
    let language: OtpLanguage
    let method: OtpMethod
    let otpType: OtpType

    public init(apiKey: String,
                identifier: String,
                language: OtpLanguage,
                method: OtpMethod,
                otpType: OtpType) {
        self.apiKey = apiKey
        self.identifier = identifier
        self.language = language
        self.method = method
        self.otpType = otpType
    }

    enum CodingKeys: String, CodingKey {
        case apiKey = "apikey"
        case identifier
        case language
        case method
        case otpType = "otp_type"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.apiKey = try container.decode(String.self, forKey: .apiKey)
        self.identifier = try container.decode(String.self, forKey: .identifier)
        self.language = try container.decode(OtpLanguage.self, forKey: .language)
        self.method = try container.decode(OtpMethod.self, forKey: .method)
        self.otpType = try container.decode(OtpType.self, forKey: .otpType)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.apiKey, forKey: .apiKey)
        try container.encode(self.identifier, forKey: .identifier)
        try container.encode(self.language, forKey: .language)
        try container.encode(self.method, forKey: .method)
        try container.encode(self.otpType, forKey: .otpType)
    }
}
