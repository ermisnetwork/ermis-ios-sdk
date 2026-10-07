import Foundation

/// A protocol notification is a wake-up signal, not proof of application membership.
/// Query the existing channel before waking the durable MLS bootstrap coordinator.
final class E2eeMembershipRefreshCoordinator {
    struct Session: Equatable {
        let accountId: String
        let deviceId: String
    }

    enum Failure: Error {
        case superseded
        case membershipNotJoined
        case responseMismatch
    }

    private let database: DatabaseContainer
    private let currentSession: () -> Session?
    private let fetch: (ChannelId, @escaping (Result<ChannelPayload, Error>) -> Void) -> Void
    private let publish: (ChannelMembershipRefreshedEvent, @escaping () -> Void) -> Void
    private let finished: (ChannelId, Result<Void, Error>) -> Void
    private let lock = NSLock()
    private var requests: [ChannelId: UUID] = [:]
    private var rechecks: Set<ChannelId> = []
    private var advertisedMlsScopes: [ChannelId: Session] = [:]

    init(
        database: DatabaseContainer,
        currentSession: @escaping () -> Session?,
        fetch: @escaping (ChannelId, @escaping (Result<ChannelPayload, Error>) -> Void) -> Void,
        publish: @escaping (ChannelMembershipRefreshedEvent, @escaping () -> Void) -> Void,
        finished: @escaping (ChannelId, Result<Void, Error>) -> Void
    ) {
        self.database = database
        self.currentSession = currentSession
        self.fetch = fetch
        self.publish = publish
        self.finished = finished
    }

    func invalidate(_ cid: ChannelId) {
        lock.lock()
        requests.removeValue(forKey: cid)
        rechecks.remove(cid)
        advertisedMlsScopes.removeValue(forKey: cid)
        lock.unlock()
    }

    /// A membership change supersedes a query that may still describe the pending invite.
    /// Welcome duplicates alone must not repeatedly query the same membership.
    func refresh(_ cid: ChannelId, recheckIfInFlight: Bool = false) {
        guard let session = currentSession() else { return }
        let request = UUID()
        lock.lock()
        guard requests[cid] == nil else {
            if recheckIfInFlight { rechecks.insert(cid) }
            lock.unlock()
            log.debug("mls_membership_refresh result=coalesced", subsystems: .mls)
            return
        }
        requests[cid] = request
        lock.unlock()
        log.debug("mls_membership_refresh result=started", subsystems: .mls)
        fetch(cid) { [weak self] response in
            guard let self else { return }
            guard self.isCurrent(request, cid: cid, session: session) else {
                self.complete(request, cid: cid, session: session, result: .failure(Failure.superseded))
                return
            }
            switch response {
            case .failure(let error):
                self.complete(request, cid: cid, session: session, result: .failure(error))
            case .success(let payload):
                guard payload.channel.cid == cid,
                      payload.channel.mlsEnabled,
                      let membership = payload.membership,
                      membership.userId == session.accountId,
                      membership.user?.id == session.accountId else {
                    self.complete(request, cid: cid, session: session, result: .failure(Failure.responseMismatch))
                    return
                }
                let knownRoles = ["owner", "admin", "moder", "member", "pending", "rejected", "skipped"]
                let role = membership.role?.rawValue ?? "unknown"
                let safeRole = knownRoles.contains(role) ? role : "unknown"
                let banned = membership.isBanned.map { $0 ? "true" : "false" } ?? "unknown"
                let blocked = membership.isBlocked.map { $0 ? "true" : "false" } ?? "unknown"
                log.info("mls_membership_validation role=\(safeRole) banned=\(banned) blocked=\(blocked)", subsystems: .mls)
                guard membership.role.map({ [.owner, .admin, .moderator, .member].contains($0) }) == true,
                      membership.isBanned != true,
                      membership.isBlocked != true else {
                    self.complete(request, cid: cid, session: session, result: .failure(Failure.membershipNotJoined))
                    return
                }
                var channel: Channel?
                self.database.write({ db in
                    guard self.isCurrent(request, cid: cid, session: session),
                          db.currentUser?.user(of: cid.projectId)?.userId == session.accountId else {
                        throw Failure.superseded
                    }
                    let dto = try db.saveChannel(payload: payload)
                    // A zero-member query still returns our own membership. Restore its
                    // roster relation too: allChannels filters on members.user.id.
                    if let ownMember = dto.membership { dto.members.insert(ownMember) }
                    channel = try dto.asModel()
                }, completion: { error in
                    if let error {
                        self.complete(request, cid: cid, session: session, result: .failure(error))
                        return
                    }
                    guard let channel,
                          self.isCurrent(request, cid: cid, session: session) else {
                        self.complete(request, cid: cid, session: session, result: .failure(Failure.superseded))
                        return
                    }
                    self.publish(.init(channel: channel)) {
                        guard self.isCurrent(request, cid: cid, session: session) else {
                            self.complete(request, cid: cid, session: session, result: .failure(Failure.superseded))
                            return
                        }
                        self.complete(request, cid: cid, session: session, result: .success(()))
                    }
                })
            }
        }
    }

    private func isCurrent(_ request: UUID, cid: ChannelId, session: Session) -> Bool {
        lock.lock()
        let matches = requests[cid] == request && !rechecks.contains(cid)
        lock.unlock()
        return matches && currentSession() == session
    }

    private func complete(_ request: UUID, cid: ChannelId, session: Session, result: Result<Void, Error>) {
        lock.lock()
        let ownsRequest = requests[cid] == request
        let recheck = ownsRequest && rechecks.contains(cid)
        if ownsRequest {
            requests.removeValue(forKey: cid)
            rechecks.remove(cid)
        }
        lock.unlock()
        let marker: String
        switch result {
        case .success: marker = "joined"
        case .failure(Failure.superseded): marker = "superseded"
        case .failure(Failure.membershipNotJoined): marker = "not_joined"
        case .failure: marker = "failed"
        }
        log.debug("mls_membership_refresh result=\(marker)", subsystems: .mls)
        if recheck, currentSession() == session {
            refresh(cid)
            return
        }
        // An invalidated response must not wake bootstrap or overwrite newer readiness.
        guard ownsRequest, marker != "superseded" else { return }
        finished(cid, result)
    }

    /// These events wake an authoritative query; their role alone does not start MLS.
    @discardableResult
    func handleMemberEvent(_ event: Event, cachedMlsEnabled: (ChannelId) -> Bool) -> Bool {
        let cid: ChannelId
        let target: String
        let type: String
        let advertisedMls: Bool
        switch event {
        case let event as MemberAddedEvent:
            cid = event.cid; target = event.memberId; type = "member_added"
            advertisedMls = event.mlsEnable
        case let event as MemberUpdatedEvent:
            cid = event.cid; target = event.member.userId; type = "member_updated"
            advertisedMls = false
        case let event as MemberJoinnedEvent:
            cid = event.cid; target = event.member.userId; type = "member_joined"
            advertisedMls = false
        case let event as E2eeInviteAcceptedSignalEvent:
            cid = event.cid; target = event.targetUserId; type = "invite_accepted"
            advertisedMls = true
        default: return false
        }
        guard let session = currentSession(), session.accountId == target else { return false }
        lock.lock()
        if advertisedMls { advertisedMlsScopes[cid] = session }
        let announcedMls = advertisedMlsScopes[cid] == session
        lock.unlock()
        // A pending first query has not stored channel metadata yet. Its later
        // member.updated signal still needs the MLS hint from this session's invite.
        guard advertisedMls || announcedMls || cachedMlsEnabled(cid) else { return false }
        log.info("mls_membership_signal type=\(type) result=refresh", subsystems: .mls)
        refresh(cid, recheckIfInFlight: true)
        return true
    }
}

/// Internal publication of an authoritative query, distinct from an invitation event.
struct ChannelMembershipRefreshedEvent: ChannelSpecificEvent {
    let channel: Channel
    var cid: ChannelId { channel.cid }
    var parentCid: ChannelId? { channel.parentCid }
    var topicCids: [ChannelId] { [] }
}
