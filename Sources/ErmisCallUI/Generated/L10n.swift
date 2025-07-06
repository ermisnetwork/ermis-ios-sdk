// Generated using SwiftGen — https://github.com/SwiftGen/SwiftGen

import Foundation


// MARK: - Strings

internal enum L10n {

  internal enum Alert {
    internal enum Actions {
      /// Accept
      internal static var accept: String { L10n.tr("Localizable", "alert.actions.accept") }
      /// Cancel
      internal static var cancel: String { L10n.tr("Localizable", "alert.actions.cancel") }
      /// Ok
      internal static var ok: String { L10n.tr("Localizable", "alert.actions.ok") }
      /// Settings
      internal static var settings: String { L10n.tr("Localizable", "alert.actions.settings") }
    }
    internal enum Message {
      /// %@ doesn't have permission to use Camera, please change privacy settings
      internal static func cameraAccessNotgrandted(_ p1: Any) -> String {
        return L10n.tr("Localizable", "alert.message.camera-access-notgrandted", String(describing: p1))
      }
      /// The camera is unavailable on your device
      internal static var cameraUnavailable: String { L10n.tr("Localizable", "alert.message.camera-unavailable") }
      /// %@ doesn't have permission to use Microphone, plase change privacy settings
      internal static func micAccessNotgrandted(_ p1: Any) -> String {
        return L10n.tr("Localizable", "alert.message.mic-access-notgrandted", String(describing: p1))
      }
    }
    internal enum Title {
      /// Camera
      internal static var camera: String { L10n.tr("Localizable", "alert.title.camera") }
      /// Microphone
      internal static var mic: String { L10n.tr("Localizable", "alert.title.mic") }
    }
  }

  internal enum Call {
    internal enum Connection {
      /// Low connection
      internal static var lowConnection: String { L10n.tr("Localizable", "call.connection.low-connection") }
      /// %@'s network connection is unstable
      internal static func otherConnectionUnstable(_ p1: Any) -> String {
        return L10n.tr("Localizable", "call.connection.other-connection-unstable", String(describing: p1))
      }
      /// Your network connection is unstable
      internal static var yourConnectionUnstable: String { L10n.tr("Localizable", "call.connection.your-connection-unstable") }
    }
    internal enum Message {
      /// Receiver busy
      internal static var receiverBusy: String { L10n.tr("Localizable", "call.message.receiver-busy") }
    }
    internal enum Status {
      /// Connecting...
      internal static var connecting: String { L10n.tr("Localizable", "call.status.connecting") }
      /// The call was ended
      internal static var ended: String { L10n.tr("Localizable", "call.status.ended") }
      /// Ringing...
      internal static var ringing: String { L10n.tr("Localizable", "call.status.ringing") }
    }
    internal enum Title {
      /// Video call
      internal static var videoCall: String { L10n.tr("Localizable", "call.title.video-call") }
      /// Voice call
      internal static var voiceCall: String { L10n.tr("Localizable", "call.title.voice-call") }
    }
  }
}

// MARK: - Implementation Details

extension L10n {
  private static func tr(_ table: String, _ key: String, _ args: CVarArg...) -> String {
     let format = Bundle.ermisCallUI.localizedString(forKey: key, value: nil, table: table)
     return String(format: format, locale: Locale.current, arguments: args)
  }
}

private final class BundleToken {
  static let bundle: Bundle = .ermisCallUI
}

