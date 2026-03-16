//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// A view that shows a channel avatar including an online indicator if any user is online.
open class ChannelAvatarView: _View, UIProvider, SwiftUIRepresentable {
    /// A view that shows the avatar image
    open private(set) lazy var presenceAvatarView: PresenceAvatarView = components
        .presenceAvatarView.init(with: avatarStyle)
        .withoutAutoresizingMaskConstraints

    open private(set) lazy var combinedAvatarView: CombineAvatarView = components
        .combinedAvatarView
        .init(bottomLeftAvatarStyle: .cornerRadius(12),
              topRightAvatarStyle: .cornerRadius(10))
        .withoutAutoresizingMaskConstraints

    /// The data this view component shows.
    open var content: Content? {
        didSet {
            guard oldValue != content else {
                return
            }
            updateContentIfNeeded()
        }
    }

    open var avatarStyle: AvatarStyle = .circular {
        didSet {
            presenceAvatarView.avatarStyle = avatarStyle
        }
    }

    /// The maximum number of images that combine to form a single avatar
    private let maxNumberOfImagesInCombinedAvatar = 2

    var channelLoadedAvatarCID: ChannelId?

    public required init(avatarStyle: AvatarStyle) {
        super.init(frame: .zero)
        self.avatarStyle = avatarStyle
    }
    
    @MainActor public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    open override func setUp() {
        combinedAvatarView.isHidden = true
    }

    override open func setUpUI() {
        super.setUpUI()
        embed(presenceAvatarView)
        embed(combinedAvatarView)
    }

    override open func contentDidChanged() {
        presenceAvatarView.isOnlineIndicatorVisible = false
        guard let content else {
            presenceAvatarView.avatarView.cancelLoading()
            combinedAvatarView.cancelLoading()
            return
        }
        loadAvatar(for: content)
    }

    open func loadAvatar(for content: Content) {
        guard channelLoadedAvatarCID != content.cid else { return }
        // If the channel has an avatar set, load that avatar
        if let channelAvatarUrl = content.imageUrl {
            presenceAvatarView.isHidden = false
            combinedAvatarView.isHidden = true
            loadChannelAvatar(from: channelAvatarUrl)
            if content.isDirectChannel {
                let lastActiveMembers = self.lastActiveMembers()
                guard !lastActiveMembers.isEmpty , let otherMember = lastActiveMembers.first else {
                    return
                }
                presenceAvatarView.isOnlineIndicatorVisible = (content.isDirectChannel ?? false) && otherMember.isOnline
            }
            return
        }
        // Use the appropriate method to load avatar based on channel type
        if content.isDirectChannel {
            presenceAvatarView.isHidden = false
            combinedAvatarView.isHidden = true
            combinedAvatarView.cancelLoading()
            loadDirectMessageChannelAvatar()
        } else if content.lastActiveMembers.filter { $0.isJoined }.count < 3 {
            presenceAvatarView.isHidden = false
            combinedAvatarView.isHidden = true
            combinedAvatarView.cancelLoading()
            loadIntoAvatarImageView(from: nil, placeHolderString: content.channelName)
        } else {
            presenceAvatarView.isHidden = true
            presenceAvatarView.avatarView.cancelLoading()
            combinedAvatarView.isHidden = false
            loadMergedAvatars(for: content.cid)
        }
    }

    /// Loads the avatar from the URL. This function is used when the channel has a non-nil `imageURL`
    /// - Parameter url: The `imageURL` of the channel
    open func loadChannelAvatar(from url: URL) {
        loadIntoAvatarImageView(from: url, placeHolderString: content?.channelName)
    }

    /// Loads avatar for a directMessageChannel
    /// - Parameter channel: The channel
    open func loadDirectMessageChannelAvatar() {
        let lastActiveMembers = self.lastActiveMembers()

        // If there are no members other than the current user in the channel, load a placeholder
        guard !lastActiveMembers.isEmpty , let otherMember = lastActiveMembers.first(where: { $0.userId !=  content?.currentUserId}) else {
            presenceAvatarView.isOnlineIndicatorVisible = false
            loadIntoAvatarImageView(from: nil, placeHolderString: content?.lastActiveMembers.first?.displayName)
            return
        }

        loadIntoAvatarImageView(from: otherMember.imageURL,
                                placeHolderString: otherMember.displayName)
        presenceAvatarView.isOnlineIndicatorVisible = (content?.isDirectChannel ?? false) && otherMember.isOnline
    }

    /// Loads an avatar which is merged (tiled) version of the first four active members of the channel
    /// - Parameter channel: The channel
    open func loadMergedAvatars(for cid: ChannelId) {
        // The channel is a non-DM channel, hide the online indicator
        presenceAvatarView.isOnlineIndicatorVisible = false

        let lastActiveMembers = self.lastActiveMembers().filter { $0.isJoined }

        // If there are no members other than the current user in the channel, load a placeholder
        guard lastActiveMembers.count > 1 else {
            loadIntoAvatarImageView(from: nil, placeHolderString: content?.channelName)
            return
        }

        var members = lastActiveMembers.filter({ $0.imageURL != nil })
        // We show a combination of at max images combined
        members = Array(members.prefix(maxNumberOfImagesInCombinedAvatar))
        if members.count < maxNumberOfImagesInCombinedAvatar, members.count < lastActiveMembers.count {
            let unAvatarMembers = lastActiveMembers
                .filter{ $0.imageURL == nil }
                .prefix(min(lastActiveMembers.count, maxNumberOfImagesInCombinedAvatar) - members.count)
            members.append(contentsOf: unAvatarMembers)
        }
        self.combinedAvatarView.content = members
    }

    /// Loads avatars for the given URLs
    /// - Parameters:
    ///   - members: The channel members
    ///   - channelId: The channelId of the channel
    ///   - completion: Completion that gets called with an array of `UIImage`s when all the avatars are loaded
//    open func loadAvatarsFrom(
//        members: [ChannelMember],
//        channelId: ChannelId,
//        completion: @escaping ([UIImage], ChannelId)
//            -> Void
//    ) {
//        let avatarSize = components.avatarThumbnailSize
//        let imageProcessor = components.imageProcessor
//        let requests = members.map(\.imageURL).prefix(maxNumberOfImagesInCombinedAvatar)
//            .compactMap { $0 }
//            .map { ImageDownloadRequest(url: $0, options: ImageDownloadOptions(resize: .init(avatarSize))) }
//
//        components.imageLoader.downloadMultipleImages(with: requests) { [weak self] results in
//            // Scale only placeholders since images already have a correct size
//            let imagesMapper = ImageResultsMapper(results: results)
//            let images = imagesMapper.mapErrors { index in
//                let placeholderImage = PlaceholderImageGenerator.shared.getPlaceHolderImage(from: members[index].displayName)
//                return imageProcessor.scale(image: placeholderImage, to: avatarSize)
//            }
//            completion(images, channelId)
//        }
//    }

    open func lastActiveMembers() -> [ChannelMember] {
        guard let content else { return [] }
        return content.lastActiveMembers
            .sorted { $0.memberCreatedAt ?? Date() < $1.memberCreatedAt ?? Date() }
            .filter { $0.userId != content.currentUserId }
    }

    open func loadIntoAvatarImageView(from url: URL?,
                                      placeholder: UIImage? = nil,
                                      placeHolderString: String? = nil) {
        log.debug("Load image from URL: \(url)")
        presenceAvatarView.avatarView.cancelLoading()
        presenceAvatarView.avatarView.loadImage(from: url,
                                                with: ImageLoaderOptions(
            resize: .init(components.avatarThumbnailSize),
            placeHolderString: placeHolderString,
            placeholder: placeholder
        ))
    }
}

public
extension ChannelAvatarView {
    struct Content: Equatable {
        let cid: ChannelId
        let channelName: String
        let imageUrl: URL?
        let lastActiveMembers: [ChannelMember]
        let isDirectChannel: Bool
        let currentUserId: UserId

        public init?(from channel: Channel?) {
            guard let channel, let currentUserId = channel.membership?.userId else { return nil }
            self.cid = channel.cid
            self.channelName = channel.name ?? channel.cid.id
            self.imageUrl = channel.imageURL
            self.lastActiveMembers = channel.lastActiveMembers
            self.isDirectChannel = channel.isDirectMessageChannel
            self.currentUserId = currentUserId
        }
    }
}
