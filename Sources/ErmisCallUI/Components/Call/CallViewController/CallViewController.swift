//
// Copyright 2025 Ermis Inc.
//

import Foundation
import UIKit
import Combine
import ErmisChat
import ErmisCall
import ErmisChatUI
import StreamWebRTC

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
        .videoView.init()
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
    /// The view responsible for displaying call's connection status.
    public private(set) lazy var connectionStatusView = callComponents
        .connectionStatusView.init()
        .withoutAutoresizingMaskConstraints
    /// The biew responsible for displaying call control buttons.
    public private(set) lazy var controls = createControlView()
    /// Timer for hide controls.
    private var hideControlsTimer: Timer?
    private var controlsBottomConstraint: NSLayoutConstraint?

    lazy var eventsController = call.client.eventsController()
    /// A boolean value, is `true` if call view controller is showing in PiP mode.
    private var isPiP: Bool = false
    /// A default ratio of Pip view.
    private let pipRatio = 16.0 / 9.0
    /// A component for displaying alert messages.
    public private(set) lazy var alertRouter = components.alertsRouter.init(rootViewController: self)
    /// Controller for call.
    public var controller: CallController!
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

    @MainActor required public init(with controller: CallController,
                                    delegate: CallViewControllerDelegate) {
        self.controller = controller
        self.delegate = delegate
        super.init(nibName: nil, bundle: nil)
    }
    
    @MainActor required public init?(coder: NSCoder) {
        super.init(coder: coder)
    }
    
    // MARK: - Setup
    open override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.updateSpeakerMenu()
    }

    open override func setUp() {
        super.setUp()
        setupNavigation()
        setupWebRTC()
        /// If outgoing call is not going, start it.
        if !callDetails.isIncoming, callDetails.state == .idle {
            startCall()
        }

        controller.delegate = self
        eventsController.delegate = self
        controller.startCallObservers()

        remoteVideoView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(onRemoteVideoDidTapped)))
        /// Set default audio port.
        if callDetails.isVideo {
            controller.setAudioPort(.builtInSpeaker)
        } else {
            controller.setAudioPort(.builtInReceiver)
        }

        updateViewByCallIOState()
    }

    open override func setUpUI() {
        super.setUpUI()
        self.view.addSubviews([
            remoteVideoView,
            remoteAvatarView,
            titleLabel,
            stateLabel,
            durationLabel,
            connectionStatusView,
            localVideoView,
            localAvatarView,
            controls
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

        localVideoView.pin(anchors: [.trailing], to: view, contant: -16)
        localVideoView.pin(anchors: [.width], to: 120)
        localVideoView.pin(anchors: [.height], to: 160)

        localAvatarView.pin(anchors: [.centerX, .centerY], to: localVideoView)
        localAvatarView.pin(anchors: [.width, .height], to: 60)

        controls.topAnchor.pin(equalTo: localVideoView.bottomAnchor, constant: 20).isActive = true
        controls.pin(anchors: [.centerX], to: view)
        controls.pin(anchors: [.height], to: 56)
        controlsBottomConstraint = controls.bottomAnchor.pin(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -40)
        controlsBottomConstraint?.isActive = true
    }

    open override func setUpTheme() {
        super.setUpTheme()
        view.backgroundColor = theme.colors.surface
        titleLabel.textColor = theme.colors.white
        titleLabel.font = theme.fonts.title
        stateLabel.textColor = theme.colors.white
        stateLabel.font = theme.fonts.body
        durationLabel.textColor = theme.colors.white
        durationLabel.font = theme.fonts.body
        titleView.tintColor = theme.colors.white
    }

    private func setupWebRTC() {
        Task {
            if callDetails.isVideo {
                let isCameraAvailable = await ioAccessManager.requestCameraAccessIfNeeded()
                guard isCameraAvailable else {
                    controller.setVideoEnabled(false)
                    return
                }
                DispatchQueue.main.async {
                    self.controller.renderLocalVideo(to: self.localVideoView.videoView)
                }
            }
        }
    }

    open override func contentDidChanged() {
        super.contentDidChanged()
        navigationItem.title = callDetails.isVideo == true ? L10n.Call.Title.videoCall : L10n.Call.Title.voiceCall

        if let membership = controller.channel.membership {
            localVideoView.content = .init(with: membership, isMirror: true)
        }

        if let directMembership = controller.channel.directUserMembership {
            remoteVideoView.content = .init(with: directMembership)
        }

        remoteAvatarView.loadImage(from: callDetails.imageURL,
                                   with: ImageLoaderOptions(
                                    resize: .init(components.avatarThumbnailSize),
                                    placeHolderString: callDetails.title,
                                    placeholder: nil
                                   ))

        localAvatarView.loadImage(from: callDetails.currentUser?.imageURL,
                                   with: ImageLoaderOptions(
                                    resize: .init(components.avatarThumbnailSize),
                                    placeHolderString: callDetails.currentUser?.displayName,
                                    placeholder: nil
                                   ))

        titleLabel.text = callDetails.title
        stateLabel.text = L10n.Call.Status.ringing
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
        Task {
            do {
                try await controller.startCall()
            } catch let error {
                log.error("[ErmisCall] start call failed with error: \(error)", subsystems: .call)
                // busy
                if let clientError = error as? ClientError, clientError.ermisApiError?.type == .otherCallInProgress {
                    DispatchQueue.main.async {
                        self.presentAlert(title: L10n.Call.Message.receiverBusy,
                                          message: nil,
                                          okHandler: { [weak self] in
                            self?.close()
                        })
                    }
                    return
                }
                DispatchQueue.main.async {
                    self.presentAlert(title: "Error when starting call",
                                      message: "Something went wrong",
                                      okHandler: { [weak self] in
                        self?.close()
                    })
                }
            }
        }
    }

    /// End current call.
    public func endCall() {
        Task {
            do {
                try await controller.endCall()
                close()
            } catch let error {
                close()
                log.error("[ErmisCall] end call failed with error: \(error)", subsystems: .call)
            }
        }
    }

    /// Update speaker menu button.
    func updateSpeakerMenu() {
        if let speakerButton = controls.getButton(of: .speaker) {
            speakerButton.menu = UIMenu(children:
                                            controller.getAllAudioPort().map({ port in
                return UIAction(title: port.name,
                                state: port == controller.getCurrentAudioPort() ? .on : .off, handler: { [weak self] _ in
                    guard let self else {
                        return
                    }
                    controller.setAudioPort(port.portType)
                })
            })
            )

            speakerButton.showsMenuAsPrimaryAction = true
        }
    }

    /// Hide call screen. If current call is video call, video call will be shown in PiP mode.
    @objc private func back() {
        if callDetails.isVideo {
            delegate?.callViewControllerWantsToMinize(self)
        } else {
            NotificationCenter.default.post(name: .callVCDidHidden,
                                            object: self,
                                            userInfo: [
                                                "call_id": callDetails.callId,
                                                "cid": callDetails.cid
                                            ])
            delegate?.callViewControllerWantsToDismiss(self)
        }
    }

    private func close() {
        delegate?.callViewControllerWantsToDismiss(self)
    }

    @objc public func onRemoteVideoDidTapped() {
        UIView.animate(withDuration: 0.35) {
            self.navigationController?.setNavigationBarHidden(false, animated: true)
            self.setControlsViewHidden(false)
        }
        startHideControlsTimer()
    }
    // MARK: - Private

    /// Update screen by call's state.
    private func updateViewByCallState() {
        switch callState {
        case .ringing:
            stateLabel.text = L10n.Call.Status.ringing
        case .connecting:
            stateLabel.text = L10n.Call.Status.connecting
        case .connected:
            stateLabel.text = ""
        case .ended:
            stateLabel.text = L10n.Call.Status.ended
        default:
            stateLabel.text = ""
        }
        stateLabel.isHidden = stateLabel.text.isEmptyOrNil

        updateNavigationBarTitleView()
    }

    /// Update screen by call's IO State.
    private func updateViewByCallIOState() {
        updateAvatarsVisibleState()
        updateTitleLabelVisibleState()
        updateDurationLabelVisibleState()
        updateVideoViewsState()
        updateControlsState()
    }

    private func startHideControlsTimer() {
        stopHideControlsTimer()
        hideControlsTimer = Timer.scheduledTimer(timeInterval: 5,
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
        updateViewByCallState()
        updateDurationLabelVisibleState()
        if callState == .connected {
            startHideControlsTimer()
        }
        if callState == .ended {
            close()
        }
    }

    open func callConnectionStatusDidChange(to connectionStatus: CallConnectionStatus) {
        updateConnectionStatusLabel(connectionStatus)
    }

    open func callIOStateDidChange(to callIOState: ErmisCall.CallIOState) {
        if !callDetails.isVideo, callIOState.isVideoEnabled || callIOState.isRemoteVideoEnabled {
            call.details.isVideo = true
            CallManager.shared.reportUpdateCall(for: callDetails.uuid, hasVideo: true)
        }
        updateViewByCallIOState()

        callIOState
    }

    open func remoteVideoTrackDidChange(to remoteVideoTrack: RTCVideoTrack?) {
        remoteVideoTrack?.add(self.remoteVideoView.videoView)
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

    public func callDidEnd(_ notification: Notification) {
        guard let callId = notification.userInfo?["call_id"] as? String,
              callId == callDetails.callId else { return }
        self.close()
    }
    // MARK: - CallControlViewDelegate
    open func callControlView(_ view: CallControlView, didSelect buttonType: CallControlButtonType) {
        switch buttonType {
        case .speaker:
            break
        case .video:
            if ioAccessManager.isCameraAccessGranted {
                controller.togleVideo()
            } else {
                Task {
                    let isCameraAccessGranted = await ioAccessManager.requestCameraAccessIfNeeded()
                    if isCameraAccessGranted {
                        controller.togleVideo()
                    } else {
                        ioAccessManager.presentCameraPermissionDeniedAlert(from: self, showSettingAction: false, animated: true)
                        var content = view.content
                        content?.isVideoEnable = false
                        view.content = content
                    }
                }
            }
        case .switchCamera:
            controller.switchCamera()
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
            controller.toggleMute()
        case .endCall:
            endCall()
        case .shareScreen:
            break
        case .custom(rawValue: let rawValue):
            // Manual handle in subclass.
            break
        }

        onRemoteVideoDidTapped()
    }

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

    open func createLocalVideoView() -> VideoView {
        let view = callComponents.videoView.init().withoutAutoresizingMaskConstraints
        view.layer.cornerRadius = 10
        view.clipsToBounds = true
        return view
    }
}
// MARK: - EventsControllerDelegate
extension CallViewController: EventsControllerDelegate {
    public func eventsController(_ controller: ErmisChat.EventsController, didReceiveEvent event: any ErmisChat.Event) {
        if let callSignalEvent = event as? CallSignalEvent, callDetails.callId == callSignalEvent.callId {
            if callSignalEvent.callAction == .endCall {
                close()
            }
        }
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
        localAvatarView.isHidden = callIOState.isVideoEnabled || !callDetails.isVideo
        remoteAvatarView.isHidden = callIOState.isRemoteVideoEnabled
    }

    /// Update user's video view/ other user's video view visble state.
    private func updateVideoViewsState() {
        localVideoView.isHidden = isPiP || !callDetails.isVideo

        localVideoView.videoView.isHidden = !callIOState.isVideoEnabled
        remoteVideoView.videoView.isHidden = !callIOState.isRemoteVideoEnabled
        if !localVideoView.videoView.isHidden {
            DispatchQueue.main.async {
                self.controller.renderLocalVideo(to: self.localVideoView.videoView)
            }
        }
        if !remoteVideoView.videoView.isHidden {
            DispatchQueue.main.async {
                self.controller.renderRemoteVideo(to: self.remoteVideoView.videoView)
            }
        }
    }

    /// Update controls view.
    private func updateControlsState() {
        controls.isHidden = isPiP
        controls.content = .init(isAudioEnable: callIOState.isAudioEnabled,
                                 isVideoEnable: callIOState.isVideoEnabled,
                                 currentPort: controller.getCurrentAudioPort()?.portType ?? .builtInReceiver)
        if let switchCamera = controls.getButton(of: .switchCamera) {
            switchCamera.isHidden = !callDetails.isVideo
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
    private func updateDurationLabelVisibleState() {
        guard !isPiP else {
            durationLabel.isHidden = true
            return
        }
        durationLabel.isHidden = callDetails.isVideo || callState != .connected
    }

    
    private func updateNavigationBarTitleView() {
        if !callDetails.isVideo {
            titleView.content = .init(title: L10n.Call.Title.voiceCall)
        } else {
            switch callState {
            case .idle, .ringing, .connecting:
                titleView.content = .init(title: L10n.Call.Title.videoCall)
            case .connected, .ended:
                titleView.content = .init(title: callDetails.title, subtitle: timeFormater.string(from: duration))
            }
        }
        navigationItem.titleView = titleView
    }

    private func setControlsViewHidden(_ isHidden: Bool) {
        let constant = isHidden ? view.safeAreaInsets.bottom + controls.bounds.height : -40
        self.controlsBottomConstraint?.constant = constant
    }

    private func updateConnectionStatusLabel(_ connectionStatus: CallConnectionStatus) {
        connectionStatusView.content = .init(connectionStatus: connectionStatus,
                                             callTitle: callDetails.title)
    }
}
// MARK: - PiPable
extension CallViewController: PiPable {
    public func willMinimizedPiP() {

    }

    public func didMinimizedPiP() {
        isPiP = true
        onPiPStateDidChange()
    }

    public func willExpanedPiP() {

    }

    public func didExpanedPiP() {
        isPiP = false
        onPiPStateDidChange()
    }

    private func onPiPStateDidChange() {
        UIView.animate(withDuration: 0.27, animations: {
            self.updateAvatarsVisibleState()
            self.updateVideoViewsState()
            self.updateTitleLabelVisibleState()
            self.updateStateLabelVisible()
            self.updateDurationLabelVisibleState()
            self.updateControlsState()
            self.navigationController?.setNavigationBarHidden(self.controls.isHidden, animated: true)
        })
    }
}
// MARK: - Computed properties
extension CallViewController {
    public var call: Call {
        return controller.call
    }

    public var callDetails: CallDetails {
        return controller.callDetails
    }

    public var callIOState: CallIOState {
        return controller.callIOState
    }

    public var callState: CallState {
        return controller.callState
    }

    public var duration: TimeInterval {
        return controller.duration
    }
}
