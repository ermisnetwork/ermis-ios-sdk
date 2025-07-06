//
// Copyright 2025 Ermis Inc.
//

public enum AuthType: Codable {
    case wallet
    case phone(phoneNumber: String)
    case email(email: String)
    case google
    case apple

    public var isPhoneAuth: Bool {
        switch self {
        case .phone:
            return true
        default:
            return false
        }
    }
}
