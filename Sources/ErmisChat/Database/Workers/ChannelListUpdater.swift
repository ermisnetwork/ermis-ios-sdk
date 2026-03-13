//
// Copyright 2025 Ermis Inc.
//

import CoreData
import ErmisShared

/// Makes a channels query call to the backend and updates the local storage with the results.
class ChannelListUpdater: Worker {
    private weak var e2eRepository: E2eRepository?

    init(database: DatabaseContainer, apiClient: APIClient, e2eRepository: E2eRepository?) {
        self.e2eRepository = e2eRepository
        super.init(database: database, apiClient: apiClient)
    }

    /// Makes a channels query call to the backend and updates the local storage with the results.
    ///
    /// - Parameters:
    ///   - channelListQuery: The channels query used in the request
    ///   - completion: Called when the API call is finished. Called with `Error` if the remote update fails.
    ///
    func update(
        channelListQuery: ChannelListQuery,
        userId: String?,
        completion: ((Result<[Channel], Error>) -> Void)? = nil
    ) {
        fetch(channelListQuery: channelListQuery) { [weak self] in
            switch $0 {
            case let .success(channelListPayload):
                let isInitialFetch = channelListQuery.pagination.cursor == nil && channelListQuery.pagination.offset == 0
                var initialActions: ((DatabaseSession) -> Void)?
                if isInitialFetch {
                    initialActions = { session in
                        let filterHash = channelListQuery.filter.filterHash
                        guard let queryDTO = session.channelListQuery(filterHash: filterHash) else { return }
                        queryDTO.channels.removeAll()
                    }
                }

                self?.writeChannelListPayload(
                    payload: channelListPayload,
                    query: channelListQuery,
                    initialActions: initialActions,
                    completion: completion
                )
            case let .failure(error):
                completion?(.failure(error))
            }
        }
    }

    func resetChannelsQuery(
        for query: ChannelListQuery,
        pageSize: Int,
        watchedAndSynchedChannelIds: Set<ChannelId>,
        synchedChannelIds: Set<ChannelId>,
        completion: @escaping (Result<(synchedAndWatched: [Channel], unwanted: Set<ChannelId>), Error>) -> Void
    ) {
        var updatedQuery = query
        updatedQuery.pagination = .init(pageSize: pageSize, offset: 0)

        var unwantedCids = Set<ChannelId>()
        // Fetches the channels matching the query, and stores them in the database.
        apiClient.recoveryRequest(endpoint: .channels(query: query)) { [weak self] result in
            switch result {
            case let .success(channelListPayload):
                self?.writeChannelListPayload(
                    payload: channelListPayload,
                    query: updatedQuery,
                    initialActions: { session in
                        guard let queryDTO = session.channelListQuery(filterHash: updatedQuery.filter.filterHash) else { return }

                        let localQueryCIDs = Set(queryDTO.channels.compactMap { try? ChannelId(cid: $0.cid) })
                        let remoteQueryCIDs = Set(channelListPayload.channels.map(\.channel.cid))

                        let updatedChannels = synchedChannelIds.union(watchedAndSynchedChannelIds)
                        let localNotInRemote = localQueryCIDs.subtracting(remoteQueryCIDs)
                        let localInRemote = localQueryCIDs.intersection(remoteQueryCIDs)

                        // We unlink those local channels that are no longer in remote
                        for cid in localNotInRemote {
                            guard let channelDTO = session.channel(cid: cid) else { continue }
                            queryDTO.channels.remove(channelDTO)
                        }

                        // We are going to clean those channels that are present in the both the local and remote query,
                        // and that have not been synched nor watched. Those are outdated, can contain gaps.
                        let cidsToClean = localInRemote.subtracting(updatedChannels)
                        session.cleanChannels(cids: cidsToClean)

                        // We are also going to keep track of the unwanted channels
                        // Those are the ones that exist locally but we are not interested in anymore in this context.
                        // In this case, it is going to query local ones not appearing in remote, subtracting the ones
                        // that are already being watched.
                        unwantedCids = localNotInRemote.subtracting(watchedAndSynchedChannelIds)
                    },
                    completion: { result in
                        switch result {
                        case let .success(newSynchedAndWatchedChannels):
                            completion(.success((newSynchedAndWatchedChannels, unwantedCids)))
                        case let .failure(error):
                            completion(.failure(error))
                        }
                    }
                )
            case let .failure(error):
                completion(.failure(error))
            }
        }
    }

    /// Starts watching the channels with the given ids and updates the channels in the local storage.
    ///
    /// - Parameters:
    ///   - ids: The channel ids.
    ///   - completion: The callback once the request is complete.
    func startWatchingChannels(withIds ids: [ChannelId], userId: String?, completion: ((Error?) -> Void)? = nil) {
        var query = ChannelListQuery(filter: .in(.cid, values: ids))
        fetch(channelListQuery: query) { [weak self] in
            switch $0 {
            case let .success(payload):
                self?.database.write { session in
                    session.saveChannelList(payload: payload, query: nil)
                } completion: { _ in
                    completion?(nil)
                }
            case let .failure(error):
                completion?(error)
            }
        }
    }

    func loadChannel(with cid: ChannelId, completion: @escaping (Result<Channel, Error>) -> Void) {
        fetch(channelQuery: .init(cid: cid, pageSize: 0)) { [weak self] result in
            switch result {
            case .success(let channelPayload):
                self?.database.write({ session in
                    do {
                        let channelDTO = try session.saveChannel(payload: channelPayload)
                        let channel = try channelDTO.asModel()
                        completion(.success(channel))
                    } catch let error {
                        completion(.failure(error))
                    }
                })
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func searchPublicChannel(in projectId: String,
                             term: String,
                             offset: Int = 0,
                             limit: Int = 100,
                             completion: @escaping (Result<ChannelListPublicSearchPayload, Error>) -> Void) {
        let body = ChannelPublicSearchRequestBody(projectId: projectId,
                                                  searchTerm: term,
                                                  limit: limit,
                                                  offset: offset)
        apiClient.request(endpoint: .channelPublicSearch(body: body), completion: { [weak self] result in
            switch result {
            case .success(let payload):
                completion(.success(payload.searchResult))
            case .failure(let error):
                completion(.failure(error))
            }
        })
    }

    /// Fetches the given query from the API and returns results via completion.
    ///
    /// - Parameters:
    ///   - channelListQuery: The query to fetch from the API.
    ///   - completion: The completion to call with the results.
    func fetch(
        channelListQuery: ChannelListQuery,
        completion: @escaping (Result<ChannelListPayload, Error>) -> Void
    ) {
        apiClient.request(
            endpoint: .channels(query: channelListQuery),
            completion: completion
        )
    }

    /// Fetches the given query from the API and returns results via completion.
    ///
    /// - Parameters:
    ///   - channelQuery: The query to fetch from the API.
    ///   - completion: The completion to call with the results.
    func fetch(channelQuery: ChannelQuery, completion: @escaping(Result<ChannelPayload, Error>) -> Void) {
        apiClient.request(endpoint: .updateChannel(query: channelQuery), completion: completion)
    }

    /// Marks all channels for a user as read.
    /// - Parameter completion: Called when the API call is finished. Called with `Error` if the remote update fails.
    func markAllRead(completion: ((Error?) -> Void)? = nil) {
        apiClient.request(endpoint: .markAllRead()) {
            completion?($0.error)
        }
    }

    /// Links a channel to the given query.
    func link(channel: Channel, with query: ChannelListQuery, completion: ((Error?) -> Void)? = nil) {
        database.write { session in
            guard let (channelDTO, queryDTO) = session.getChannelWithQuery(cid: channel.cid, query: query) else {
                return
            }
            queryDTO.channels.insert(channelDTO)
        } completion: { error in
            completion?(error)
        }
    }

    /// Unlinks a channel to the given query.
    func unlink(channel: Channel, with query: ChannelListQuery, completion: ((Error?) -> Void)? = nil) {
        database.write { session in
            guard let (channelDTO, queryDTO) = session.getChannelWithQuery(cid: channel.cid, query: query) else {
                return
            }
            queryDTO.channels.remove(channelDTO)
        } completion: { error in
            completion?(error)
        }
    }
}

private extension DatabaseSession {
    func getChannelWithQuery(cid: ChannelId, query: ChannelListQuery) -> (ChannelDTO, ChannelListQueryDTO)? {
        guard let queryDTO = channelListQuery(filterHash: query.filter.filterHash) else {
            log.debug("Channel list query has not yet created \(query)")
            return nil
        }

        guard let channelDTO = channel(cid: cid) else {
            log.debug("Channel \(cid) cannot be found in database.")
            return nil
        }

        return (channelDTO, queryDTO)
    }
}

private extension ChannelListUpdater {
    func writeChannelListPayload(
        payload: ChannelListPayload,
        query: ChannelListQuery,
        initialActions: ((DatabaseSession) -> Void)? = nil,
        completion: ((Result<[Channel], Error>) -> Void)? = nil
    ) {
        var channels: [Channel] = []
        database.write { session in
            initialActions?(session)
            channels = session.saveChannelList(payload: payload, query: query).compactMap { try? $0.asModel() }
        } completion: { [weak self] error in
            if let error = error {
                log.error("Failed to save `ChannelListPayload` to the database. Error: \(error)")
                completion?(.failure(error))
            } else {
                // Only external-join channels the user was already a member of
                // before this device logged in (membershipCreatedAt < loginTime).
                // Channels joined after login will be handled via welcome or
                // invite events instead.
                let loginTime = self?.e2eRepository?.loginTime
                let mlsCids = payload.channels
                    .filter { channelPayload in
                        guard channelPayload.channel.mlsEnabled else { return false }
                        guard let loginTime,
                              let memberCreatedAt = channelPayload.membership?.createdAt else {
                            return false
                        }
                        return memberCreatedAt < loginTime
                    }
                    .map { $0.channel.cid }
                if !mlsCids.isEmpty {
                    self?.e2eRepository?.handleNewEncryptedChannels(mlsCids)
                }
                completion?(.success(channels))
            }
        }
    }
}
