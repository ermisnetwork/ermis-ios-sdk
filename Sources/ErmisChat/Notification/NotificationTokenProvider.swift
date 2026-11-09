//
// Copyright 2025 Ermis Inc.
//

import Foundation

public protocol NotificationTokenProviding {
    var fcmToken: DeviceId? { get set } // Firebase messaging token for push notificaiton
    var deviceToken: DeviceId? { get set } // PushKitRegistry deviceToken for send voip push notification.
}

public class DefaultNotificationTokenProvider: NotificationTokenProviding {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    convenience init(config: ErmisClientConfig) {
        guard config.localStorageNamespace?.isEmpty == false else {
            self.init()
            return
        }
        guard let defaults = config.namespacedUserDefaults else {
            preconditionFailure("Scoped notification preferences are unavailable")
        }
        self.init(defaults: defaults)
    }

    public var fcmToken: String? {
        get {
            return defaults.string(forKey: "fcmToken")
        }

        set {
            defaults.setValue(newValue, forKey: "fcmToken")
        }
    }

    public var deviceToken: String? {
        get {
            return defaults.string(forKey: "deviceToken")
        }

        set {
            defaults.setValue(newValue, forKey: "deviceToken")
        }
    }
}
