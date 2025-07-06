//
// Copyright 2025 Ermis Inc.
//

import CoreData
import Foundation

extension ErmisClient {
    /// Creates a new `ChannelMemberListController` with the provided query.
    /// - Parameter query: The query specify the filter and sorting options for members the controller should fetch.
    /// - Returns: A new instance of `ChannelMemberListController`.
    public func memberListController(
        query: ChannelMemberListQuery
    ) -> ChannelMemberListController {
        .init(query: query, client: self)
    }
}

/// `ChannelMemberListController` is a controller class which allows observing
/// a list of chat users based on the provided query.
public class ChannelMemberListController: DataController, DelegateCallable, DataStoreProvider {
    /// The query specifying sorting and filtering for the list of channel members.
    @Atomic public private(set) var query: ChannelMemberListQuery

    /// The `ErmisClient` instance this controller belongs to.
    public let client: ErmisClient

    /// The channel members matching the query.
    /// To observe the member list changes, set your class as a delegate of this controller or use the provided
    /// `Combine` publishers.
    public var members: LazyCachedMapCollection<ChannelMember> {
        startObservingIfNeeded()
        return memberListObserver.items
    }

    /// The worker used to fetch the remote data and communicate with servers.
    private lazy var memberListUpdater = createMemberListUpdater()

    /// The observer used to observe the changes in the database.
    private lazy var memberListObserver = createMemberListObserver()

    /// The type-erased delegate.
    var multicastDelegate: MulticastDelegate<ChannelMemberListControllerDelegate> = .init() {
        didSet {
            stateMulticastDelegate.set(mainDelegate: multicastDelegate.mainDelegate)
            stateMulticastDelegate.set(additionalDelegates: multicastDelegate.additionalDelegates)

            startObservingIfNeeded()
        }
    }

    var _basePublishers: Any?
    /// An internal backing object for all publicly available Combine publishers. We use it to simplify the way we expose
    /// publishers. Instead of creating custom `Publisher` types, we use `CurrentValueSubject` and `PassthroughSubject` internally,
    /// and expose the published values by mapping them to a read-only `AnyPublisher` type.
    var basePublishers: BasePublishers {
        if let value = _basePublishers as? BasePublishers {
            return value
        }
        _basePublishers = BasePublishers(controller: self)
        return _basePublishers as? BasePublishers ?? .init(controller: self)
    }

    private let environment: Environment

    /// Creates a new `ChannelMemberListController`
    /// - Parameters:
    ///   - query: The query used for filtering and sorting the channel members.
    ///   - client: The `Client` this controller belongs to.
    ///   - environment: Environment for this controller.
    init(query: ChannelMemberListQuery, client: ErmisClient, environment: Environment = .init()) {
        self.client = client
        self.query = query
        self.environment = environment
    }

    override public func synchronize(_ completion: ((_ error: Error?) -> Void)? = nil) {
        startObservingIfNeeded()

        if case let .localDataFetchFailed(error) = state {
            callback { completion?(error) }
            return
        }

        memberListUpdater.load(query) { error in
            self.state = error == nil ? .remoteDataFetched : .remoteDataFetchFailed(ClientError(with: error))
            self.callback { completion?(error) }
        }
    }

    private func createMemberListUpdater() -> ChannelMemberListUpdater {
        environment.memberListUpdaterBuilder(
            client.databaseContainer,
            client.apiClient
        )
    }

    private func createMemberListObserver() -> ListDatabaseObserverWrapper<ChannelMember, MemberDTO> {
        let observer = environment.memberListObserverBuilder(
            false,
            client.databaseContainer,
            MemberDTO.members(matching: query),
            { try $0.asModel() },
            NSFetchedResultsController<MemberDTO>.self
        )

        observer.onDidChange = { [weak self] changes in
            self?.delegateCallback { [weak self] in
                guard let self = self else {
                    log.warning("Callback called while self is nil")
                    return
                }

                $0.memberListController(self, didChangeMembers: changes)
            }
        }

        return observer
    }

    private func startObservingIfNeeded() {
        guard state == .initialized else { return }

        do {
            try memberListObserver.startObserving()
            state = .localDataFetched
        } catch {
            log.error("Observing members matching <\(query)> failed: \(error). Accessing `members` will always return `[]`.")
            state = .localDataFetchFailed(ClientError(with: error))
        }
    }
}

// MARK: - Actions

public extension ChannelMemberListController {
    /// Loads next members from backend.
    /// - Parameters:
    ///   - limit: The page size.
    ///   - completion: The completion. Will be called on a **callbackQueue** when the network request is finished.
    ///                 If request fails, the completion will be called with an error.
    func loadNextMembers(
        limit: Int = 25,
        completion: ((Error?) -> Void)? = nil
    ) {
        var updatedQuery = query
        updatedQuery.pagination = Pagination(pageSize: limit, offset: members.count)
        memberListUpdater.load(updatedQuery) { error in
            self.query = updatedQuery
            self.callback {
                completion?(error)
            }
        }
    }
}

extension ChannelMemberListController {
    struct Environment {
        var memberListUpdaterBuilder: (
            _ database: DatabaseContainer,
            _ apiClient: APIClient
        ) -> ChannelMemberListUpdater = ChannelMemberListUpdater.init

        var memberListObserverBuilder: (
            _ isBackgroundMappingEnabled: Bool,
            _ database: DatabaseContainer,
            _ fetchRequest: NSFetchRequest<MemberDTO>,
            _ itemCreator: @escaping (MemberDTO) throws -> ChannelMember,
            _ controllerType: NSFetchedResultsController<MemberDTO>.Type
        ) -> ListDatabaseObserverWrapper<ChannelMember, MemberDTO> = {
            .init(isBackground: $0, database: $1, fetchRequest: $2, itemCreator: $3, fetchedResultsControllerType: $4)
        }
    }
}

extension ChannelMemberListController {
    /// Set the delegate of `ChannelMemberListController` to observe the changes in the system.
    public var delegate: ChannelMemberListControllerDelegate? {
        get { multicastDelegate.mainDelegate }
        set { multicastDelegate.set(mainDelegate: newValue) }
    }
}

/// `ChannelMemberListController` uses this protocol to communicate changes to its delegate.
public protocol ChannelMemberListControllerDelegate: DataControllerStateDelegate {
    /// Controller observed a change in the channel member list.
    func memberListController(
        _ controller: ChannelMemberListController,
        didChangeMembers changes: [ListChange<ChannelMember>]
    )
}

public extension ChatUserListControllerDelegate {
    func memberListController(
        _ controller: ChannelMemberListController,
        didChangeMembers changes: [ListChange<ChannelMember>]
    ) {}
}

public extension ChannelMemberListControllerDelegate {
    func memberListController(
        _ controller: ChannelMemberListController,
        didChangeMembers changes: [ListChange<ChannelMember>]
    ) {}
}
