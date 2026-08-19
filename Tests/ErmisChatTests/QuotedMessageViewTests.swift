import XCTest
import UIKit

@testable import ErmisChat
@testable import ErmisChatUI

@MainActor
final class QuotedMessageViewTests: XCTestCase {
    func testChatUILocalizationFallsBackToItsOwnResourceBundle() {
        XCTAssertNotEqual(L10n.Message.encryptedMessage, "message.encrypted-message")
        XCTAssertNotEqual(L10n.Message.QuotedMessage.repliedToYou, "message.quoted-message.replied-to-you")
        XCTAssertNotEqual(
            L10n.Message.QuotedMessage.repliedTo("Author"),
            "message.quoted-message.replied-to"
        )
    }

    func testEncryptedParentReplacesDeletedPlaceholderWhenViewIsReused() {
        let host = UIView()
        let view = QuotedMessageView()
        host.addSubview(view)
        view.content = .init(
            message: makeMessage(id: "deleted", deletedAt: Date()),
            repliedMessageAuthor: nil
        )

        XCTAssertEqual(view.textView.text, L10n.Message.deletedMessagePlaceholder)

        view.content = .init(
            message: makeMessage(id: "encrypted", encryptedData: Data([1, 2, 3])),
            repliedMessageAuthor: nil
        )

        XCTAssertEqual(view.textView.text, L10n.Message.encryptedMessage)
    }

    func testEmptyNonEncryptedParentClearsReusedPlaceholder() {
        let host = UIView()
        let view = QuotedMessageView()
        host.addSubview(view)
        view.content = .init(
            message: makeMessage(id: "deleted", deletedAt: Date()),
            repliedMessageAuthor: nil
        )

        view.content = .init(
            message: makeMessage(id: "empty"),
            repliedMessageAuthor: nil
        )

        XCTAssertEqual(view.textView.text, "")
    }

    private func makeMessage(
        id: MessageId,
        encryptedData: Data? = nil,
        deletedAt: Date? = nil
    ) -> ChatMessage {
        let author = ChatUser(
            id: "author",
            projectId: "project",
            name: "Author",
            imageURL: nil,
            phone: nil,
            email: nil,
            isOnline: true,
            isBanned: false,
            isFlaggedByCurrentUser: false,
            userRole: .user,
            createdAt: nil,
            updatedAt: nil,
            deactivatedAt: nil,
            lastActiveAt: nil,
            teams: [],
            language: nil
        )
        let now = Date()
        return ChatMessage(
            id: id,
            cid: ChannelId(type: .team, projectId: "project", id: "quoted-message-view"),
            text: "",
            encryptedData: encryptedData,
            mlsEpoch: encryptedData == nil ? nil : 1,
            oldTexts: nil,
            type: .regular,
            command: nil,
            createdAt: now,
            locallyCreatedAt: nil,
            updatedAt: now,
            deletedAt: deletedAt,
            arguments: nil,
            parentMessageId: nil,
            replyCount: 0,
            quotedMessageId: nil,
            quotedMessage: { nil },
            forwardChannelId: nil,
            isBounced: false,
            isSilent: false,
            isShadowed: false,
            reactionScores: [:],
            reactionCounts: [:],
            author: { author },
            mentionedUsers: { [] },
            mentionedAll: false,
            threadParticipants: { [] },
            threadParticipantsCount: { 0 },
            attachments: { [] },
            latestReplies: { [] },
            localState: nil,
            isFlaggedByCurrentUser: false,
            latestReactions: { [] },
            currentUserReactions: { [] },
            currentUserReactionsCount: { 0 },
            isSentByCurrentUser: false,
            translations: nil,
            originalLanguage: nil,
            moderationDetails: nil,
            decryptedMessage: nil,
            readBy: { [] },
            readByCount: { 0 },
            underlyingContext: nil,
            textUpdatedAt: nil
        )
    }
}
