//
// Copyright 2025 Ermis Inc.
//

import Foundation

public protocol NotificationTokenProviding {
    var fcmToken: DeviceId? { get set } // Firebase messaging token for push notificaiton
    var deviceToken: DeviceId? { get set } // PushKitRegistry deviceToken for send voip push notification.
}

public class DefaultNotificationTokenProvider: NotificationTokenProviding {
    public var fcmToken: String? {
        get {
            return UserDefaults.standard.string(forKey: "fcmToken")
        }

        set {
            UserDefaults.standard.setValue(newValue, forKey: "fcmToken")
        }
    }

    public var deviceToken: String? {
        get {
            return UserDefaults.standard.string(forKey: "deviceToken")
        }

        set {
            UserDefaults.standard.setValue(newValue, forKey: "deviceToken")
        }
    }
}
