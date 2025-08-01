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

        let updatedAttributeText = NSMutableAttributedString(string: "")

        let pattern = mentionString
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return
        }

        var lastMentionRangeLocation = 0
        regex.enumerateMatches(in: attributedText.string, range: attributedText.string.nsRange) { match, _, _ in
            guard let match else {
                return
            }
            // Copy attributed text befor mention
            let beforeRange = NSRange(location: lastMentionRangeLocation,
                                      length: match.range.location - lastMentionRangeLocation)
            let beforeAttributedString = attributedText.attributedSubstring(from: beforeRange)
            updatedAttributeText.append(beforeAttributedString)
            //

            var mentionOtherUserTextColor = isSendByCurrentUser
            ? Theme.default.colors.outgoingMentionOtherUserText
            : Theme.default.colors.incomingMentionOtherUserText

            var mentionCurrentUserTextColor = Theme.default.colors.mentionUserText
            let mentionAttributedString = NSAttributedString(
                string: mentionDisplayedString, attributes: [
                    .link: "",
                    .foregroundColor: isCurrentUser ? mentionCurrentUserTextColor : mentionCurrentUserTextColor,
                    .font: font?.bold
                ]
            )
            // Append mention displayed string
            updatedAttributeText.append(mentionAttributedString)
            lastMentionRangeLocation = match.range.upperBound
        }
        // If have text after last mention, add it.
        if lastMentionRangeLocation < attributedText.length {
            let lastRange = NSRange(location: lastMentionRangeLocation, length: attributedText.length - lastMentionRangeLocation)
            let afterAttributedText = attributedText.attributedSubstring(from: lastRange)
            updatedAttributeText.append(afterAttributedText)
        }

        attributedText = updatedAttributeText
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
