//
// Copyright 2025 Ermis Inc.
//

import Foundation
import UIKit
import Combine
import ErmisChat
import ErmisCall
import ErmisChatUI
import ErmisCallNode
import AVFoundation
import AVKit

public protocol CallViewControllerDelegate: AnyObject {
    func callViewControllerWantsToMinize(_ callVC: CallViewController)
    func callViewControllerWantsToDismiss(_ callVC: CallViewController)
}
/// Controller responsible for displaying auido/video call.
open class CallViewController: _ViewController, UIProvider, CallComponentsProvider, CallControllerDelegate, CallControlViewDelegate {
    /// The view for showing as a navigation title view.
    public private(set) lazy var titleView = callComponents
        .callTitleContainerView.init()
        .withoutAutoresizingMaskConstraints
    /// The View responsible for display current user's video.
    /// If Video is turn off, it will display user avatar with blur efect.
    public private(set) lazy var localVideoView = createLocalVideoView()
    /// The view display current user's avatar.
    public private(set) lazy var localAvatarView = components
        .avatarView.init(style: .circular)
        .withoutAutoresizingMaskConstraints
    /// The View responsible for other user's video.
    /// If Video is turn off, it will display user avatar with blur efect.
    public private(set) lazy var remoteVideoView = callComponents
        .remoteVideoView.init()
        .withoutAutoresizingMaskConstraints
    /// The view responsible for displaying other user's avatar.
    public private(set) lazy var remoteAvatarView = components
        .avatarView.init(style: .circular)
        .withoutAutoresizingMaskConstraints
    /// The view responsible for displaying other user's name.
    public private(set) lazy var titleLabel = createTitleLabel()
    /// The view responsible for displaying call's state.
    public private(set) lazy var stateLabel = createStateLabel()
    /// The view responsible for displaying call's duration.
    public private(set) lazy var durationLabel = createDurationLabel()

    public private(set) lazy var connectionStatusLabel = UILabel().withoutAutoresizingMaskConstraints
    /// The view responsible for displaying call's connection status.
    public private(set) lazy var connectionStatusView = callComponents
        .connectionStatusView.init()
        .withoutAutoresizingMaskConstraints
    /// The biew responsible for displaying call control buttons.
    public private(set) lazy var controls = createControlView()
    /// Timer for hide controls.
    private var hideControlsTimer: Timer?
    private var controlsBottomConstraint: NSLayoutConstraint?

    private var localVideoCenterXConstraint: NSLayoutConstraint?
    private var localVideoCenterYConstraint: NSLayoutConstraint?
    private var localVideoInitialCenterX: CGFloat = 0
    private var localVideoInitialCenterY: CGFloat = 0
    private var localVideoPanGesture: UIPanGestureRecognizer!
    private var localVideoPosition: CACornerMask = .layerMaxXMaxYCorner

    private var isEndingCall = false
    /// A boolean value, is `true` if call view controller is showing in PiP mode.
    private var isPiP: Bool = false
    /// A default ratio of Pip view.
    private let pipRatio = 16.0 / 9.0
    /// A component for displaying alert messages.
    public private(set) lazy var alertRouter = components.alertsRouter.init(rootViewController: self)
    /// Controller for call.
    public weak var controller: CallController?
    public weak var delegate: CallViewControllerDelegate?

    private lazy var timeFormater = {
        let formater = DateComponentsFormatter()
        formater.allowedUnits = [.minute, .second]
        formater.unitsStyle = .positional
        formater.zeroFormattingBehavior = .pad
        formater.maximumUnitCount = 3
        return formater
    }()

    var cancelBags: [AnyCancellable] = []
    /// The class for access IO devices like: camera, mic...
    private let ioAccessManager = IOAccessManager()

    // MARK: - Lifecyle + Setup
    required public init(with controller: CallController,
                                    delegate: CallViewControllerDelegate) {
        self.controller = controller
        self.delegate = delegate
        super.init(nibName: nil, bundle: nil)
    }
    
    required public init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        log.debug("TTTT CALL VIEW CONTROLLER DEINIT")
        stopHideControlsTimer()
        controller?.delegate = nil
        NotificationCenter.default.removeObserver(self, name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    // MARK: - Setup
    open override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.updateSpeakerMenu()
        self.updateViewByCallIOState()
        self.positionLocalVideoAtCorner(localVideoPosition)
//        self.call.callNodeClient.sendRequestKeyframeEvent()
    }

    open override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { @MainActor [weak self] in
            guard let call, await call.details.state != .ended,
                  await !CallManager.shared.containsEndingCallUUID(call.details.uuid) else {
                close()
                return
            }
            /// If outgoing call is not going, start it.
            if let callDetails, !callDetails.isIncoming, callDetails.state == .idle {
                startCall()
            }
        }
    }

    open override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        log.debug("[CallVC] viewDidDisappear - isBeingDismissed: \(isBeingDismissed), isMovingFromParent: \(isMovingFromParent)")
    }

    override open func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        onTraitCollectionDidChange(previousTraitCollection)
    }

    override open func viewWillLayoutSubviews() {
        onViewWillLayoutSubViews()
        super.viewWillLayoutSubviews()
    }

    open override func setUp() {
        setupNavigation()


        controller?.delegate = self
        controller?.startCallObservers()

        connectionStatusLabel.numberOfLines = 0
        connectionStatusLabel.isHidden = true

        remoteVideoView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(onRemoteVideoDidTapped)))
        updateViewByCallIOState()
        setupBackgroundObservers()
        setupLocalVideoDragging()
        stateLabel.isHidden = true
    }
    
    private func setupBackgroundObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }
    
    @objc private func appDidEnterBackground() {

    }
    
    @objc private func appWillEnterForeground() {
        // This can be used to restore the call UI if needed
        // For now, we'll just log that we're coming back to foreground
        log.debug("[Call] App will enter foreground, isPiP: \(isPiP)", subsystems: .call)
    }

    open override func setUpUI() {
        self.view.addSubviews([
            remoteVideoView,
            remoteAvatarView,
            titleLabel,
            stateLabel,
            durationLabel,
            connectionStatusView,
            localVideoView,
            localAvatarView,
            controls,
            connectionStatusLabel
        ])

        remoteVideoView.pin(to: view)

        remoteAvatarView.pin(anchors: [.top], to: view, contant: 175)
        remoteAvatarView.pin(anchors: [.centerX], to: view)
        remoteAvatarView.pin(anchors: [.width, .height], to: 100)

        titleLabel.topAnchor.pin(equalTo: remoteAvatarView.bottomAnchor, constant: 8).isActive = true
        titleLabel.pin(anchors: [.centerX], to: view)

        stateLabel.topAnchor.pin(equalTo: titleLabel.bottomAnchor, constant: 8).isActive = true
        stateLabel.pin(anchors: [.centerX], to: view)

        durationLabel.topAnchor.pin(equalTo: titleLabel.bottomAnchor, constant: 8).isActive = true
        durationLabel.pin(anchors: [.centerX], to: view)

        connectionStatusView.topAnchor.pin(equalTo: durationLabel.bottomAnchor, constant: 8).isActive = true
        connectionStatusView.pin(anchors: [.centerX], to: view)
        connectionStatusView.pin(anchors: [.leading], to: view, contant: 16)

//        localVideoView.pin(anchors: [.trailing], to: view, contant: -16)
        localVideoView.pin(anchors: [.width], to: 120)
        localVideoView.pin(anchors: [.height], to: 160)
        localVideoCenterXConstraint = localVideoView.centerXAnchor.constraint(equalTo: view.leadingAnchor, constant: 0)
        localVideoCenterYConstraint = localVideoView.centerYAnchor.constraint(equalTo: view.topAnchor, constant: 0)
        localVideoCenterYConstraint?.priority = .defaultHigh
        localVideoCenterXConstraint?.isActive = true
        localVideoCenterYConstraint?.isActive = true

        localAvatarView.pin(anchors: [.centerX, .centerY], to: localVideoView)
        localAvatarView.pin(anchors: [.width, .height], to: 60)

        controls.topAnchor.pin(greaterThanOrEqualTo: localVideoView.bottomAnchor, constant: 20).isActive = true
        controls.pin(anchors: [.centerX], to: view)
        controls.pin(anchors: [.height], to: 56)
        controlsBottomConstraint = controls.bottomAnchor.pin(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -40)
        controlsBottomConstraint?.isActive = true

        setupCallNode()

        connectionStatusLabel.pin(anchors: [.leading, .trailing], to: view)
        connectionStatusLabel.topAnchor.pin(equalTo: view.topAnchor, constant: 200).isActive = true
        self.setControlsViewHidden(true)
    }

    open override func setUpTheme() {
        view.backgroundColor = theme.colors.surface
        titleLabel.textColor = theme.colors.white
        titleLabel.font = theme.fonts.title
        stateLabel.textColor = theme.colors.white
        stateLabel.font = theme.fonts.body
        durationLabel.textColor = theme.colors.white
        durationLabel.font = theme.fonts.body
        titleView.tintColor = theme.colors.white
    }

    private func setupCallNode() {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            if let callDetails, callDetails.isVideo {
                let isCameraAvailable = await ioAccessManager.requestCameraAccessIfNeeded()
                guard isCameraAvailable else {
                    controller?.setVideoEnabled(false)
                    return
                }

            }
            if let call {
                self.localVideoView.attach(with: call.callNodeClient.capturer)
            } else {
                log.warning("[CallViewController] can't attach localvideo view because call is nil.")
            }
        }
    }

    private func setupLocalVideoDragging() {
        localVideoPanGesture = UIPanGestureRecognizer(target: self, action: #selector(handleLocalVideoPan(_:)))
        localVideoView.addGestureRecognizer(localVideoPanGesture)
        localVideoView.isUserInteractionEnabled = true
    }

    open override func contentDidChanged() {
        Task { @MainActor [weak self] in
            navigationItem.title = callDetails?.isVideo == true ? L10n.Call.Title.videoCall : L10n.Call.Title.voiceCall

            if let membership = controller?.channel.membership {
                localVideoView.content = .init(with: membership, isMirror: false)
            }

            if let directMembership = controller?.channel.directUserMembership {
                remoteVideoView.content = .init(with: directMembership)
            }

            remoteAvatarView.loadImage(from: callDetails?.imageURL,
                                       with: ImageLoaderOptions(
                                        resize: .init(components.avatarThumbnailSize),
                                        placeHolderString: callDetails?.title,
                                        placeholder: nil
                                       ))

            localAvatarView.loadImage(from: callDetails?.currentUser?.imageURL,
                                      with: ImageLoaderOptions(
                                        resize: .init(components.avatarThumbnailSize),
                                        placeHolderString: callDetails?.currentUser?.displayName,
                                        placeholder: nil
                                      ))

            titleLabel.text = callDetails?.title
        }
    }

    private func setupNavigation() {
        let barButtonItemAppearance = UIBarButtonItemAppearance(style: .plain)
        barButtonItemAppearance.normal.titleTextAttributes = [.foregroundColor: theme.colors.white]

        guard let customNavBarAppearance = navigationController?.navigationBar.standardAppearance else {
            return
        }
        customNavBarAppearance.configureWithTransparentBackground()
        customNavBarAppearance.buttonAppearance = barButtonItemAppearance
        customNavBarAppearance.backButtonAppearance = barButtonItemAppearance
        customNavBarAppearance.doneButtonAppearance = barButtonItemAppearance
        customNavBarAppearance.titleTextAttributes = [.foregroundColor: theme.colors.white]

        navigationController?.navigationBar.standardAppearance = customNavBarAppearance
        navigationController?.navigationBar.scrollEdgeAppearance = customNavBarAppearance
        navigationController?.navigationBar.compactAppearance = customNavBarAppearance
        if #available(iOS 15.0, *) {
            navigationController?.navigationBar.compactScrollEdgeAppearance = customNavBarAppearance
        }

        navigationItem.leftBarButtonItem = createBackBarButton()
        navigationItem.rightBarButtonItem = createChatButton()

        updateNavigationBarTitleView()
    }

    // MARK: - Action

    /// Start current call.
    public func startCall() {
        log.debug("TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT")
        Task(priority: .userInitiated) { [weak self] in
            guard let self else {
                return
            }
            do {
                try await controller?.startCall()
            } catch let error {

            }
        }
    }

    /// End current call.
    public func endCall() {
        isEndingCall = true
        updateViewForEnding()
        Task { @MainActor [weak self] in
            do {
                try await controller?.endCall()
            } catch let error {
                //close()
                log.error("[ErmisCall] end call failed with error: \(error)", subsystems: .call)
            }
        }

    }

    /// Update speaker menu button.
    func updateSpeakerMenu() {
        if let speakerButton = controls.getButton(of: .speaker) {
            let currentPort = controller?.getCurrentAudioPort()
            speakerButton.menu = UIMenu(children:
                                            controller?.getAllAudioPort().map({ port in
                return UIAction(title: port.name,
                                state: port == currentPort ? .on : .off, handler: { [weak self] _ in
                    guard let self else {
                        return
                    }
                    controller?.setAudioPort(port.portType)
                })
            }) ?? []
            )

            speakerButton.showsMenuAsPrimaryAction = true
        }
    }

    /// Hide call screen. If current call is video call, video call will be shown in PiP mode.
    @objc private func back() {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            if callDetails?.isVideo == true {
                delegate?.callViewControllerWantsToMinize(self)
            } else {
                NotificationCenter.default.post(name: .callVCDidHidden,
                                                object: self,
                                                userInfo: [
                                                    "call_id": callDetails?.callId,
                                                    "cid": callDetails?.cid
                                                ])
                delegate?.callViewControllerWantsToDismiss(self)
            }
        }

    }

    private func close() {
        log.debug("[CallVC] close() called - presentingVC: \(presentingViewController != nil), navigationController: \(navigationController != nil)")
        log.debug("[CallVC], closed, \(isPiP)]")
//        if !isPiP {
        while let presentedVC = self.presentedViewController {
            presentedVC.dismiss(animated: false)
        }
        controller?.cleanUp()
        delegate?.callViewControllerWantsToDismiss(self)
//        }
    }

    @objc public func onRemoteVideoDidTapped() {
        guard let controller else {
            return
        }
        UIView.animate(withDuration: 0.35) {
            self.navigationController?.setNavigationBarHidden(false, animated: true)
            self.setControlsViewHidden(false)
        }
        startHideControlsTimer()
    }

    @objc private func handleLocalVideoPan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view)

        switch gesture.state {
        case .began:
            localVideoInitialCenterX = localVideoCenterXConstraint?.constant ?? 0
            localVideoInitialCenterY = localVideoCenterYConstraint?.constant ?? 0

        case .changed:
            localVideoCenterXConstraint?.constant = localVideoInitialCenterX + translation.x
            localVideoCenterYConstraint?.constant = localVideoInitialCenterY + translation.y

        case .ended, .cancelled:
            let velocity = gesture.velocity(in: view)
            snapLocalVideoToCorner(with: velocity)

        default:
            break
        }
    }

    @discardableResult
    private func snapLocalVideoToCorner(with velocity: CGPoint) -> CACornerMask {
        let padding: CGFloat = 16
        let safeArea = view.safeAreaInsets
        let videoSize = CGSize(width: 120, height: 160)//localVideoView.bounds.size

        let topY = safeArea.top + padding + videoSize.height / 2
        let bottomY = view.bounds.height - safeArea.bottom - videoSize.height / 2 - 20
        let leftX = padding + videoSize.width / 2
        let rightX = view.bounds.width - padding - videoSize.width / 2

        let corners: [(point: CGPoint, mask: CACornerMask)] = [
            (CGPoint(x: leftX, y: topY), .layerMinXMinYCorner),      // Top-left
            (CGPoint(x: rightX, y: topY), .layerMaxXMinYCorner),     // Top-right
            (CGPoint(x: leftX, y: bottomY), .layerMinXMaxYCorner),   // Bottom-left
            (CGPoint(x: rightX, y: bottomY), .layerMaxXMaxYCorner)   // Bottom-right
        ]

        let currentCenterX = localVideoCenterXConstraint?.constant ?? 0
        let currentCenterY = localVideoCenterYConstraint?.constant ?? 0

        let projectedCenter = CGPoint(
            x: currentCenterX + velocity.x * 0.1,
            y: currentCenterY + velocity.y * 0.1
        )

        var closestCorner = corners[0]
        var minDistance = CGFloat.greatestFiniteMagnitude

        for corner in corners {
            let distance = hypot(projectedCenter.x - corner.point.x, projectedCenter.y - corner.point.y)
            if distance < minDistance {
                minDistance = distance
                closestCorner = corner
            }
        }

        // Animate constraint changes
//        UIView.animate(
//            withDuration: 0.4,
//            delay: 0,
//            usingSpringWithDamping: 0.7,
//            initialSpringVelocity: 0.5,
//            options: [.curveEaseOut],
//            animations: {
//                self.localVideoCenterXConstraint?.constant = closestCorner.point.x
//                self.localVideoCenterYConstraint?.constant = closestCorner.point.y
//                self.view.layoutIfNeeded()
//            },
//            completion: nil
//        )
        positionLocalVideoAtCorner(closestCorner.mask)
        return closestCorner.mask
    }

    private func positionLocalVideoAtCorner(_ corner: CACornerMask, animated: Bool = true) {
        let padding: CGFloat = 16
        let safeArea = view.safeAreaInsets
        let videoSize = CGSize(width: 120, height: 160)//localVideoView.bounds.size

        log.debug("TTTT videosize: \(videoSize), safeArea: \(safeArea)")

        let topY = safeArea.top + padding + videoSize.height / 2
        let bottomY = view.bounds.height - safeArea.bottom - videoSize.height / 2 - 20

        let leftX = padding + videoSize.width / 2
        let rightX = view.bounds.width - padding - videoSize.width / 2

        let targetX: CGFloat
        let targetY: CGFloat

        switch corner {
        case .layerMinXMinYCorner: // top-left
            targetX = leftX
            targetY = topY
        case .layerMaxXMinYCorner: // top-right
            targetX = rightX
            targetY = topY
        case .layerMinXMaxYCorner: // bottom-left
            targetX = leftX
            targetY = bottomY
        default: // bottom-right (.layerMaxXMaxYCorner)
            targetX = rightX
            targetY = bottomY
        }

        if animated {
            UIView.animate(
                withDuration: 0.4,
                delay: 0,
                usingSpringWithDamping: 0.7,
                initialSpringVelocity: 0.5,
                options: [.curveEaseOut],
                animations: {
                    self.localVideoCenterXConstraint?.constant = targetX
                    self.localVideoCenterYConstraint?.constant = targetY
                    self.view.layoutIfNeeded()
                },
                completion: nil
            )
        } else {
            localVideoCenterXConstraint?.constant = targetX
            localVideoCenterYConstraint?.constant = targetY
        }
    }
    // MARK: - Private

    /// Update screen by call's state.
    private func updateViewByCallState() {
        guard !isEndingCall else {
            stateLabel.text = L10n.Call.Status.ended
            return
        }
        switch callState {
        case .idle:
            stateLabel.text = ""
        case .starting:
            stateLabel.text = ""
        case .reported:
            stateLabel.text = L10n.Call.Status.ringing
        case .ringing:
            stateLabel.text = L10n.Call.Status.ringing
        case .connecting:
            stateLabel.text = L10n.Call.Status.connecting
        case .connected:
            stateLabel.text = ""
        case .ending:
            stateLabel.text = L10n.Call.Status.ended
        case .ended:
            stateLabel.text = L10n.Call.Status.ended
        }

        updateStateLabelVisible()
        updateNavigationBarTitleView()
    }

    private func updateViewForEnding() {
        updateControlsState()
        updateViewByCallState()
    }

    /// Update screen by call's IO State.
    @MainActor
    private func updateViewByCallIOState() {
        Task { @MainActor in
            let ioState = await callIOState
            let details = await callDetails
            let isVideo = (details?.isVideo ?? false) || ioState.isVideoEnabled || ioState.isRemoteVideoEnabled
            updateAvatarsVisibleState()
            updateTitleLabelVisibleState()
            updateDurationLabelVisibleState(isVideo: isVideo, callState: callState)
            updateVideoViewsState()
            updateControlsState()
        }
    }

    private func startHideControlsTimer() {
        stopHideControlsTimer()
        hideControlsTimer = Timer.scheduledTimer(timeInterval: 8,
                                                 target: self,
                                                 selector: #selector(hideControlsTimerDidFire),
                                                 userInfo: nil,
                                                 repeats: false)
    }

    private func stopHideControlsTimer() {
        hideControlsTimer?.invalidate()
        hideControlsTimer = nil
    }

    @objc private func hideControlsTimerDidFire() {
        UIView.animate(withDuration: 0.35) {
            self.navigationController?.setNavigationBarHidden(true, animated: false)
            self.setControlsViewHidden(true)
        }
    }

    // MARK: - CallControllerDelegate
    open func callStateDidChange(to callState: CallState) {
        Task { @MainActor in
            let ioState = await callIOState
            let details = await callDetails
            let isVideo = (details?.isVideo ?? false) || ioState.isVideoEnabled || ioState.isRemoteVideoEnabled
            let callState = await callState
            log.debug("TTTT CALL STATE: \(callState), isVideo: \(details?.isVideo ?? false)", subsystems: .call)
            updateViewByCallState()
            await updateDurationLabelVisibleState(isVideo:isVideo,  callState: callState)
            if callState == .connected {
                startHideControlsTimer()
            }
            if callState == .ended {
                //close()
            }
        }
    }

    open func callConnectionStatusDidChange(to connectionStatus: CallConnectionStatus) {
        updateConnectionStatusLabel(connectionStatus)
    }

    open func callIOStateDidChange(to callIOState: ErmisCall.CallIOState) {

        Task { @MainActor in
            let state = callState
            let details = await callDetails
            let isVideo = (details?.isVideo ?? false) || callIOState.isVideoEnabled || callIOState.isRemoteVideoEnabled

            if let callDetails, !callDetails.isVideo, callIOState.isVideoEnabled {
                await call?.setVideoEnabled(true)
                await CallManager.shared.reportUpdateCall(for: callDetails.uuid, hasVideo: true)
            }
            updateViewByCallIOState()
            updateDurationLabelVisibleState(isVideo: isVideo, callState: state)
        }
    }

    open func durationDidChange(to duration: TimeInterval) {
        timeFormater.allowedUnits = duration >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        durationLabel.text = timeFormater.string(from: duration)
        updateNavigationBarTitleView()
    }

    open func audioPortChange(to port: AudioPort?) {
        updateSpeakerMenu()
        if var controlsContent = controls.content {
            controlsContent.currentPort = port?.portType ?? .builtInReceiver
            controls.content = controlsContent
        }
    }

    public func didReceiveCallManagerMessage(_ message: CallManagerMessage) {
        log.debug("[CallViewController] Did receive call manager message: \(message)")
        Task { @MainActor in
            switch message {
            case .startEndingCall(let uuid, let id, let cid):
                guard callDetails?.uuid == uuid else {
                    return
                }
                isEndingCall = true
                updateViewForEnding()
            case .endCall(let uuid, let id, let cid):
                //self.close()
                break
            case .createOutgoingCallError(let uuid, let error):
                guard callDetails?.uuid == uuid else {
                    return
                }
                guard !isPiP else {
                    return
                }
                if let clientError = error as? ClientError, clientError.ermisApiError?.type == .otherCallInProgress {
                    self.presentAlert(title: L10n.Call.Message.receiverBusy,
                                      message: nil,
                                      okHandler: { [weak self] in
                        self?.close()
                    })
                    return
                }
                self.presentAlert(title: "Error when starting call",
                                  message: "Something went wrong",
                                  okHandler: { [weak self] in
                    self?.close()
                })
            case .failedToConnect(uuid: let uuid, error: let error):
                guard callDetails?.uuid == uuid else {
                    return
                }
                guard !isPiP else {
                    return
                }
                if let clientError = error as? ClientError, clientError.ermisApiError?.type == .otherCallInProgress {
                    self.presentAlert(title: L10n.Call.Message.receiverBusy,
                                      message: nil,
                                      okHandler: { [weak self] in
                        self?.close()
                    })
                    return
                }
                self.presentAlert(title: "Error when connecting",
                                  message: "Something went wrong",
                                  okHandler: { [weak self] in
                    self?.close()
                })
            }
        }
    }

//    public func callDidEnd(_ notification: Notification) {
//        guard let call else {
//            self.close()
//            return
//        }
//        guard let callUUID = notification.userInfo?["call_uuid"] as? String,
//              callUUID == callDetails?.uuid.uuidString else {
//            log.warning("[Call] CallVC Received end call notification with wrong id")
//            return
//        }
//        self.close()
//    }

    public func callDidUpdateConnectionStats(status: ErmisCallNode.ConnectionStats) {
        var connectionType: String = ""
        switch status.connectionType {
        case .direct:
            connectionType = "Direct"
        case .mixed:
            connectionType = "Mixed"
        case .relay:
            connectionType = "Relay"
        case .none:
            connectionType = "None"
        default:
            break
        }
        let content = "\(connectionType) - packetloss: \(status.packetLoss), rtt: \(status.roundTripTimeMs)"
        connectionStatusLabel.text = content
    }

    public func remoteVideoOrientationDidChanged(to orientation: VideoOrientation) {
        guard let renderView = self.remoteVideoView.renderView,
              let previewLayer = renderView.previewLayer else { return }

        self.remoteVideoView.layoutIfNeeded()

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Determine video gravity
        let videoGravity: AVLayerVideoGravity
        if UIDevice.current.isPhone {
            let isFit = orientation.rotation == 0 || orientation.rotation == 180
            videoGravity = isFit ? .resizeAspect : .resizeAspectFill
        } else {
            videoGravity = .resizeAspect
        }
        previewLayer.videoGravity = videoGravity

        let rotationAngle = CGFloat(orientation.rotation) * .pi / 180
        let containerBounds = self.remoteVideoView.bounds

        if orientation.rotation == 90 || orientation.rotation == 270 {
            // For 90° and 270° rotations, swap width and height
            previewLayer.setAffineTransform(.identity)
            previewLayer.frame = CGRect(
                x: 0,
                y: 0,
                width: containerBounds.height,  // Swap dimensions
                height: containerBounds.width
            )
            // Center the layer after swapping dimensions
            previewLayer.position = CGPoint(x: containerBounds.midX, y: containerBounds.midY)
            previewLayer.setAffineTransform(CGAffineTransform(rotationAngle: rotationAngle))
        } else {
            // For 0° and 180° rotations, use normal dimensions
            previewLayer.setAffineTransform(.identity)
            previewLayer.frame = containerBounds
            previewLayer.setAffineTransform(CGAffineTransform(rotationAngle: rotationAngle))
        }

        CATransaction.commit()
    }

    // MARK: - CallControlViewDelegate
    open func callControlView(_ view: CallControlView, didSelect buttonType: CallControlButtonType) {
        switch buttonType {
        case .speaker:
            break
        case .video:
            if ioAccessManager.isCameraAccessGranted {
                controller?.togleVideo()
            } else {
                Task {
                    let isCameraAccessGranted = await ioAccessManager.requestCameraAccessIfNeeded()
                    if isCameraAccessGranted {
                        controller?.togleVideo()
                    } else {
                        ioAccessManager.presentCameraPermissionDeniedAlert(from: self, showSettingAction: false, animated: true)
                        var content = view.content
                        content?.isVideoEnable = false
                        view.content = content
                    }
                }
            }
        case .switchCamera:
            controller?.switchCamera()
        case .mic:
            if !callIOState.isAudioEnabled {
                if !ioAccessManager.isMicrophoneAccessGranted {
                    ioAccessManager.presentMicrophonePermissionDeniedAlert(from: self, showSettingAction: false, animated: true)
                    var content = view.content
                    content?.isAudioEnable = false
                    view.content = content
                    return
                }
            }
            controller?.toggleMute()
        case .endCall:
            endCall()
            let endCallButton = view.getButton(of: .endCall)
            endCallButton?.isEnabled = false
        case .shareScreen:
            break
        case .custom(rawValue: let rawValue):
            // Manual handle in subclass.
            break
        }

        onRemoteVideoDidTapped()
    }

    // MARK: - AVPictureInPictureControllerDelegate
//    private func onPiPStateDidChange() {
//        UIView.animate(withDuration: 0.27, animations: {
//            self.updateAvatarsVisibleState()
//            self.updateVideoViewsState()
//            self.updateTitleLabelVisibleState()
//            self.updateStateLabelVisible()
//            self.updateDurationLabelVisibleState()
//            self.updateControlsState()
//            self.navigationController?.setNavigationBarHidden(self.controls.isHidden, animated: true)
//        })
//    }
//    open func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
//        isPiP = true
//        stopHideControlsTimer()
//    }
//
//    open func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
//        isPiP = true
//        onPiPStateDidChange()
//    }
//
//    open func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: any Error) {
//
//    }
//
//    open func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
//        log.debug("[PiP] Will stop PiP, isPiP: \(isPiP)")
//        isPiP = false
//        
//        // Prepare the video view to receive content again
//        remoteVideoView.isHidden = false
//        log.debug("[PiP] Remote video view isHidden: \(remoteVideoView.isHidden)")
//    }
//
//    open func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
//        log.debug("[PiP] Did stop PiP, isPiP: \(isPiP)")
//        isPiP = false
//        startHideControlsTimer()
//        
//        // Update all UI visibility
//        onPiPStateDidChange()
//        
//        // Force layout update to prevent black screen
//        DispatchQueue.main.async { [weak self] in
//            guard let self = self else { return }
//            
//            log.debug("[PiP] Refreshing video view")
//            
//            // Force a complete UI update
//            self.updateViewByCallIOState()
//            
//            // Force layout
//            self.view.setNeedsLayout()
//            self.view.layoutIfNeeded()
//            
//            log.debug("[PiP] Video view frame: \(self.remoteVideoView.frame)")
//            log.debug("[PiP] Video view isHidden: \(self.remoteVideoView.isHidden)")
//        }
//    }
//
//    open func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping @Sendable (Bool) -> Void) {
//        // This is called when user wants to restore from PiP (taps the PiP window)
//        // This is called BEFORE pictureInPictureControllerWillStopPictureInPicture
//        log.debug("[PiP] Restore UI requested, view.window: \(view.window != nil), isPiP: \(isPiP)")
//        
//        // Pre-emptively set isPiP to false so UI will be shown
//        isPiP = false
//        
//        // Update UI to show everything again
//        DispatchQueue.main.async { [weak self] in
//            guard let self = self else {
//                completionHandler(false)
//                return
//            }
//            
//            self.onPiPStateDidChange()
//            
//            // Check if we're already visible
//            if self.view.window != nil {
//                // Already in the window hierarchy, just complete
//                log.debug("[PiP] Already visible, completing")
//                completionHandler(true)
//                return
//            }
//            
//            // Need to present the view controller
//            log.debug("[PiP] Not visible, presenting...")
//            let viewControllerToPresent: UIViewController = self.navigationController ?? self
//            viewControllerToPresent.modalPresentationStyle = .fullScreen
//            
//            // Find the top-most view controller to present from
//            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
//                  let window = scene.windows.first,
//                  let rootVC = window.rootViewController else {
//                log.debug("[PiP] Failed to find root VC")
//                completionHandler(false)
//                return
//            }
//            
//            var topVC = rootVC
//            while let presented = topVC.presentedViewController {
//                topVC = presented
//            }
//            
//            topVC.present(viewControllerToPresent, animated: true) {
//                log.debug("[PiP] Presentation completed")
//                completionHandler(true)
//            }
//        }
//    }

    // MARK: - Create UI
    open func createBackBarButton() -> UIBarButtonItem {
        let barButtonItem = UIBarButtonItem(image: UIImage(systemName: "chevron.left"), style: .plain, target: self, action: #selector(back))
        barButtonItem.tintColor = theme.colors.white
        return barButtonItem
    }

    open func createChatButton() -> UIBarButtonItem {
        let barButtonItem = UIBarButtonItem(image: Theme.Icons.chat, style: .plain, target: self, action: #selector(back))
        barButtonItem.tintColor = theme.colors.white
        return barButtonItem
    }

    open func createBackgroundImageView() -> UIImageView {
        let imageView = UIImageView().withoutAutoresizingMaskConstraints
        return imageView
    }

    open func createControlView() -> CallControlView {
        let controls = callComponents
            .controlsView.init()
            .withoutAutoresizingMaskConstraints
        controls.delegate = self
        return controls
    }

    open func createTitleLabel() -> UILabel {
        let label = UILabel().withoutAutoresizingMaskConstraints
        return label
    }

    open func createStateLabel() -> UILabel {
        let label = UILabel().withoutAutoresizingMaskConstraints
        return label
    }

    open func createDurationLabel() -> UILabel {
        let label = UILabel().withoutAutoresizingMaskConstraints
        return label
    }

    open func createLocalVideoView() -> LocalVideoView {
        let view = callComponents.localVideoView.init().withoutAutoresizingMaskConstraints
        view.layer.cornerRadius = 10
        view.clipsToBounds = true
        return view
    }
}
// MARK: - UIContextMenuInteractionDelegate
extension CallViewController: UIContextMenuInteractionDelegate {
    public func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation point: CGPoint) -> UIContextMenuConfiguration? {
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { sugestionAction in
            return UIMenu(title: "", children: [])
        }
    }
}
// MARK: - Update Views
extension CallViewController {
    /// Update user's avatar/ other user's avatar visble state.
    private func updateAvatarsVisibleState() {
        guard !isPiP else {
            localAvatarView.isHidden = true
            remoteAvatarView.isHidden = true
            return
        }
        Task { @MainActor in
            let isVideo = await callDetails?.isVideo ?? false
            localAvatarView.isHidden = callIOState.isVideoEnabled || !(isVideo)
            remoteAvatarView.isHidden = callIOState.isRemoteVideoEnabled
        }
    }

    /// Update user's video view/ other user's video view visble state.
    private func updateVideoViewsState() {
        Task { @MainActor in
            let isVideo = await callDetails?.isVideo ?? false
            localVideoView.isHidden = isPiP || !(isVideo)

            localVideoView.videoView.isHidden = !callIOState.isVideoEnabled
            remoteVideoView.videoView.isHidden = !callIOState.isRemoteVideoEnabled
        }

    }

    /// Update controls view.
    private func updateControlsState() {
        controls.isHidden = isPiP || isEndingCall
        controls.content = .init(isAudioEnable: callIOState.isAudioEnabled,
                                 isVideoEnable: callIOState.isVideoEnabled,
                                 currentPort: controller?.getCurrentAudioPort()?.portType ?? .builtInReceiver)
        Task { @MainActor in
            if let switchCamera = controls.getButton(of: .switchCamera) {
                switchCamera.isHidden = !(callDetails?.isVideo ?? false)
            }
        }
    }

    /// Update title label
    private func updateTitleLabelVisibleState() {
        guard !isPiP else {
            titleLabel.isHidden = true
            return
        }
        titleLabel.isHidden = callIOState.isRemoteVideoEnabled
    }

    /// Update call status label
    private func updateStateLabelVisible() {
        guard !isPiP else {
            stateLabel.isHidden = true
            return
        }
        stateLabel.isHidden = stateLabel.text.isEmptyOrNil
    }
    /// Update call duration label.
    public func updateDurationLabelVisibleState(isVideo: Bool, callState: CallState) {
        guard !isPiP else {
            durationLabel.isHidden = true
            return
        }
        durationLabel.isHidden = isVideo || callState != .connected
    }

    private func updateNavigationBarTitleView() {
        Task { @MainActor [weak self] in
            if let callDetails, !callDetails.isVideo {
                titleView.content = .init(title: L10n.Call.Title.voiceCall)
            } else {
                switch callState {
                case .idle, .starting, .reported, .ringing, .connecting:
                    titleView.content = .init(title: L10n.Call.Title.videoCall)
                case .connected, .ending, .ended:
                    titleView.content = .init(title: callDetails?.title, subtitle: timeFormater.string(from: duration))
                }
            }
            navigationItem.titleView = titleView
        }
    }

    private func setControlsViewHidden(_ isHidden: Bool) {
        let constant = isHidden ? view.safeAreaInsets.bottom + controls.bounds.height : -40
        self.controlsBottomConstraint?.constant = constant
    }

    private func updateConnectionStatusLabel(_ connectionStatus: CallConnectionStatus) {
        Task { @MainActor [weak self] in
            connectionStatusView.content = .init(connectionStatus: connectionStatus,
                                                 callTitle: callDetails?.title)
        }
    }
}
//// MARK: - PiPable
extension CallViewController: PiPable {
    public func willMinimizedPiP() {
        isPiP = true
        stopHideControlsTimer()
    }

    public func didMinimizedPiP() {
        isPiP = true
        onPiPStateDidChange()
    }

    public func willExpanedPiP() {
        isPiP = false
        if let call {
            remoteVideoOrientationDidChanged(to: call.callNodeClient.remoteVideoOrientationPublisher.value)
        }
    }

    public func didExpanedPiP() {
        isPiP = false
        startHideControlsTimer()
        onPiPStateDidChange()
        if let call {
//            remoteVideoOrientationDidChanged(to: call.callNodeClient.remoteVideoOrientationPublisher.value)
        }
    }

    private func onPiPStateDidChange() {
        Task { @MainActor in
            let ioState = await callIOState
            let details = await callDetails
            let isVideo = (details?.isVideo ?? false) || ioState.isVideoEnabled || ioState.isRemoteVideoEnabled
            UIView.animate(withDuration: 0.27, animations: {
                self.updateAvatarsVisibleState()
                self.updateVideoViewsState()
                self.updateTitleLabelVisibleState()
                self.updateViewByCallState()
                self.updateDurationLabelVisibleState(isVideo: isVideo, callState: self.callState)
                self.updateControlsState()
                self.navigationController?.setNavigationBarHidden(self.controls.isHidden, animated: true)
            })
        }

    }
}
// MARK: - Computed properties
extension CallViewController {
    public var call: Call? {
        return controller?.call
    }

    public var callDetails: CallDetails? {
        get async {
            return await controller?.callDetails
        }
    }

    public var callIOState: CallIOState {
        return controller?.callIOState ?? .init()
    }

    public var callState: CallState {
        return controller?.callState ?? .idle
    }

    public var duration: TimeInterval {
        return controller?.duration ?? 0
    }
}

extension CallViewController: AVPictureInPictureSampleBufferPlaybackDelegate {
    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {

    }
    
    public func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        return CMTimeRange(start: .zero, end: .zero)
    }
    
    public func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        return false
    }
    
    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {

    }
    
    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping @Sendable () -> Void) {
        completionHandler()
    }
}
