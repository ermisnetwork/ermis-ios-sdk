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
        let inventory = channelListQuery.shouldLoadAllChannels && channelListQuery.sessionReadinessProjectId != nil
            && channelListQuery.pagination.offset == 0 && channelListQuery.pagination.cursor == nil
            ? e2eRepository?.beginSessionInventory() : nil
        let retry: () -> Void = { [weak self] in
            self?.update(channelListQuery: channelListQuery, userId: userId)
        }
        let requestId = UUID().uuidString.lowercased()
        let started = ProcessInfo.processInfo.systemUptime
        func trace(_ stage: String, count: Int) {
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
            log.info("channel_list_load stage=\(stage) request_id=\(requestId) count=\(count) elapsed_ms=\(elapsed)", subsystems: .mls)
        }
        trace("query_started", count: 0)
        fetch(channelListQuery: channelListQuery) { [weak self] in
            switch $0 {
            case let .success(channelListPayload):
                trace("query_received", count: channelListPayload.channels.count)
                let isInitialFetch = channelListQuery.pagination.cursor == nil && channelListQuery.pagination.offset == 0
                var initialActions: ((DatabaseSession) -> Void)?
                if isInitialFetch {
                    initialActions = { session in
                        let filterHash = channelListQuery.filter.filterHash
                        guard let queryDTO = session.channelListQuery(filterHash: filterHash) else { return }
                        queryDTO.channels.removeAll()
                    }
                }

                let finish: (Result<[Channel], Error>) -> Void = { result in
                    switch result {
                    case .success(let channels): trace("store_finished", count: channels.count)
                    case .failure: trace("store_failed", count: 0)
                    }
                    completion?(result)
                    if let inventory, let repository = self?.e2eRepository {
                        if case .success = result, let userId, let projectId = channelListQuery.sessionReadinessProjectId {
                            repository.completeSessionInventory(inventory, roots: channelListPayload,
                                userId: userId, projectId: projectId, retry: retry)
                        } else { repository.failSessionInventory(inventory, retry: retry) }
                    }
                }
                if channelListQuery.shouldLoadAllChannels,
                   channelListPayload.channels.count > max(1, channelListQuery.pagination.pageSize) {
                    self?.writeWholeListInBatches(payload: channelListPayload, query: channelListQuery, completion: finish)
                    return
                }
                self?.writeChannelListPayload(
                    payload: channelListPayload,
                    query: channelListQuery,
                    initialActions: initialActions,
                    completion: finish
                )
            case let .failure(error):
                trace("query_failed", count: 0)
                completion?(.failure(error))
                if let inventory { self?.e2eRepository?.failSessionInventory(inventory, retry: retry) }
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
        let snapshotOwner = apiClient.captureSessionNetworkOwner()
        // Fetches the channels matching the query, and stores them in the database.
        apiClient.requestChannelMetadata(query: updatedQuery, isRecovery: true) { [weak self] result in
            switch result {
            case .success(var channelListPayload):
                do { try snapshotOwner() } catch { completion(.failure(error)); return }
                channelListPayload.sessionOwner = snapshotOwner
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
        let query = ChannelListQuery(filter: .in(.cid, values: ids))
        fetch(channelListQuery: query) { [weak self] in
            switch $0 {
            case let .success(payload):
                guard let database = self?.database else { return }
                // Watching does not replace a channel-list query. Commit each complete
                // channel, then let already queued live events use the serial writer.
                WatchedChannelPageWriter.save(payload.channels, persist: { channel, didSave in
                    database.write({ session in
                        session.saveChannelList(payload: ChannelListPayload(channels: [channel]), query: nil)
                    }, completion: didSave)
                }, completion: { completion?($0) })
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
        apiClient.requestChannelMetadata(query: channelListQuery, completion: completion)
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
    /// Publish complete metadata batches only for an empty query (cold start).
    /// A refresh with existing rows retains the original atomic replacement.
    func writeWholeListInBatches(payload: ChannelListPayload, query: ChannelListQuery,
                                 completion: @escaping (Result<[Channel], Error>) -> Void) {
        let size = max(1, query.pagination.pageSize)
        let batches = stride(from: 0, to: payload.channels.count, by: size).map {
            Array(payload.channels[$0..<min($0 + size, payload.channels.count)])
        }
        var channels: [Channel] = []
        var usedAtomicRefresh = false
        let traceId = UUID().uuidString.lowercased()
        let started = ProcessInfo.processInfo.systemUptime
        WatchedChannelPageWriter.save(Array(batches.enumerated()), persist: { [database] batch, acknowledge in
            if usedAtomicRefresh { acknowledge(nil); return }
            database.write({ session in
                try payload.sessionOwner?()
                if batch.offset == 0, let queryDTO = session.channelListQuery(filterHash: query.filter.filterHash),
                   !queryDTO.channels.isEmpty {
                    // Existing rows are already usable: preserve refresh atomicity,
                    // including the ordering of queued live membership changes.
                    usedAtomicRefresh = true
                    queryDTO.channels.removeAll()
                    channels = session.saveChannelList(payload: payload, query: query).compactMap { try? $0.asModel() }
                } else {
                    let part = ChannelListPayload(channels: batch.element)
                    channels += session.saveChannelList(payload: part, query: query).compactMap { try? $0.asModel() }
                }
            }, completion: { error in
                if error == nil {
                    let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
                    log.info("channel_list_load stage=store_batch request_id=\(traceId) count=\(channels.count) elapsed_ms=\(elapsed)", subsystems: .mls)
                }
                acknowledge(error)
            })
        }, completion: { [weak self] error in
            if let error { completion(.failure(error)); return }
            do { try payload.sessionOwner?() } catch { completion(.failure(error)); return }
            self?.notifyPersistedMetadata(payload)
            completion(.success(channels))
        })
    }

    func notifyPersistedMetadata(_ payload: ChannelListPayload) {
        // Query results are now the bootstrap trigger, matching Web: restored groups
        // catch up in bounded batches; missing groups pre-sync for a Welcome and only
        // then fall back to serialized external join + post-sync.
        e2eRepository?.cleanupOrphanedMlsGroups()

        // Register exact latest-message demand before bootstrap can finish.
        e2eRepository?.requestChannelListPreviews(payload.channels)
        e2eRepository?.handlePersistedEncryptedChannels(payload)
    }

    func writeChannelListPayload(
        payload: ChannelListPayload,
        query: ChannelListQuery,
        initialActions: ((DatabaseSession) -> Void)? = nil,
        completion: ((Result<[Channel], Error>) -> Void)? = nil
    ) {
        var channels: [Channel] = []
        database.write { session in
            try payload.sessionOwner?()
            initialActions?(session)
            channels = session.saveChannelList(payload: payload, query: query).compactMap { try? $0.asModel() }
        } completion: { [weak self] error in
            if let error = error {
                log.error("Failed to save `ChannelListPayload` to the database. Error: \(error)")
                completion?(.failure(error))
            } else {
                do { try payload.sessionOwner?() } catch { completion?(.failure(error)); return }
                self?.notifyPersistedMetadata(payload)
                completion?(.success(channels))
            }
        }
    }
}
