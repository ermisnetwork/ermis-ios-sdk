import CoreData
import XCTest
@testable import ErmisChat

final class MemberReinviteMiddlewareTests: XCTestCase {
    private let cid = ChannelId(type: .team, projectId: "project", id: "reinvite")

    func testMlsAcceptanceWithoutCachedChannelSurvivesTheRealMiddlewarePipeline() throws {
        let db = try database()
        let event = try payload(type: "notification.invite_accepted", user: "target").event()
        try db.writeAndWait { session in
            let context = try XCTUnwrap(session as? NSManagedObjectContext)
            context.delete(try XCTUnwrap(session.channel(cid: self.cid)))
        }
        try db.writeAndWait { session in
            _ = EventDataProcessorMiddleware().handle(event: event, session: session)
            _ = MemberEventMiddleware().handle(event: event, session: session)
            let domain = EventDTOConverterMiddleware().handle(event: event, session: session)
            XCTAssertNotNil(domain, "Acceptance must reach the authoritative refresh even after removal deletes cached channel metadata")
            let signal = try XCTUnwrap(domain as? E2eeInviteAcceptedSignalEvent)
            XCTAssertEqual(signal.cid, self.cid)
            XCTAssertEqual(signal.targetUserId, "target")
            XCTAssertNil(session.channel(cid: self.cid), "A notification must not fabricate channel authority")
        }
    }

    func testCachedMlsAcceptanceRetainsExistingPublicEvent() throws {
        let db = try database()
        let event = try payload(type: "notification.invite_accepted", user: "target").event()
        try db.writeAndWait { session in
            _ = EventDataProcessorMiddleware().handle(event: event, session: session)
            _ = MemberEventMiddleware().handle(event: event, session: session)
            let accepted = try XCTUnwrap(EventDTOConverterMiddleware().handle(event: event, session: session) as? NotificationInviteRespondBackEvent)
            XCTAssertEqual(accepted.cid, self.cid)
            XCTAssertEqual(accepted.member.userId, "target")
            XCTAssertEqual(accepted.respondBackType, .accept)
        }
    }

    func testPlainAcceptanceWithoutCacheDoesNotUseMlsWakeUp() throws {
        let db = try database()
        let response = try payload(type: "notification.invite_accepted", user: "target", mlsEnabled: false)
        let event = try response.event()
        try db.writeAndWait { session in
            let context = try XCTUnwrap(session as? NSManagedObjectContext)
            context.delete(try XCTUnwrap(session.channel(cid: self.cid)))
        }
        try db.writeAndWait { session in
            _ = EventDataProcessorMiddleware().handle(event: event, session: session)
            _ = MemberEventMiddleware().handle(event: event, session: session)
            XCTAssertNil(EventDTOConverterMiddleware().handle(event: event, session: session))
        }
    }

    private func database(authenticated: Bool = true) throws -> DatabaseContainer {
        let db = DatabaseContainer(kind: .inMemory, shouldResetEphemeralValuesOnStart: false)
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !db.persistentStoreCoordinator.persistentStores.isEmpty
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 5), .completed)
        if authenticated {
            let now = Date()
            let account = CurrentUserPayload(
                id: "target", projectId: "project", name: "Target", imageURL: nil,
                phone: nil, email: nil, role: .user, createdAt: now, updatedAt: now,
                deactivatedAt: nil, lastActiveAt: now, isOnline: false, isInvisible: false,
                isBanned: false, isBlocked: false, language: nil, isEmailVerified: true,
                bellBoyId: "", aboutMe: ""
            )
            try db.writeAndWait { session in
                try session.saveCurrentUser(payload: account, projectId: "project")
            }
        }
        try db.writeAndWait { session in
            let dto = ChannelDTO.loadOrCreate(cid: self.cid, context: (try XCTUnwrap(session as? NSManagedObjectContext)), cache: nil)
            dto.createdAt = Date().bridgeDate
            dto.updatedAt = Date().bridgeDate
            dto.mlsEnabled = true
        }
        return db
    }

    private func payload(type: String, user: String, channel: ChannelId? = nil, mlsEnabled: Bool = true) throws -> EventPayload {
        let channel = channel ?? cid
        let bytes = Data("""
        {"type":"\(type)","cid":"\(channel.rawValue)","mls_enabled":\(mlsEnabled),
         "created_at":"2026-10-05T16:53:13.000Z","self_remove":false,
         "user":{"id":"owner","name":"Owner","role":"user",
           "created_at":"2026-10-05T16:00:00.000Z","updated_at":"2026-10-05T16:53:13.000Z"},
         "member":{"user_id":"\(user)","channel_role":"member",
           "created_at":"2026-10-05T16:53:13.000Z",
           "user":{"id":"\(user)","name":"Member","role":"user",
             "created_at":"2026-10-05T16:00:00.000Z","updated_at":"2026-10-05T16:53:13.000Z"}}}
        """.utf8)
        return try JSONDecoder.default.decode(EventPayload.self, from: bytes)
    }

    func testAcceptedCurrentMemberRestoresJoinedMlsDiscoveryAfterRemoval() throws {
        let db = try database()
        let accepted = try NotificationInviteAcceptedEventDTO(from: payload(type: "notification.invite_accepted", user: "target"))
        let removed = try MemberRemovedEventDTO(from: payload(type: "member.removed", user: "target"))
        try db.writeAndWait { session in
            let dto = try XCTUnwrap(session.channel(cid: self.cid))
            let initialMember = try session.saveMember(payload: accepted.member, channelId: self.cid)
            dto.members.insert(initialMember)
            dto.membership = initialMember
            _ = MemberEventMiddleware().handle(event: removed, session: session)
            XCTAssertNil(dto.membership)
            XCTAssertTrue(ChannelDTO.fetchAllJoinedMlsEnabled(context: (try XCTUnwrap(session as? NSManagedObjectContext))).isEmpty)
            _ = MemberEventMiddleware().handle(event: accepted, session: session)
            XCTAssertEqual(dto.membership?.user.userId, "target")
            XCTAssertEqual(dto.members.filter { $0.user.userId == "target" }.count, 1)
            XCTAssertEqual(ChannelDTO.fetchAllJoinedMlsEnabled(context: (try XCTUnwrap(session as? NSManagedObjectContext))).count, 1)
        }
    }

    func testTenSameChannelRemovalAcceptanceCyclesRestoreMembershipWithoutQuery() throws {
        let db = try database()
        let accepted = try NotificationInviteAcceptedEventDTO(from: payload(type: "notification.invite_accepted", user: "target"))
        let removed = try MemberRemovedEventDTO(from: payload(type: "member.removed", user: "target"))
        try db.writeAndWait { session in
            let dto = try XCTUnwrap(session.channel(cid: self.cid))
            let initialMember = try session.saveMember(payload: accepted.member, channelId: self.cid)
            dto.members.insert(initialMember)
            dto.membership = initialMember
            for cycle in 1...10 {
                _ = MemberEventMiddleware().handle(event: removed, session: session)
                XCTAssertNil(dto.membership, "cycle \(cycle)")
                _ = MemberEventMiddleware().handle(event: accepted, session: session)
                XCTAssertEqual(dto.membership?.user.userId, "target", "cycle \(cycle)")
                XCTAssertEqual(dto.members.filter { $0.user.userId == "target" }.count, 1, "cycle \(cycle)")
            }
        }
    }

    func testAnotherMembersAcceptanceDoesNotRestoreCurrentMembership() throws {
        let db = try database()
        let event = try NotificationInviteAcceptedEventDTO(from: payload(type: "notification.invite_accepted", user: "other"))
        try db.writeAndWait { session in
            _ = MemberEventMiddleware().handle(event: event, session: session)
            XCTAssertNil(session.channel(cid: self.cid)?.membership)
        }
    }

    func testAcceptanceFromOtherProjectDoesNotAssignCurrentAccount() throws {
        let db = try database()
        let otherCid = ChannelId(type: .team, projectId: "other-project", id: "reinvite")
        let event = try NotificationInviteAcceptedEventDTO(from: payload(type: "notification.invite_accepted", user: "target", channel: otherCid))
        try db.writeAndWait { session in
            let dto = ChannelDTO.loadOrCreate(cid: otherCid, context: (try XCTUnwrap(session as? NSManagedObjectContext)), cache: nil)
            dto.createdAt = Date().bridgeDate
            dto.updatedAt = Date().bridgeDate
            _ = MemberEventMiddleware().handle(event: event, session: session)
            XCTAssertNil(dto.membership)
        }
    }

    func testAcceptanceWithoutAuthenticatedAccountDoesNotRestoreMembership() throws {
        let db = try database(authenticated: false)
        let event = try NotificationInviteAcceptedEventDTO(from: payload(type: "notification.invite_accepted", user: "target"))
        try db.writeAndWait { session in
            _ = MemberEventMiddleware().handle(event: event, session: session)
            XCTAssertNil(session.channel(cid: self.cid)?.membership)
        }
    }

    func testAddedAndUpdatedOwnMemberRestoreNilMembershipAndRoster() throws {
        for type in ["member.added", "member.updated", "member.joined"] {
            let db = try database()
            let event = try payload(type: type, user: "target").event()
            try db.writeAndWait { session in
                _ = MemberEventMiddleware().handle(event: event, session: session)
                let dto = try XCTUnwrap(session.channel(cid: self.cid))
                XCTAssertEqual(dto.membership?.user.userId, "target", type)
                XCTAssertEqual(dto.members.filter { $0.user.userId == "target" }.count, 1, type)
                XCTAssertEqual(ChannelDTO.fetchAllJoinedMlsEnabled(context: try XCTUnwrap(session as? NSManagedObjectContext)).count, 1, type)
            }
        }
    }

    func testOtherMemberAddedUpdatedOrJoinedCannotBecomeOwnMembership() throws {
        for type in ["member.added", "member.updated", "member.joined"] {
            let db = try database()
            let event = try payload(type: type, user: "other").event()
            try db.writeAndWait { session in
                _ = MemberEventMiddleware().handle(event: event, session: session)
                XCTAssertNil(session.channel(cid: self.cid)?.membership, type)
            }
        }
    }

    func testAddedMemberWithoutChannelMetadataStillConvertsToDomainSignal() throws {
        let db = try database()
        let response = try payload(type: "member.added", user: "target")
        let event = try response.event()
        try db.writeAndWait { session in
            let context = try XCTUnwrap(session as? NSManagedObjectContext)
            context.delete(try XCTUnwrap(session.channel(cid: self.cid)))
        }
        try db.writeAndWait { session in
            _ = EventDataProcessorMiddleware().handle(event: event, session: session)
            _ = MemberEventMiddleware().handle(event: event, session: session)
            let domain = try XCTUnwrap(EventDTOConverterMiddleware().handle(event: event, session: session) as? MemberAddedEvent)
            XCTAssertEqual(domain.memberId, "target")
            XCTAssertEqual(domain.cid, self.cid)
            XCTAssertTrue(domain.mlsEnable)
            XCTAssertNil(session.channel(cid: self.cid))
        }
    }

    func testMemberAddedFromOtherProjectDoesNotRestoreOwnMembership() throws {
        let db = try database()
        let otherCid = ChannelId(type: .team, projectId: "other-project", id: "reinvite")
        let event = try payload(type: "member.added", user: "target", channel: otherCid).event()
        try db.writeAndWait { session in
            let context = try XCTUnwrap(session as? NSManagedObjectContext)
            let dto = ChannelDTO.loadOrCreate(cid: otherCid, context: context, cache: nil)
            dto.createdAt = Date().bridgeDate
            dto.updatedAt = Date().bridgeDate
            _ = MemberEventMiddleware().handle(event: event, session: session)
            XCTAssertNil(dto.membership)
        }
    }
}
