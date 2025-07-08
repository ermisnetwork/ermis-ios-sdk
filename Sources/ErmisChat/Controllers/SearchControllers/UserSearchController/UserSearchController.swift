//
// Copyright 2025 Ermis Inc.
//

import CoreData
import Foundation

extension ErmisClient {
    /// Creates a new `UserSearchController` with the provided user query.
    ///
    /// - Parameter query: The query specify the filter and sorting of the users the controller should fetch.
    ///
    /// - Returns: A new instance of `UserSearchController`.
    ///
    public func userSearchController() -> UserSearchController {
        .init(client: self)
    }
}

/// `UserSearchController` is a controller class which allows observing a list of chat users based on the provided query.
public class UserSearchController: DataController, DelegateCallable, DataStoreProvider {
    /// The `ErmisClient` instance this controller belongs to.
    public let client: ErmisClient

    /// Copy of last search query made, used for getting next page.
    public private(set) var query: UserListQuery?
    /// If true, the friend contact list will be load before fetch users.
    public var shouldLoadFriendContacts = false
    /// The closure to filter user
    public var userFilterClosure: (ChatUser) -> Bool = { _ in true }

    var projectId: String {
        return client.projectId
    }


    /// The users matching the last query of this controller.
    private var _users: [ChatUser] = []
    /// List of friend contact id, only have value if `shouldLoadFriendContacts` = true
    private var friendContactIds: Set<String> = []
    /// Dictionary with `key` is `projectId`, value is list of friend contact id, only have value if `shouldLoadFriendContacts` = true
    private var projectFriendUserIdList: [String: [FriendContactPayload]] = [:] {
        didSet {
            var currentUserId = client.currentUserId
            projectFriendUserIdList.forEach { key, friendContactList in
                var blockUserIds: Set<String> = []
                for friendContact in friendContactList where friendContact.relationStatus == .blocked {
                    blockUserIds.insert(friendContact.userId == currentUserId ? friendContact.otherId : friendContact.userId)
                }
                projectBlockUserIdList[key] = blockUserIds
            }
        }
    }
    /// Dictionary with `key` is `projectId`, value is list of blocked contact id, only have value if `shouldLoadFriendContacts` = true
    private var projectBlockUserIdList: [String: Set<String>] = [:]
    private var hasLoadFriendContacts: Bool = false

    public var users: [ChatUser] {
        setLocalDataFetchedStateIfNeeded()
        return _users
    }

    public var friendContacts: [ChatUser] = []

    lazy var userQueryUpdater = self.environment
        .userQueryUpdaterBuilder(
            client.databaseContainer,
            client.apiClient
        )

    /// A type-erased delegate.
    var multicastDelegate: MulticastDelegate<UserSearchControllerDelegate> = .init() {
        didSet {
            stateMulticastDelegate.set(mainDelegate: multicastDelegate.mainDelegate)
            stateMulticastDelegate.set(additionalDelegates: multicastDelegate.additionalDelegates)

            setLocalDataFetchedStateIfNeeded()
        }
    }

    private let environment: Environment

    init(client: ErmisClient, environment: Environment = .init()) {
        self.client = client
        self.environment = environment
    }

    /// Searches users for the given term.
    ///
    /// When this function is called, `users` property of this controller will refresh with new users matching the term.
    /// The delegate function `didChangeUsers` will also be called.
    ///
    /// - Note: Currently, no local data will be searched, only remote data will be queried.
    ///
    /// - Parameters:
    ///   - term: Search term. If empty string or `nil`, all users are fetched.
    ///   - completion: Called when the controller has finished fetching remote data.
    ///   If the data fetching fails, the error variable contains more details about the problem.
    public func search(term: String?, completion: ((_ error: Error?) -> Void)? = nil) {
        getContactFriendsIfNeeded { [weak self] error in
            if let error = error {
                completion?(error)
            } else {
                self?.fetch(.search(term: term, projectId: self?.projectId ?? ""), completion: completion)
            }
        }
    }

    /// Searches users for the given query.
    ///
    /// When this function is called, `users` property of this controller will refresh with new users matching the term.
    /// The delegate function `didChangeUsers` will also be called.
    ///
    /// - Note: Currently, no local data will be searched, only remote data will be queried.
    ///
    /// - Parameters:
    ///   - query: Search query.
    ///   - completion: Called when the controller has finished fetching remote data.
    ///   If the data fetching fails, the error variable contains more details about the problem.
    public func search(query: UserListQuery, completion: ((_ error: Error?) -> Void)? = nil) {
        getContactFriendsIfNeeded { [weak self] error in
            if let error = error {
                completion?(error)
            } else {
                self?.fetch(query, completion: completion)
            }
        }
    }

    /// Loads all friend contact ids
    /// - Parameters: completion: Called when the controller has finished fetching remote data.

    public func getFriendUserIds(completion: @escaping (Result<FriendContactListPayload, Error>) -> Void) {
        userQueryUpdater.getFriendContacts(projectId: projectId, completion: completion)
    }

    /// Loads next users from backend.
    ///
    /// - Parameters:
    ///   - limit: Limit for page size.
    ///   - completion: The completion. Will be called on a **callbackQueue** when the network request is finished.
    ///                 If request fails, the completion will be called with an error.
    ///
    public func loadMoreUsers(
        limit: Int = 25,
        completion: ((Error?) -> Void)? = nil
    ) {
        guard let lastQuery = query else {
            completion?(ClientError("You should make a search before calling for next page."))
            return
        }

        var updatedQuery = lastQuery
        guard lastQuery.pagination?.isLastPage == false else {
            completion?(nil)
            return
        }
        updatedQuery.pagination = UserPagination(page: (lastQuery.pagination?.page ?? 1) + 1,
                                                 pageSize: lastQuery.pagination?.pageSize ?? limit,
                                                 totalPages: lastQuery.pagination?.totalPages,
                                                 totalResults: lastQuery.pagination?.totalResults)
        fetch(updatedQuery, completion: completion)
    }

    /// Clears the current search results.
    public func clearResults() {
        _users = []
    }

    /// Check user is current user or not
    ///
    /// - Parameters:
    ///   - user: The user to check.
    ///
    /// - Returns: A boolean value, true if user is current user.
    public func isCurrentUser(_ user: ChatUser) -> Bool {
        return user.userId == client.currentUserId
    }

    /// Check user is friend or not
    ///
    /// - Parameters:
    ///   - user: The user to check.
    ///
    /// - Returns: A boolean value, true if user is friend.

    public func isFriendUser(_ user: ChatUser) -> Bool {
        return friendContactIds.contains(user.id)
    }

    /// Check user is blocked or not
    ///
    /// - Parameters:
    ///   - user: The user to check.
    ///
    /// - Returns: A boolean value, true if user is blocked.
    public func isBlockUser(_ user: ChatUser) -> Bool {
        return projectBlockUserIdList[projectId ?? ""]?.contains(user.userId) == true
    }
}

private extension UserSearchController {
    /// Fetches the given query from the API, saves the loaded page to the database, updates the list of users and notifies the delegate.
    ///
    /// - Parameters:
    ///   - query: The query to fetch.
    ///   - completion: The completion that is triggered when the query is processed.
    func fetch(_ query: UserListQuery, completion: ((Error?) -> Void)? = nil) {
        // TODO: Remove with the next major
        //
        // This is needed to make the delegate fire about state changes at the same time with the same
        // values as it was when query was persisted.
        setLocalDataFetchedStateIfNeeded()
        userQueryUpdater.fetch(userListQuery: query) { [weak self] result in
            guard let self else {
                completion?(nil)
                return
            }
            switch result {
            case let .success(page):
                self.save(page: page) { [weak self] loadedUsers in
                    guard let self else {
                        completion?(nil)
                        return
                    }
                    var loadedUsers = loadedUsers.filter { self.userFilterClosure($0) }
                    let listChanges = self.prepareListChanges(
                        loadedPage: loadedUsers,
                        updatePolicy: query.pagination?.page == 1 ? .replace : .merge
                    )

                    self.query = query
                    self.query?.pagination?.page = page.page
                    self.query?.pagination?.totalPages = page.pageCount
                    self.query?.pagination?.totalResults = page.resultCount

                    let users = self.userList(after: listChanges)
                    self._users = users
                    self.state = .remoteDataFetched

                    self.callback {
                        self.multicastDelegate.invoke {
                            $0.controller(self, didChangeUsers: listChanges)
                        }
                        completion?(nil)
                    }
                }
            case let .failure(error):
                self.state = .remoteDataFetchFailed(ClientError(with: error))
                self.callback { completion?(error) }
            }
        }
    }

    /// Saves the given payload to the database and returns database independent models.
    ///
    /// - Parameters:
    ///   - page: The page of users fetched from the API.
    ///   - completion: The completion that will be called with user models when database write is completed.
    func save(page: UserListPayload, completion: @escaping ([ChatUser]) -> Void) {
        var loadedUsers: [ChatUser] = []

        client.databaseContainer.write({ [weak self] session in
            loadedUsers = page
                .users
                .compactMap { try? session.saveUser(payload: $0, projectId: self?.projectId ?? "").asModel() }

        }, completion: { _ in
            DispatchQueue.main.async {
                completion(loadedUsers)
            }
        })
    }

    /// Creates the list of changes based on current list, the new page, and the policy.
    ///
    /// - Parameters:
    ///   - loadedPage: The next page of users.
    ///   - updatePolicy: The update policy.
    /// - Returns: The list of changes that can be applied to the current list of users.
    func prepareListChanges(loadedPage: [ChatUser], updatePolicy: UpdatePolicy) -> [ListChange<ChatUser>] {
        switch updatePolicy {
        case .replace:
            let deletions = users.enumerated().reversed().map { (index, user) in
                ListChange.remove(user, index: .init(item: index, section: 0))
            }

            let insertions = loadedPage.enumerated().map { (index, user) in
                ListChange.insert(user, index: .init(item: index, section: 0))
            }

            return deletions + insertions
        case .merge:
            let insertions = loadedPage.enumerated().map { (index, user) in
                ListChange.insert(user, index: .init(item: index + users.count, section: 0))
            }

            return insertions
        }
    }

    /// Applies the given changes to the current list of users and returns the updated list.
    ///
    /// - Parameter changes: The changes to apply.
    /// - Returns: The user list after the given changes applied.
    ///
    func userList(after changes: [ListChange<ChatUser>]) -> [ChatUser] {
        var users = _users

        for change in changes {
            switch change {
            case let .insert(user, indexPath):
                users.insert(user, at: indexPath.item)
            case let .remove(_, indexPath):
                users.remove(at: indexPath.item)
            default:
                log.assertionFailure("Unsupported list change observed: \(change)")
            }
        }

        return users
    }

    /// Sets state to `localDataFetched` if current state is `initialized`.
    func setLocalDataFetchedStateIfNeeded() {
        guard state == .initialized else { return }

        state = .localDataFetched
    }

    public func getContactFriendsIfNeeded(completion: ((_ error: Error?) -> Void)? = nil) {
        if shouldLoadFriendContacts, !hasLoadFriendContacts {
            getFriendUserIds { [weak self] result in
                switch result {
                case .success(let payload):
                    self?.friendContactIds = Set(payload.projectUserIds[self?.projectId ?? ""]?
                        .compactMap {
                            $0.otherId != self?.client.currentUserId ? $0.otherId : nil
                        } ?? [])
                    self?.friendContacts = self?.queryUsers(with: Array(self?.friendContactIds ?? [])) ?? []
                    self?.projectFriendUserIdList = payload.projectUserIds
                    self?.hasLoadFriendContacts = true
                    completion?(nil)
                case .failure(let failure):
                    completion?(failure)
                }
            }
        } else {
            completion?(nil)
        }
    }

    public func queryUsers(with ids: [String]) -> [ChatUser] {
        let request = UserDTO.userListFetchRequest(userIds: ids, projectId: client.projectId)
        let users = try? client.databaseContainer.viewContext.fetch(request).compactMap({
            try? $0.asModel()
        })
        return users ?? []
    }
}

extension UserSearchController {
    struct Environment {
        var userQueryUpdaterBuilder: (
            _ database: DatabaseContainer,
            _ apiClient: APIClient
        ) -> UserListUpdater = UserListUpdater.init
    }
}

extension UserSearchController {
    /// Set the delegate of `UserListController` to observe the changes in the system.
    public weak var delegate: UserSearchControllerDelegate? {
        get { multicastDelegate.mainDelegate }
        set { multicastDelegate.set(mainDelegate: newValue) }
    }
}

/// `UserSearchController` uses this protocol to communicate changes to its delegate.
public protocol UserSearchControllerDelegate: DataControllerStateDelegate {
    /// The controller changed the list of observed users.
    ///
    /// - Parameters:
    ///   - controller: The controller emitting the change callback.
    ///   - changes: The change to the list of users.
    ///
    func controller(
        _ controller: UserSearchController,
        didChangeUsers changes: [ListChange<ChatUser>]
    )
}

public extension UserSearchControllerDelegate {
    func controller(
        _ controller: UserSearchController,
        didChangeUsers changes: [ListChange<ChatUser>]
    ) {}
}
