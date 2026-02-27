//
// Copyright 2025 Ermis Inc.
//

import CoreData
import Foundation
import ErmisShared

public extension ErmisClient {
    /// Creates a new `CurrentUserController` instance.
    ///
    /// - Returns: A new instance of `CurrentUserController`.
    ///
    func currentUserController() -> CurrentUserController {
        .init(client: self)
    }
}

/// `CurrentUserController` is a controller class which allows observing and mutating the currently logged-in
/// user of `ErmisClient`.
public class CurrentUserController: DataController, DelegateCallable, DataStoreProvider {
    /// The `ErmisClient` instance this controller belongs to.
    public let client: ErmisClient

    private let environment: Environment

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

    /// Used for observing the current user changes in a database.
    private lazy var currentUserObserver = createUserObserver()
        .onChange { [weak self] change in
            self?.delegateCallback { [weak self] in
                guard let self = self else {
                    log.warning("Callback called while self is nil")
                    return
                }
                $0.currentUserController(self, didChangeCurrentUser: change)
            }
        }
        .onFieldChange(\.unreadCount) { [weak self] change in
            self?.delegateCallback { [weak self] in
                guard let self = self else {
                    log.warning("Callback called while self is nil")
                    return
                }
                $0.currentUserController(self, didChangeCurrentUserUnreadCount: change.unreadCount)
            }
        }

    /// A type-erased delegate.
    var multicastDelegate: MulticastDelegate<CurrentUserControllerDelegate> = .init()

    /// The currently logged-in user. `nil` if the connection hasn't been fully established yet, or the connection
    /// wasn't successful.
    /// Having a non-nil currentUser does not mean the user is authenticated. Make sure to call `connect()` before performing any API call.
    public var currentUser: CurrentChatUser? {
        startObservingIfNeeded()
        return currentUserObserver.item
    }

    /// The unread messages and channels count for the current user.
    ///
    /// Returns `noUnread` if `currentUser` doesn't exist yet.
    ///
    public var unreadCount: UnreadCount {
        currentUser?.unreadCount ?? .noUnread
    }

    /// The worker used to update the current user.
    private lazy var currentUserUpdater = environment.currentUserUpdaterBuilder(
        client.databaseContainer,
        client.apiClient
    )

    /// Creates a new `CurrentUserControllerGeneric`.
    ///
    /// - Parameters:
    ///   - client: The `Client` instance this controller belongs to.
    ///   - environment: The source of internal dependencies
    ///
    init(client: ErmisClient, environment: Environment = .init()) {
        self.client = client
        self.environment = environment
    }

    /// Synchronize local data with remote. Waits for the client to connect but doesn’t initiate the connection itself.
    /// This is to make sure the fetched local data is up-to-date, since the current user data is updated through WebSocket events.
    ///
    /// - Parameter completion: Called when the controller has finished fetching the local data
    ///   and the client connection is established.
    override public func synchronize(_ completion: ((_ error: Error?) -> Void)? = nil) {
        startObservingIfNeeded()

        if case let .localDataFetchFailed(error) = state {
            callback { completion?(error) }
            return
        }

        // Unlike the other DataControllers, this one does not make a remote call when synchronising.
        // But we can assume that if we wait for the connection of the WebSocket, it means the local data
        // is in sync with the remote server, so we can set the state to remoteDataFetched.
        client.provideConnectionId { [weak self] result in
            var error: ClientError?
            if case .failure = result {
                error = ClientError.ConnectionNotSuccessful()
            }

            self?.state = error == nil ? .remoteDataFetched : .remoteDataFetchFailed(error!)
            self?.callback { completion?(error) }
        }
    }

    private func startObservingIfNeeded() {
        guard state == .initialized else { return }

        do {
            try currentUserObserver.startObserving()
            state = .localDataFetched
        } catch {
            log.error("""
            Observing current user failed: \(error).\n
            Accessing `currentUser` will always return `nil`, `unreadCount` with `.noUnread`
            """)
            state = .localDataFetchFailed(ClientError(with: error))
        }

        guard let currentUserId = client.currentUserId else {
            return
        }
        currentUserUpdater.getInfo(currentUserId, projectId: client.projectId)
    }
}

public extension CurrentUserController {
    /// Fetches the token from `tokenProvider` and prepares the current `ErmisClient` variables
    /// for the new user.
    ///
    /// If the a token obtained from `tokenProvider` is for another user the
    /// database will be flushed.
    ///
    /// - Parameter completion: The completion to be called when the operation is completed.
    func reloadUserIfNeeded(completion: ((Error?) -> Void)? = nil) {
        client.authenticationRepository.refreshToken { error in
            self.callback {
                completion?(error)
            }
        }
    }

    /// Updates the current user data.
    ///
    /// By default all data is `nil`, and it won't be updated unless a value is provided.
    ///
    /// - Parameters:
    ///   - name: Optionally provide a new name to be updated.
    ///   - imageData: Optionally provide a new image data to be updated.
    ///   - completion: Called when user is successfuly updated, or with error.
    func updateUserData(
        name: String? = nil,
        imageData: Data? = nil,
        completion: ((Error?) -> Void)? = nil
    ) {
        guard let currentUserId = client.currentUserId else {
            completion?(ClientError.CurrentUserDoesNotExist())
            return
        }

        currentUserUpdater.updateUserData(
            currentUserId: currentUserId,
            projectId: client.projectId,
            name: name,
            imageData: imageData
        ) { error in
            self.callback {
                completion?(error)
            }
        }
    }

    /// Fetches the most updated devices and syncs with the local database.
    /// - Parameter completion: Called when the devices are synced successfully, or with error.
    func synchronizeDevices(completion: ((Error?) -> Void)? = nil) {
        guard let currentUserId = client.currentUserId else {
            completion?(ClientError.CurrentUserDoesNotExist())
            return
        }

        currentUserUpdater.fetchDevices(currentUserId: currentUserId, projectId: client.projectId) { error in
            self.callback { completion?(error) }
        }
    }

    func setFcmToken(fcmToken: DeviceId?, completion: ((Error?) -> Void)? = nil) {
        client.notificationTokenProvider.fcmToken = fcmToken
        if let fcmToken {
            addDevice(fcmToken: fcmToken, deviceToken: client.notificationTokenProvider.deviceToken, completion: completion)
        } else if let fcmToken {
            removeDevice(fcmToken: fcmToken)
        }
    }

    func setDeviceToken(deviceToken: DeviceId?, completion: ((Error?) -> Void)? = nil) {
        client.notificationTokenProvider.deviceToken = deviceToken
        if let deviceToken, let fcmToken = client.notificationTokenProvider.fcmToken {
            addDevice(fcmToken: fcmToken, deviceToken: deviceToken, completion: completion)
        }
    }

    /// Registers the current user's device for push notifications.
    /// - Parameters:
    ///   - fcmToken: The fcmToken.
    ///   - deviceToken: The pushkit device token.
    ///   - completion: Callback when device is successfully registered, or failed with error.
    func addDevice(fcmToken: DeviceId, deviceToken: DeviceId?, completion: ((Error?) -> Void)? = nil) {
        guard let currentUserId = client.currentUserId else {
            completion?(ClientError.CurrentUserDoesNotExist())
            return
        }

        currentUserUpdater.addDevice(fcmToken: fcmToken,
                                     deviceToken: deviceToken,
                                     projectId: client.projectId,
                                     completion: { error in
            if let error {
                log.debug("[ErmisChat] registerDevice with fcmToken: \(fcmToken), deviceToken: \(deviceToken ?? "nil"), failed: \(error)")
            } else {
                log.debug("[ErmisChat] registerDevice success with fcmToken: \(fcmToken), deviceToken: \(deviceToken ?? "nil")")
            }
            self.callback {
                completion?(error)
            }
        })
    }

    /// Removes a registered device from the current user.
    /// `connectUser` must be called before calling this.
    /// - Parameters:
    ///   - fcmToken: fcm token.
    ///   - completion: Called when device is successfully deregistered, or with error.
    func removeDevice(fcmToken: DeviceId, completion: ((Error?) -> Void)? = nil) {
        guard let currentUserId = client.currentUserId else {
            completion?(ClientError.CurrentUserDoesNotExist())
            return
        }

        currentUserUpdater.removeDevice(fcmToken: fcmToken) { error in
            self.callback {
                completion?(error)
            }
        }
    }

    /// Marks all channels for a user as read.
    ///
    /// - Parameter completion: Called when the API call is finished. Called with `Error` if the remote update fails.
    ///
    func markAllRead(completion: ((Error?) -> Void)? = nil) {
        currentUserUpdater.markAllRead { error in
            self.callback {
                completion?(error)
            }
        }
    }
}

// MARK: - Environment

extension CurrentUserController {
    struct Environment {
        var currentUserObserverBuilder: (
            _ context: NSManagedObjectContext,
            _ fetchRequest: NSFetchRequest<CurrentUserDTO>,
            _ itemCreator: @escaping (CurrentUserDTO) throws -> CurrentChatUser,
            _ fetchedResultsControllerType: NSFetchedResultsController<CurrentUserDTO>.Type
        ) -> EntityDatabaseObserver<CurrentChatUser, CurrentUserDTO> = EntityDatabaseObserver.init

        var currentUserUpdaterBuilder = CurrentUserUpdater.init
    }
}

// MARK: - Private

private extension EntityChange where Item == UnreadCount {
    var unreadCount: UnreadCount {
        switch self {
        case let .create(count):
            return count
        case let .update(count):
            return count
        case .remove:
            return .noUnread
        }
    }
}

private extension CurrentUserController {
    func createUserObserver() -> EntityDatabaseObserver<CurrentChatUser, CurrentUserDTO> {
        environment.currentUserObserverBuilder(
            client.databaseContainer.viewContext,
            CurrentUserDTO.defaultFetchRequest,
            { [unowned self] in
                try $0.asModel(self.client.projectId)
            },
            NSFetchedResultsController<CurrentUserDTO>.self
        )
    }
}

// MARK: - Delegates

/// `CurrentUserController` uses this protocol to communicate changes to its delegate.
public protocol CurrentUserControllerDelegate: AnyObject {
    /// The controller observed a change in the `UnreadCount`.
    func currentUserController(_ controller: CurrentUserController, didChangeCurrentUserUnreadCount: UnreadCount)

    /// The controller observed a change in the `CurrentChatUser` entity.
    func currentUserController(_ controller: CurrentUserController, didChangeCurrentUser: EntityChange<CurrentChatUser>)
}

public extension CurrentUserControllerDelegate {
    func currentUserController(_ controller: CurrentUserController, didChangeCurrentUserUnreadCount: UnreadCount) {}

    func currentUserController(_ controller: CurrentUserController, didChangeCurrentUser: EntityChange<CurrentChatUser>) {}
}

public extension CurrentUserController {
    /// Set the delegate of `CurrentUserController` to observe the changes in the system.
    var delegate: CurrentUserControllerDelegate? {
        get { multicastDelegate.mainDelegate }
        set { multicastDelegate.set(mainDelegate: newValue) }
    }
}
