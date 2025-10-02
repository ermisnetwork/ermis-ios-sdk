// Generated using SwiftGen — https://github.com/SwiftGen/SwiftGen

import Foundation
import ErmisChatUI

// MARK: - Strings

public enum L10n {

  public enum Alert {
    public enum Actions {
      /// Accept
      public static var accept: String { L10n.tr("Localizable", "alert.actions.accept") }
      /// Cancel
      public static var cancel: String { L10n.tr("Localizable", "alert.actions.cancel") }
      /// Ok
      public static var ok: String { L10n.tr("Localizable", "alert.actions.ok") }
      /// Settings
      public static var settings: String { L10n.tr("Localizable", "alert.actions.settings") }
    }
    public enum Message {
      /// %@ doesn't have permission to use Camera, please change privacy settings
      public static func cameraAccessNotgrandted(_ p1: Any) -> String {
        return L10n.tr("Localizable", "alert.message.camera-access-notgrandted", String(describing: p1))
      }
      /// The camera is unavailable on your device
      public static var cameraUnavailable: String { L10n.tr("Localizable", "alert.message.camera-unavailable") }
      /// %@ doesn't have permission to use Microphone, plase change privacy settings
      public static func micAccessNotgrandted(_ p1: Any) -> String {
        return L10n.tr("Localizable", "alert.message.mic-access-notgrandted", String(describing: p1))
      }
    }
    public enum Title {
      /// Camera
      public static var camera: String { L10n.tr("Localizable", "alert.title.camera") }
      /// Microphone
      public static var mic: String { L10n.tr("Localizable", "alert.title.mic") }
    }
  }

  public enum Call {
    public enum Connection {
      /// Low connection
      public static var lowConnection: String { L10n.tr("Localizable", "call.connection.low-connection") }
      /// %@'s network connection is unstable
      public static func otherConnectionUnstable(_ p1: Any) -> String {
        return L10n.tr("Localizable", "call.connection.other-connection-unstable", String(describing: p1))
      }
      /// Your network connection is unstable
      public static var yourConnectionUnstable: String { L10n.tr("Localizable", "call.connection.your-connection-unstable") }
    }
    public enum Message {
      /// Receiver busy
      public static var receiverBusy: String { L10n.tr("Localizable", "call.message.receiver-busy") }
    }
    public enum Status {
      /// Connecting...
      public static var connecting: String { L10n.tr("Localizable", "call.status.connecting") }
      /// The call was ended
      public static var ended: String { L10n.tr("Localizable", "call.status.ended") }
      /// Ringing...
      public static var ringing: String { L10n.tr("Localizable", "call.status.ringing") }
    }
    public enum Title {
      /// Video call
      public static var videoCall: String { L10n.tr("Localizable", "call.title.video-call") }
      /// Voice call
      public static var voiceCall: String { L10n.tr("Localizable", "call.title.voice-call") }
    }
  }
}

// MARK: - Implementation Details

extension L10n {
  private static func tr(_ table: String, _ key: String, _ args: CVarArg...) -> String {
     // TODO: Using using Theme.default prohibits using Theme injection
     let format = Theme.default.localizationProvider(key, table)
     return String(format: format, locale: Locale.current, arguments: args)
  }
}

private final class BundleToken {
  static let bundle: Bundle = .ermisChatUI
}

