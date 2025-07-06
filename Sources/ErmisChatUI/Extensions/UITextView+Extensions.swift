//
// Copyright 2025 Ermis Inc.
//

import UIKit
import ErmisChat

extension UITextView {
    func highlightMentions(_ mentionUser: ChatUser, isCurrentUser: Bool, isSendByCurrentUser: Bool) {
        linkTextAttributes = [:]
        let mentionString = mentionUser.mentionString
        let mentionDisplayedString = mentionUser.mentionsDisplayString

        let attributeText = NSMutableAttributedString(attributedString: attributedText)
        var string = attributeText.string

        let ranges = string.ranges(of: mentionString)
        var indexOffset: Int = 0

        var messageRanges: [Range<String.Index>] = []
        var tempString = string

        for range in ranges {
            tempString.append(mentionDisplayedString)
        }

        var mentionOtherUserTextColor = isSendByCurrentUser
        ? Theme.default.colors.outgoingMentionOtherUserText
        : Theme.default.colors.incomingMentionOtherUserText

        var mentionCurrentUserTextColor = Theme.default.colors.mentionUserText

        for range in ranges.map { NSRange($0, in: string)}.reversed() {
            attributeText.replaceCharacters(in: range, with: mentionUser.mentionsDisplayString)
            let newRange = NSRange(location: range.location, length: mentionUser.mentionsDisplayString.count)
            attributeText.addAttribute(.link, value: "", range: newRange)
            attributeText.addAttribute(.foregroundColor, value: isCurrentUser
                                       ? mentionCurrentUserTextColor
                                       : mentionOtherUserTextColor, range: newRange)
            attributeText.addAttribute(.font, value: font?.bold, range: newRange)
        }

        attributedText = attributeText
    }

    func highlightMentionAllUsers() {
        linkTextAttributes = [:]
        let attributeText = NSMutableAttributedString(attributedString: attributedText)
        var string = attributeText.string
        
        string.ranges(of: "@all", options: [.caseInsensitive])
            .map({ NSRange($0, in: string)})
            .forEach{
                attributeText.addAttribute(.link, value: "", range: $0)
                attributeText.addAttribute(.foregroundColor,
                                           value: Theme.default.colors.mentionUserText,
                                           range: $0)
                attributeText.addAttribute(.font, value: font?.bold, range: $0)
            }

        attributedText = attributeText
    }
}
