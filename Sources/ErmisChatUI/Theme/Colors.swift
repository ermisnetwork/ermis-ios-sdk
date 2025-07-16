//
// Copyright 2025 Ermis Inc.
//

import UIKit

public class Colors {
    // MARK: - Texts
    public var text = BaseColor.onSurface
    public var subtitleText = BaseColor.onSurfaceVariant
    public var subTitleTextLow = BaseColor.onSurfaceVariantLow
    public var subTitleTextHigh = BaseColor.onSurfaceVariantHigh

    public var channelUnreadcountText = BaseColor.onError

    public var incommingMessageText = BaseColor.onSurface
    public var outgoingMessageText = BaseColor.onPrimary
    public var incommingQuotedMessageText = BaseColor.onSurface
    public var outgoingQuotedMessageText = BaseColor.onPrimary

    public var mentionUserText = BaseColor.error
    public var incomingMentionOtherUserText = BaseColor.onSurface
    public var outgoingMentionOtherUserText = BaseColor.onPrimary

    public var systemMessageText = BaseColor.onSurfaceVariant
    public var textLinkColor = BaseColor.primary

    public var messageListSeparatorText = BaseColor.onSurface

    public var reactionCountText = BaseColor.onSurface
    public var currentUserReactionCountText = BaseColor.onPrimary
    // MARK: - Background
    public var channelUnreadcountBackground = BaseColor.error

    public var incommingBubbleMessageBackground = BaseColor.surfaceContainer
    public var outgoingBubbleMessageBackground = BaseColor.primary
    public var incommingBubbleQuotedMessageBackground = BaseColor.surfaceContainerLow
    public var outgoingBubbleQuotedMessageBackground = BaseColor.primaryDark
    public var messageListSeparatorBackground = BaseColor.surfaceContainerHigh
    public var systemMessageBackground = BaseColor.surfaceContainerLowest
    
    public var reactionBubbleBackground = BaseColor.surfaceContainerHighest
    public var reactionItemBackground = BaseColor.surfaceContainerHighest
    public var currentUserReactionItemBackground = BaseColor.primary

    public var jumpToUnreadMessageButtonBackground = BaseColor.surfaceContainerLowest

    public var channelListItemBackground = BaseColor.surface
    public var invitedChannelListItemBackground = BaseColor.surface
    // MARK: - Border
    public var reactionBubbleBorder = BaseColor.outline
    public var jumpToUnreadMessageButtonBorder = BaseColor.outlineVariant

    // MARK: - Base colors
    public var white = UIColor.white
    public var black = UIColor.black
    public var primary = BaseColor.primary
    public var primaryLight = BaseColor.primaryLight
    public var primaryDark = BaseColor.primaryDark
    public var onPrimary = BaseColor.onPrimary
    public var primaryContainer = BaseColor.primaryContainer
    public var primaryContainerLight = BaseColor.primaryContainerLight
    public var primaryContainerDark = BaseColor.primaryContainerDark
    public var onPrimaryContainer = BaseColor.onPrimaryContainer
    public var error = BaseColor.error
    public var onError = BaseColor.onError
    public var errorContainer = BaseColor.errorContainer
    public var onErrorContainer = BaseColor.onErrorContainer
    public var errorLight = BaseColor.errorLight
    public var errorHigh = BaseColor.errorHigh
    public var outline = BaseColor.outline
    public var outlineVariantHigh = BaseColor.outlineVariantHigh
    public var outlineVariant = BaseColor.outlineVariant
    public var surface = BaseColor.surface
    public var surfaceBright = BaseColor.surfaceBright
    public var onSurface = BaseColor.onSurface
    public var inverseSurface = BaseColor.inverseSurface
    public var inverseOnSurface = BaseColor.inverseOnSurface
    public var surfaceContainerHighest = BaseColor.surfaceContainerHighest
    public var surfaceContainerHigh = BaseColor.surfaceContainerHigh
    public var surfaceContainer = BaseColor.surfaceContainer
    public var surfaceContainerLow = BaseColor.surfaceContainerLow
    public var surfaceContainerLowest = BaseColor.surfaceContainerLowest
    public var success = BaseColor.success
    public var successContainer = BaseColor.successContainer
    public var onSuccess = BaseColor.onSuccess
    public var onSuccessContainer = BaseColor.onSuccessContainer
    public var info = BaseColor.info
    public var infoContainer = BaseColor.infoContainer
    public var onInfo = BaseColor.onInfo
    public var onInfoContainer = BaseColor.onInfoContainer
    public var onSurfaceHigh = BaseColor.onSurfaceHigh

    // MARK: - Text interactions
    public var highlightedColorForColor: (UIColor) -> UIColor = { $0.withAlphaComponent(0.5) }
    public var disabledColorForColor: (UIColor) -> UIColor = { _ in .lightGray }
    public var unselectedColorForColor: (UIColor) -> UIColor = { _ in .lightGray }
}

public struct BaseColor {
    //
    public static var primary = mode(RefColors.primary(40), RefColors.primary(20))
    public static var primaryLight = mode(RefColors.primary(30), RefColors.primary(10))
    public static var primaryDark = mode(RefColors.primary(50), RefColors.primary(30))
    public static var onPrimary = mode(RefColors.white, RefColors.primary(90))
    public static var primaryContainer = mode(RefColors.primary(10), RefColors.primary(80))
    public static var primaryContainerLight = mode(RefColors.primary(6), RefColors.primary(70))
    public static var primaryContainerDark = mode(RefColors.primary(20), RefColors.primary(90))
    public static var onPrimaryContainer = mode(RefColors.primary(70), RefColors.primary(10))
    public static var error = mode(RefColors.red(50), RefColors.red(10))
    public static var onError = mode(RefColors.white, RefColors.red(95))
    public static var errorContainer = mode(RefColors.red(10), RefColors.red(70))
    public static var onErrorContainer = mode(RefColors.red(80), RefColors.red(6))
    public static var errorLight = mode(RefColors.red(40), RefColors.red(6))
    public static var errorHigh = mode(RefColors.red(60), RefColors.red(20))
    public static var outline = mode(RefColors.neutral(30), RefColors.neutral(60))
    public static var outlineVariantHigh = mode(RefColors.neutral(40), RefColors.neutral(50))
    public static var outlineVariant = mode(RefColors.neutral(20), RefColors.neutral(70))
    public static var surface = mode(RefColors.neutral(3), RefColors.neutral(95))
    public static var surfaceBright = mode(RefColors.white, RefColors.black)
    public static var onSurface = mode(RefColors.neutral(80), RefColors.neutral(30))
    public static var onSurfaceVariantLow = mode(RefColors.neutral(40), RefColors.neutral(60))
    public static var onSurfaceVariant = mode(RefColors.neutral(50), RefColors.neutral(50))
    public static var onSurfaceVariantHigh = mode(RefColors.neutral(70), RefColors.neutral(40))
    public static var inverseSurface = mode(RefColors.neutral(80), RefColors.neutral(20))
    public static var inverseOnSurface = mode(RefColors.neutral(3), RefColors.neutral(80))
    public static var surfaceContainerHighest = mode(RefColors.neutral(30), RefColors.neutral(50))
    public static var surfaceContainerHigh = mode(RefColors.neutral(20), RefColors.neutral(70))
    public static var surfaceContainer = mode(RefColors.neutral(10), RefColors.neutral(75))
    public static var surfaceContainerLow = mode(RefColors.neutral(6), RefColors.neutral(80))
    public static var surfaceContainerLowest = mode(RefColors.neutral(3), RefColors.neutral(90))
    public static var success = mode(RefColors.green(50), RefColors.green(40))
    public static var successContainer = mode(RefColors.green(6), RefColors.green(70))
    public static var onSuccess = mode(RefColors.white, RefColors.green(90))
    public static var onSuccessContainer = mode(RefColors.green(90), RefColors.green(6))
    public static var info = mode(RefColors.blue(50), RefColors.blue(30))
    public static var infoContainer = mode(RefColors.blue(6), RefColors.blue(80))
    public static var onInfo = mode(RefColors.white, RefColors.blue(95))
    public static var onInfoContainer = mode(RefColors.blue(95), RefColors.blue(3))
    public static var onSurfaceHigh = mode(RefColors.neutral(90), RefColors.neutral(20))

    static func mode(_ light: Int, lightAlpha: CGFloat = 1.0, _ dark: Int, darkAlpha: CGFloat = 1.0) -> UIColor {
        return UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark
            ? UIColor(rgb: dark).withAlphaComponent(darkAlpha)
            : UIColor(rgb: light).withAlphaComponent(lightAlpha)
        }
    }

    static func mode(_ lightColor: UIColor, lightAlpha: CGFloat = 1, _ darkColor: UIColor, darkAlpha: CGFloat = 1) -> UIColor {
        return UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark ? darkColor.withAlphaComponent(darkAlpha) : lightColor.withAlphaComponent(lightAlpha)
        }
    }

    static func mode(_ lightRefColor: RefColors, _ darkRefColor: RefColors) -> UIColor {
        return UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark ? darkRefColor.color : lightRefColor.color
        }
    }
}

enum RefColors {
    // Base
    case white
    case black
    // Primary
    case primary(Int)
    case neutral(Int)
    case red(Int)
    case yellow(Int)
    case green(Int)
    case blue(Int)

    var color: UIColor {
        switch self {
        case .white:
            return UIColor(hex: "#FFFFFF")
        case .black:
            return UIColor(hex: "#000000")
        case .primary(let rawValue):
            return primaryColor(with: rawValue)
        case .neutral(let rawValue):
            return neutralColor(with: rawValue)
        case .red(let rawValue):
            return redColor(with: rawValue)
        case .yellow(let rawValue):
            return yellowColor(with: rawValue)
        case .green(let rawValue):
            return greenColor(with: rawValue)
        case .blue(let rawValue):
            return blueColor(with: rawValue)
        }
    }

    private func primaryColor(with rawValue: Int) -> UIColor {
        switch rawValue {
        case 3:
            return UIColor(hex: "#FAFAFF")
        case 6:
            return UIColor(hex: "#F1F1FE")
        case 8:
            return UIColor(hex: "#E0E0FF")
        case 10:
            return UIColor(hex: "#D4D4FB")
        case 20:
            return UIColor(hex: "#B7B7F8")
        case 30:
            return UIColor(hex: "#A1A1FF")
        case 40:
            return UIColor(hex: "#6F6FF1")
        case 50:
            return UIColor(hex: "#5D5DCA")
        case 60:
            return UIColor(hex: "#4B4BA4")
        case 70:
            return UIColor(hex: "#3A3A7D")
        case 80:
            return UIColor(hex: "#282857")
        case 90:
            return UIColor(hex: "#161630")
        default:
            return UIColor.clear
        }
    }

    private func neutralColor(with rawValue: Int) -> UIColor {
        switch rawValue {
        case 3:
            return UIColor(hex: "#FCFCFD")
        case 6:
            return UIColor(hex: "#F9FAFB")
        case 10:
            return UIColor(hex: "#F2F4F7")
        case 20:
            return UIColor(hex: "#EAECF0")
        case 30:
            return UIColor(hex: "#D0D5DD")
        case 40:
            return UIColor(hex: "#98A2B3")
        case 50:
            return UIColor(hex: "#667085")
        case 60:
            return UIColor(hex: "#4B5565")
        case 70:
            return UIColor(hex: "#344054")
        case 75:
            return UIColor(hex: "#28313E")
        case 80:
            return UIColor(hex: "#182230")
        case 90:
            return UIColor(hex: "#101828")
        case 95:
            return UIColor(hex: "#0B0B0F")
        default:
            return .clear
        }
    }

    private func redColor(with rawValue: Int) -> UIColor {
        switch rawValue {
        case 3:
            return UIColor(hex: "#FFFBFA")
        case 6:
            return UIColor(hex: "#FEF3F2")
        case 10:
            return UIColor(hex: "#FEE4E2")
        case 20:
            return UIColor(hex: "#FECDCA")
        case 30:
            return UIColor(hex: "#FDA29B")
        case 40:
            return UIColor(hex: "#F97066")
        case 50:
            return UIColor(hex: "#F04438")
        case 60:
            return UIColor(hex: "#D92D20")
        case 70:
            return UIColor(hex: "#B42318")
        case 80:
            return UIColor(hex: "#912018")
        case 90:
            return UIColor(hex: "#7A271A")
        case 95:
            return UIColor(hex: "#55160C")
        default:
            return UIColor.clear
        }
    }

    private func yellowColor(with rawValue: Int) -> UIColor {
        switch rawValue {
        case 3:
            return UIColor(hex: "#FFFCF5")
        case 6:
            return UIColor(hex: "#FFFAEB")
        case 10:
            return UIColor(hex: "#FEF0C7")
        case 20:
            return UIColor(hex: "#FEDF89")
        case 30:
            return UIColor(hex: "#FEC84B")
        case 40:
            return UIColor(hex: "#FDB022")
        case 50:
            return UIColor(hex: "#F79009")
        case 60:
            return UIColor(hex: "#DC6803")
        case 70:
            return UIColor(hex: "#B54708")
        case 80:
            return UIColor(hex: "#93370D")
        case 90:
            return UIColor(hex: "#7A2E0E")
        case 95:
            return UIColor(hex: "#4E1D09")
        default:
            return UIColor.clear
        }
    }

    private func greenColor(with rawValue: Int) -> UIColor {
        switch rawValue {
        case 3:
            return UIColor(hex: "#F6FEF9")
        case 6:
            return UIColor(hex: "#ECFDF3")
        case 10:
            return UIColor(hex: "#DCFAE6")
        case 20:
            return UIColor(hex: "#ABEFC6")
        case 30:
            return UIColor(hex: "#75E0A7")
        case 40:
            return UIColor(hex: "#47CD89")
        case 50:
            return UIColor(hex: "#17B26A")
        case 60:
            return UIColor(hex: "#079455")
        case 70:
            return UIColor(hex: "#067647")
        case 80:
            return UIColor(hex: "#085D3A")
        case 90:
            return UIColor(hex: "#074D31")
        case 95:
            return UIColor(hex: "#053321")
        default:
            return UIColor.clear
        }
    }

    private func blueColor(with rawValue: Int) -> UIColor {
        switch rawValue {
        case 3:
            return UIColor(hex: "#F5FAFF")
        case 6:
            return UIColor(hex: "#EFF8FF")
        case 10:
            return UIColor(hex: "#D2E9FF")
        case 20:
            return UIColor(hex: "#B2DDFF")
        case 30:
            return UIColor(hex: "#85CAFF")
        case 40:
            return UIColor(hex: "#53B1FD")
        case 50:
            return UIColor(hex: "#2E90FA")
        case 60:
            return UIColor(hex: "#1470EF")
        case 70:
            return UIColor(hex: "#175CD3")
        case 80:
            return UIColor(hex: "#1849A9")
        case 90:
            return UIColor(hex: "#1A4184")
        case 95:
            return UIColor(hex: "#112A56")
        default:
            return UIColor.clear
        }
    }
}
