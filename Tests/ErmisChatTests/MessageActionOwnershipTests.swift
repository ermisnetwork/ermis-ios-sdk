import CoreData
import XCTest

@testable import ErmisChat
@testable import ErmisChatUI

final class MessageActionOwnershipTests: XCTestCase {
    private let cid = "team:project:message-action-ownership"

    func testForeignFailedLocalStateUsesNormalInteractiveActionBranchEvenWithStaleOwnershipFlag() {
        let message = makeMessage(
            authorId: "other",
            isSentByCurrentUser: true,
            localState: .syncingFailed
        )
        let currentUser = makeCurrentUser(id: "me")

        XCTAssertTrue(message.isInteractionEnabled)
        XCTAssertFalse(message.isAuthoredByCurrentUser(currentUser))
        XCTAssertNil(message.effectiveLocalStateForMessageActions(currentUser: currentUser))
    }

    func testOwnFailedLocalStateKeepsRetryMutationActionBranch() {
        let message = makeMessage(
            authorId: "me",
            isSentByCurrentUser: true,
            localState: .syncingFailed
        )
        let currentUser = makeCurrentUser(id: "me")

        XCTAssertTrue(message.isInteractionEnabled)
        XCTAssertTrue(message.isLastActionFailed)
        XCTAssertTrue(message.isAuthoredByCurrentUser(currentUser))
        XCTAssertEqual(
            message.effectiveLocalStateForMessageActions(currentUser: currentUser),
            .syncingFailed
        )
    }

    func testForeignMessageCannotBeEditedOrResentLocally() throws {
        let database = try makeDatabase()
        defer { try? close(database) }

        try database.writeAndWait { session in
            try saveCurrentUser(in: session)
            let channel = try session.saveChannel(payload: try channelPayload())
            let message = try XCTUnwrap(channel.messages.first { $0.id == "foreign-message" })
            message.localMessageState = .syncingFailed

            XCTAssertThrowsError(try session.messageEditableByCurrentUser(message.id))
            XCTAssertEqual(message.localMessageState, .syncingFailed)
        }
    }

    func testAuthoritativeForeignPayloadClearsInvalidLocalMutationState() throws {
        let database = try makeDatabase()
        defer { try? close(database) }
        let payload = try channelPayload()

        try database.writeAndWait { session in
            try saveCurrentUser(in: session)
            let channel = try session.saveChannel(payload: payload)
            let message = try XCTUnwrap(channel.messages.first { $0.id == "foreign-message" })
            message.localMessageState = .syncingFailed
            message.isHardDeleted = true

            _ = try session.saveMessage(
                payload: try XCTUnwrap(payload.messages.first),
                channelDTO: channel,
                syncOwnReactions: false,
                cache: nil
            )

            XCTAssertNil(message.localMessageState)
            XCTAssertFalse(message.isHardDeleted)
        }
    }

    private func makeMessage(
        authorId: String,
        isSentByCurrentUser: Bool,
        localState: LocalMessageState?
    ) -> ChatMessage {
        let author = ChatUser(
            id: authorId,
            projectId: "project",
            name: "Other",
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
            id: "message",
            cid: ChannelId(type: .team, projectId: "project", id: "message-action-ownership"),
            text: "hello",
            encryptedData: nil,
            mlsEpoch: nil,
            oldTexts: nil,
            type: .regular,
            command: nil,
            createdAt: now,
            locallyCreatedAt: nil,
            updatedAt: now,
            deletedAt: nil,
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
            localState: localState,
            isFlaggedByCurrentUser: false,
            latestReactions: { [] },
            currentUserReactions: { [] },
            currentUserReactionsCount: { 0 },
            isSentByCurrentUser: isSentByCurrentUser,
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

    private func makeCurrentUser(id: String) -> CurrentChatUser {
        CurrentChatUser(
            id: id,
            projectId: "project",
            name: "Me",
            imageURL: nil,
            phone: nil,
            email: nil,
            isOnline: true,
            isInvisible: false,
            isBanned: false,
            userRole: .user,
            createdAt: nil,
            updatedAt: nil,
            deactivatedAt: nil,
            lastActiveAt: nil,
            teams: [],
            language: nil,
            devices: [],
            currentDevice: nil,
            mutedUsers: [],
            flaggedUsers: [],
            flaggedMessageIDs: [],
            unreadCount: .noUnread,
            underlyingContext: nil
        )
    }

    private func saveCurrentUser(in session: any DatabaseSession) throws {
        let now = Date()
        let payload = CurrentUserPayload(
            id: "me",
            projectId: "project",
            name: "Me",
            imageURL: nil,
            phone: nil,
            email: nil,
            role: .user,
            createdAt: now,
            updatedAt: now,
            deactivatedAt: nil,
            lastActiveAt: now,
            isOnline: true,
            isInvisible: false,
            isBanned: false,
            isBlocked: false,
            language: nil,
            isEmailVerified: true,
            bellBoyId: "",
            aboutMe: ""
        )
        try session.saveCurrentUser(payload: payload, projectId: "project")
    }

    private func channelPayload() throws -> ChannelPayload {
        let json = """
        {
          "channel": {
            "cid": "\(cid)",
            "type": "team",
            "save_message": true,
            "last_message_at": "2026-08-07T15:15:00.000Z",
            "created_at": "2026-08-07T15:00:00.000Z",
            "updated_at": "2026-08-07T15:15:00.000Z",
            "member_count": 2,
            "mls_enabled": true
          },
          "messages": [{
            "id": "foreign-message",
            "type": "regular",
            "user": {"id": "other", "project_id": "project"},
            "text": "hello",
            "created_at": "2026-08-07T15:15:00.000Z",
            "updated_at": "2026-08-07T15:15:00.000Z"
          }],
          "read": []
        }
        """
        return try JSONDecoder.default.decode(ChannelPayload.self, from: Data(json.utf8))
    }

    private func makeDatabase() throws -> DatabaseContainer {
        let database = DatabaseContainer(
            kind: .inMemory,
            shouldResetEphemeralValuesOnStart: false
        )
        let storeLoaded = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                !database.persistentStoreCoordinator.persistentStores.isEmpty
            },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [storeLoaded], timeout: 5), .completed)
        return database
    }

    private func close(_ database: DatabaseContainer) throws {
        for context in database.allContext {
            context.performAndWait { context.reset() }
        }
        for store in database.persistentStoreCoordinator.persistentStores {
            try database.persistentStoreCoordinator.remove(store)
        }
    }
}
