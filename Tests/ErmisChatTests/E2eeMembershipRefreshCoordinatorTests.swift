import CoreData
import XCTest
@testable import ErmisChat

final class E2eeMembershipRefreshCoordinatorTests: XCTestCase {
    private let cid = ChannelId(type: .team, projectId: "project", id: "reinvite")
    private let identity = E2eeMembershipRefreshCoordinator.Session(accountId: "target", deviceId: "ios-fixture")

    private func database() throws -> DatabaseContainer {
        let db = DatabaseContainer(kind: .inMemory, shouldResetEphemeralValuesOnStart: false)
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !db.persistentStoreCoordinator.persistentStores.isEmpty
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 5), .completed)
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
        return db
    }

    private func payload(role: String = "member", user: String = "target", banned: Bool = false,
                         channel: ChannelId? = nil) throws -> ChannelPayload {
        let channel = channel ?? cid
        return try JSONDecoder.default.decode(ChannelPayload.self, from: Data("""
        {"channel":{"cid":"\(channel.rawValue)","type":"team","name":"Reinvite",
          "created_at":"2026-10-06T04:00:00Z","updated_at":"2026-10-06T04:30:00Z",
          "mls_enabled":true,"member_count":2},
         "membership":{"user_id":"\(user)","channel_role":"\(role)","banned":\(banned),
          "created_at":"2026-10-06T04:30:00Z",
          "user":{"id":"\(user)","name":"Target","role":"user",
            "created_at":"2026-10-06T04:00:00Z","updated_at":"2026-10-06T04:30:00Z"}},
         "messages":[],"read":[]}
        """.utf8))
    }

    func testServerJoinedMembershipPersistedAndPublishedBeforeBootstrapWithoutAcceptEvent() throws {
        let db = try database()
        let response = try payload()
        let done = expectation(description: "bootstrap ready to run")
        var publications = 0
        let worker = E2eeMembershipRefreshCoordinator(database: db, currentSession: { self.identity },
            fetch: { requested, completion in
                XCTAssertEqual(requested, self.cid)
                completion(.success(response))
            }, publish: { event, completion in
                XCTAssertEqual(event.cid, self.cid)
                XCTAssertEqual(event.channel.membership?.userId, "target")
                XCTAssertEqual(event.channel.membership?.memberRole, .member)
                publications += 1
                completion()
            }, finished: { _, result in
                if case .failure = result { XCTFail("Joined response failed") }
                XCTAssertEqual(publications, 1)
                done.fulfill()
            })
        worker.refresh(cid)
        wait(for: [done], timeout: 5)
        try db.writeAndWait { session in
            XCTAssertEqual(session.channel(cid: self.cid)?.membership?.user.userId, "target")
            XCTAssertEqual(ChannelDTO.fetchAllJoinedMlsEnabled(context: try XCTUnwrap(session as? NSManagedObjectContext)).count, 1)
        }
    }

    func testConcurrentSignalsCoalesceUntilDatabasePublicationCompletes() throws {
        let db = try database()
        let response = try payload()
        var reply: ((Result<ChannelPayload, Error>) -> Void)?
        var publishDone: (() -> Void)?
        var fetches = 0
        let published = expectation(description: "published")
        let finished = expectation(description: "finished")
        let worker = E2eeMembershipRefreshCoordinator(database: db, currentSession: { self.identity },
            fetch: { _, completion in fetches += 1; reply = completion },
            publish: { _, completion in publishDone = completion; published.fulfill() },
            finished: { _, _ in finished.fulfill() })
        for _ in 0..<20 { worker.refresh(cid) }
        XCTAssertEqual(fetches, 1)
        try XCTUnwrap(reply)(.success(response))
        wait(for: [published], timeout: 5)
        worker.refresh(cid)
        XCTAssertEqual(fetches, 1)
        try XCTUnwrap(publishDone)()
        wait(for: [finished], timeout: 5)
    }

    func testPendingRejectedBannedAndWrongAccountCannotWakeBootstrap() throws {
        for response in [try payload(role: "pending"), try payload(role: "rejected"),
                         try payload(banned: true), try payload(user: "other")] {
            let db = try database()
            var failures = 0
            let worker = E2eeMembershipRefreshCoordinator(database: db, currentSession: { self.identity },
                fetch: { _, completion in completion(.success(response)) },
                publish: { _, _ in XCTFail("Unauthorized publication") },
                finished: { _, result in
                    if case .success = result { XCTFail("Unauthorized bootstrap") }
                    failures += 1
                })
            worker.refresh(cid)
            XCTAssertEqual(failures, 1)
            try db.writeAndWait { XCTAssertNil($0.channel(cid: self.cid)) }
        }
    }

    func testWrongScopeResponseDoesNotWriteOrPublish() throws {
        let db = try database()
        let response = try payload(channel: .init(type: .team, projectId: "other", id: "reinvite"))
        var failed = false
        let worker = E2eeMembershipRefreshCoordinator(database: db, currentSession: { self.identity },
            fetch: { _, completion in completion(.success(response)) },
            publish: { _, _ in XCTFail("Wrong scope publication") },
            finished: { _, result in if case .failure = result { failed = true } })
        worker.refresh(cid)
        XCTAssertTrue(failed)
        try db.writeAndWait { XCTAssertNil($0.channel(cid: self.cid)) }
    }

    func testRemovalInvalidatesResponseAndLaterInviteCanRefreshAgain() throws {
        let db = try database()
        let response = try payload()
        var replies = [(Result<ChannelPayload, Error>) -> Void]()
        let finished = expectation(description: "only new invitation finishes")
        let worker = E2eeMembershipRefreshCoordinator(database: db, currentSession: { self.identity },
            fetch: { _, completion in replies.append(completion) },
            publish: { _, completion in completion() },
            finished: { _, result in
                if case .failure = result { XCTFail("New invitation failed") }
                finished.fulfill()
            })
        worker.refresh(cid)
        worker.invalidate(cid)
        worker.refresh(cid)
        XCTAssertEqual(replies.count, 2)
        replies[0](.success(response))
        try db.writeAndWait { XCTAssertNil($0.channel(cid: self.cid)) }
        replies[1](.success(response))
        wait(for: [finished], timeout: 5)
    }

    func testChangedDeviceSessionDiscardsInFlightResponse() throws {
        let db = try database()
        let response = try payload()
        var session: E2eeMembershipRefreshCoordinator.Session? = identity
        var reply: ((Result<ChannelPayload, Error>) -> Void)?
        let worker = E2eeMembershipRefreshCoordinator(database: db, currentSession: { session },
            fetch: { _, completion in reply = completion },
            publish: { _, _ in XCTFail("Superseded publication") },
            finished: { _, _ in XCTFail("Superseded bootstrap") })
        worker.refresh(cid)
        session = .init(accountId: "target", deviceId: "new-device")
        try XCTUnwrap(reply)(.success(response))
        try db.writeAndWait { XCTAssertNil($0.channel(cid: self.cid)) }
    }

    func testFetchFailurePreservesExistingMetadataAndDoesNotPublish() throws {
        let db = try database()
        let response = try payload()
        try db.writeAndWait { session in
            let dto = try session.saveChannel(payload: response)
            dto.mlsEpoch = 17
            dto.mlsGroupJoinedAt = Date(timeIntervalSince1970: 123).bridgeDate
        }
        var failed = false
        let worker = E2eeMembershipRefreshCoordinator(database: db, currentSession: { self.identity },
            fetch: { _, completion in completion(.failure(URLError(.notConnectedToInternet))) },
            publish: { _, _ in XCTFail("Offline publication") },
            finished: { _, result in if case .failure = result { failed = true } })
        worker.refresh(cid)
        XCTAssertTrue(failed)
        try db.writeAndWait { session in
            let dto = try XCTUnwrap(session.channel(cid: self.cid))
            XCTAssertEqual(dto.mlsEpoch, 17)
            XCTAssertEqual(dto.mlsGroupJoinedAt?.timeIntervalSince1970, 123)
            XCTAssertEqual(dto.membership?.user.userId, "target")
        }
    }

    func testMarkerContractRetainsOnlyFixedRefreshResult() {
        for result in ["started", "coalesced", "joined", "not_joined", "failed", "superseded"] {
            XCTAssertEqual(MlsFieldMarkerProjector.project("mls_membership_refresh result=\(result) token=secret"),
                           "mls_membership_refresh result=\(result)")
        }
        XCTAssertEqual(MlsFieldMarkerProjector.project("mls_membership_signal type=member_added result=refresh token=secret"),
                       "mls_membership_signal type=member_added result=refresh")
        XCTAssertNil(MlsFieldMarkerProjector.project("mls_membership_signal type=secret result=refresh"))
    }

    func testAcceptanceWhilePendingQueryInFlightRunsOneFreshQueryBeforePublishing() throws {
        let db = try database()
        let pending = try payload(role: "pending")
        let joined = try payload()
        var replies = [(Result<ChannelPayload, Error>) -> Void]()
        var published = 0
        let finished = expectation(description: "fresh accepted membership")
        let worker = E2eeMembershipRefreshCoordinator(database: db, currentSession: { self.identity },
            fetch: { _, completion in replies.append(completion) },
            publish: { _, completion in published += 1; completion() },
            finished: { _, result in
                if case .failure = result { XCTFail("Stale pending query must not publish failure") }
                finished.fulfill()
            })
        worker.refresh(cid)
        for _ in 0..<20 { worker.refresh(cid, recheckIfInFlight: true) }
        XCTAssertEqual(replies.count, 1)
        replies[0](.success(pending))
        XCTAssertEqual(replies.count, 2)
        XCTAssertEqual(published, 0)
        try db.writeAndWait { XCTAssertNil($0.channel(cid: self.cid)) }
        replies[1](.success(joined))
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(published, 1)
        XCTAssertEqual(replies.count, 2)
    }

    func testRemovalCancelsQueuedMembershipChangeRecheck() throws {
        let db = try database()
        let joined = try payload()
        var replies = [(Result<ChannelPayload, Error>) -> Void]()
        let worker = E2eeMembershipRefreshCoordinator(database: db, currentSession: { self.identity },
            fetch: { _, completion in replies.append(completion) },
            publish: { _, _ in XCTFail("Removed membership must not publish") },
            finished: { _, _ in XCTFail("Removed membership must not bootstrap") })
        worker.refresh(cid)
        worker.refresh(cid, recheckIfInFlight: true)
        worker.invalidate(cid)
        replies[0](.success(joined))
        XCTAssertEqual(replies.count, 1)
        try db.writeAndWait { XCTAssertNil($0.channel(cid: self.cid)) }
    }

    func testChangedAccountCancelsQueuedMembershipChangeRecheck() throws {
        let db = try database()
        let joined = try payload()
        var session: E2eeMembershipRefreshCoordinator.Session? = identity
        var replies = [(Result<ChannelPayload, Error>) -> Void]()
        let worker = E2eeMembershipRefreshCoordinator(database: db, currentSession: { session },
            fetch: { _, completion in replies.append(completion) },
            publish: { _, _ in XCTFail("Changed account must not publish") },
            finished: { _, _ in XCTFail("Changed account must not bootstrap") })
        worker.refresh(cid)
        worker.refresh(cid, recheckIfInFlight: true)
        session = .init(accountId: "other", deviceId: "other-device")
        replies[0](.success(joined))
        XCTAssertEqual(replies.count, 1)
    }

    private func memberEvent(type: String, target: String, database: DatabaseContainer) throws -> Event {
        let bytes = Data("""
        {"type":"\(type)","cid":"\(cid.rawValue)","mls_enabled":true,
         "created_at":"2026-10-06T08:24:30Z",
         "user":{"id":"owner","name":"Owner","role":"user",
           "created_at":"2026-10-06T04:00:00Z","updated_at":"2026-10-06T08:24:30Z"},
         "member":{"user_id":"\(target)","channel_role":"member",
           "created_at":"2026-10-06T08:24:30Z",
           "user":{"id":"\(target)","name":"Target","role":"user",
             "created_at":"2026-10-06T04:00:00Z","updated_at":"2026-10-06T08:24:30Z"}}}
        """.utf8)
        let dto = try JSONDecoder.default.decode(EventPayload.self, from: bytes).event()
        var domain: Event?
        try database.writeAndWait { session in
            _ = EventDataProcessorMiddleware().handle(event: dto, session: session)
            _ = MemberEventMiddleware().handle(event: dto, session: session)
            domain = EventDTOConverterMiddleware().handle(event: dto, session: session)
        }
        return try XCTUnwrap(domain)
    }

    func testOwnAddedUpdatedJoinedEventsWakeAuthoritativeQueryAndOtherMembersDoNot() throws {
        for type in ["member.added", "member.updated", "member.joined"] {
            let db = try database()
            let response = try payload()
            try db.writeAndWait { _ = try $0.saveChannel(payload: response) }
            var fetches = 0
            let worker = E2eeMembershipRefreshCoordinator(database: db, currentSession: { self.identity },
                fetch: { _, _ in fetches += 1 }, publish: { _, _ in }, finished: { _, _ in })
            XCTAssertFalse(worker.handleMemberEvent(try memberEvent(type: type, target: "other", database: db),
                                                   cachedMlsEnabled: { _ in true }))
            XCTAssertEqual(fetches, 0)
            XCTAssertTrue(worker.handleMemberEvent(try memberEvent(type: type, target: "target", database: db),
                                                  cachedMlsEnabled: { _ in true }))
            XCTAssertEqual(fetches, 1, type)
        }
    }

    func testMissingChannelAcceptAfterCompletedPendingQueryPublishesOnlyAuthoritativeMembership() throws {
        let db = try database()
        let pending = try payload(role: "pending")
        let joined = try payload()
        var replies = [(Result<ChannelPayload, Error>) -> Void]()
        var publications = 0
        var pendingFailures = 0
        let done = expectation(description: "accepted membership persisted before bootstrap")
        let worker = E2eeMembershipRefreshCoordinator(database: db, currentSession: { self.identity },
            fetch: { _, completion in replies.append(completion) }, publish: { event, completion in
                XCTAssertEqual(event.channel.membership?.memberRole, .member)
                publications += 1
                completion()
            }, finished: { _, result in
                switch result {
                case .failure(E2eeMembershipRefreshCoordinator.Failure.membershipNotJoined): pendingFailures += 1
                case .failure: XCTFail("Unexpected acceptance failure")
                case .success:
                    XCTAssertEqual(publications, 1)
                    done.fulfill()
                }
            })
        let added = try memberEvent(type: "member.added", target: "target", database: db)
        XCTAssertTrue(worker.handleMemberEvent(added, cachedMlsEnabled: { _ in false }))
        replies[0](.success(pending))
        XCTAssertEqual(pendingFailures, 1)
        XCTAssertEqual(publications, 0)
        try db.writeAndWait { XCTAssertNil($0.channel(cid: self.cid)) }
        let accepted = try memberEvent(type: "notification.invite_accepted", target: "target", database: db)
        XCTAssertTrue(accepted is E2eeInviteAcceptedSignalEvent)
        XCTAssertTrue(worker.handleMemberEvent(accepted, cachedMlsEnabled: { _ in false }))
        XCTAssertEqual(replies.count, 2)
        replies[1](.success(joined))
        wait(for: [done], timeout: 5)
        try db.writeAndWait { session in
            let dto = try XCTUnwrap(session.channel(cid: self.cid))
            XCTAssertEqual(dto.membership?.user.userId, "target")
            XCTAssertEqual(dto.membership?.channelRoleRaw, "member")
            XCTAssertTrue(dto.members.contains(try XCTUnwrap(dto.membership)))
        }
    }

    func testMissingChannelPeerAcceptanceCannotWakeOwnMembership() throws {
        let db = try database()
        let worker = E2eeMembershipRefreshCoordinator(database: db, currentSession: { self.identity },
            fetch: { _, _ in XCTFail("Peer acceptance must not query own membership") },
            publish: { _, _ in XCTFail("Peer acceptance must not publish") },
            finished: { _, _ in XCTFail("Peer acceptance must not bootstrap") })
        let accepted = try memberEvent(type: "notification.invite_accepted", target: "other", database: db)
        XCTAssertTrue(accepted is E2eeInviteAcceptedSignalEvent)
        XCTAssertFalse(worker.handleMemberEvent(accepted, cachedMlsEnabled: { _ in false }))
    }

    func testUnknownChannelUpdatedUsesSameSessionInviteHintWithoutGrantingPendingMembership() throws {
        let db = try database()
        var replies = [(Result<ChannelPayload, Error>) -> Void]()
        let done = expectation(description: "fresh joined query published")
        let worker = E2eeMembershipRefreshCoordinator(database: db, currentSession: { self.identity },
            fetch: { _, completion in replies.append(completion) },
            publish: { _, completion in completion() }, finished: { _, result in
                if case .failure = result { XCTFail("Only the fresh joined query should finish") }
                done.fulfill()
            })
        XCTAssertTrue(worker.handleMemberEvent(try memberEvent(type: "member.added", target: "target", database: db),
                                              cachedMlsEnabled: { _ in false }))
        XCTAssertTrue(worker.handleMemberEvent(try memberEvent(type: "member.updated", target: "target", database: db),
                                              cachedMlsEnabled: { _ in false }))
        replies[0](.success(try payload(role: "pending")))
        XCTAssertEqual(replies.count, 2)
        try db.writeAndWait { XCTAssertNil($0.channel(cid: self.cid)) }
        replies[1](.success(try payload()))
        wait(for: [done], timeout: 5)
    }

    func testInviteHintDoesNotSurviveRemovalOrChangedSession() throws {
        let db = try database()
        var session = identity
        let worker = E2eeMembershipRefreshCoordinator(database: db, currentSession: { session },
            fetch: { _, _ in }, publish: { _, _ in }, finished: { _, _ in })
        let added = try memberEvent(type: "member.added", target: "target", database: db)
        let updated = try memberEvent(type: "member.updated", target: "target", database: db)
        XCTAssertTrue(worker.handleMemberEvent(added, cachedMlsEnabled: { _ in false }))
        worker.invalidate(cid)
        XCTAssertFalse(worker.handleMemberEvent(updated, cachedMlsEnabled: { _ in false }))
        XCTAssertTrue(worker.handleMemberEvent(added, cachedMlsEnabled: { _ in false }))
        session = .init(accountId: "target", deviceId: "new-device")
        XCTAssertFalse(worker.handleMemberEvent(updated, cachedMlsEnabled: { _ in false }))
    }

    private final class ListWorker: ChannelListUpdater {
        var watched: (() -> Void)?
        override func startWatchingChannels(withIds ids: [ChannelId], userId: String?, completion: ((Error?) -> Void)? = nil) {
            watched?()
            completion?(nil)
        }
    }

    func testAuthoritativeRefreshRelinksRemovedChannelAndRewatchesOnSecondReinvite() throws {
        let db = try database()
        let response = try payload()
        var config = ErmisClientConfig(apiKeyString: "fixture-key",
            endpointEnviroment: .init(baseURL: try XCTUnwrap(URL(string: "https://example.invalid"))), isErmis: false)
        config.localStorageScope = .inMemory
        var environment = ErmisClient.Environment()
        environment.backgroundTaskSchedulerBuilder = { nil }
        environment.databaseContainerBuilder = { _, _, _, _, _, _ in db }
        let client = ErmisClient(config: config, clientId: "fixture-client", projectId: "project",
            rootProjectId: "project", chainId: 1, environment: environment,
            notificationTokenProvider: DefaultNotificationTokenProvider(),
            factory: ErmisClientFactory(config: config, environment: environment))
        client.authenticationRepository.setToken(token:
            Token(rawValue: "fixture", userId: "target", clientId: "fixture-client", projectId: "project",
                  chainId: 1, isErmis: false, expiration: nil), completeTokenWaiters: true)
        let query = ChannelListQuery(filter: .allChannels(memberId: "target", projectId: "project"))
        try db.writeAndWait { session in
            _ = try session.saveChannel(payload: response)
            _ = session.saveQuery(query: query)
        }
        let listWorker = ListWorker(database: db, apiClient: client.apiClient, e2eRepository: nil)
        var listEnvironment = ChannelListController.Environment()
        listEnvironment.channelQueryUpdaterBuilder = { _, _, _ in listWorker }
        let controller = ChannelListController(query: query, client: client, environment: listEnvironment)
        for type in ["member.added", "member.updated", "notification.invite_accepted"] {
            var removed: MemberRemovedEvent?
            try db.writeAndWait { session in
                let dto = try XCTUnwrap(session.channel(cid: self.cid))
                let member = try XCTUnwrap(dto.membership).user
                removed = MemberRemovedEvent(member: try member.asModel(), isSelfLeave: false,
                    cid: self.cid, parentCid: nil, topicCids: [], createdAt: Date())
                if let ownMember = dto.membership { dto.members.remove(ownMember) }
                dto.membership = nil
                session.channelListQuery(filterHash: query.filter.filterHash)?.channels.remove(dto)
                if type == "notification.invite_accepted" {
                    // The user-scoped removed-page transaction can remove all cached metadata.
                    (try XCTUnwrap(session as? NSManagedObjectContext)).delete(dto)
                }
            }
            controller.eventsController(controller.eventsController, didReceiveEvent: try XCTUnwrap(removed))
            let watched = expectation(description: "list linked and room watched")
            let finished = expectation(description: "bootstrap admitted")
            listWorker.watched = { watched.fulfill() }
            let refresh = E2eeMembershipRefreshCoordinator(database: db, currentSession: { self.identity },
                fetch: { _, completion in completion(.success(response)) },
                publish: { event, completion in
                    controller.eventsController(controller.eventsController, didReceiveEvent: event)
                    completion()
                }, finished: { _, result in
                    if case .failure = result { XCTFail("Membership refresh failed") }
                    finished.fulfill()
                })
            let signal = try memberEvent(type: type, target: "target", database: db)
            XCTAssertTrue(refresh.handleMemberEvent(signal, cachedMlsEnabled: { _ in true }))
            wait(for: [watched, finished], timeout: 5)
            try db.writeAndWait { session in
                let dto = try XCTUnwrap(session.channel(cid: self.cid))
                XCTAssertTrue(session.channelListQuery(filterHash: query.filter.filterHash)?.channels.contains(dto) == true)
                XCTAssertEqual(dto.membership?.user.userId, "target")
                let context = try XCTUnwrap(session as? NSManagedObjectContext)
                XCTAssertTrue(try context.fetch(ChannelDTO.channelListFetchRequest(query: query, clientConfig: client.config)).contains(dto))
            }
        }
    }
}
