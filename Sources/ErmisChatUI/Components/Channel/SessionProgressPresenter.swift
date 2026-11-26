import UIKit
import ErmisChat

@MainActor
public final class SessionProgressPresenter {
    private var observers: [NSObjectProtocol] = []
    private weak var owner: SessionSyncProgress?
    private var cycle: UUID?
    private var dismissed: UUID?
    private var panel: UIView?
    private weak var progressHost: UIViewController?
    private var completionTimer: DispatchWorkItem?
    private var timerCycle: UUID?
    private var timerToken = UUID()
    private let statusIcon = UIImageView()
    private let label = UILabel(), retry = UIButton(type: .system), close = UIButton(type: .system), spinner = UIActivityIndicatorView(style: .medium)
    private let currentProgress: () -> SessionSyncProgress?
    private let localized: (String) -> String
    var scheduleCompletion: (@escaping () -> Void) -> Void = { action in
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: action)
    }

    public init(currentProgress: @escaping () -> SessionSyncProgress?,
                localized: @escaping (String) -> String = { NSLocalizedString($0, comment: "") }) {
        self.currentProgress = currentProgress; self.localized = localized
    }

    public static let hostDidAppear = Notification.Name("ermis.sessionProgress.chatDidAppear")
    public static let hostWillDisappear = Notification.Name("ermis.sessionProgress.chatWillDisappear")

    public func start() {
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(forName: Self.hostDidAppear, object: nil, queue: .main) { [weak self] notification in
            _Concurrency.Task { @MainActor in
                guard let self, let host = notification.object as? UIViewController else { return }
                self.show(on: host, anchor: notification.userInfo?["progressAnchor"] as? UIView,
                          channelId: notification.userInfo?["progressChannelId"] as? String,
                          isEncrypted: notification.userInfo?["progressIsEncrypted"] as? () -> Bool)
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: Self.hostWillDisappear, object: nil, queue: .main) { [weak self] notification in
            _Concurrency.Task { @MainActor in
                guard let self, let host = notification.object as? UIViewController else { return }
                self.hide(from: host)
            }
        })
        for name in [SessionSyncProgress.changed, UIApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                _Concurrency.Task { @MainActor in self?.refresh(replayTerminal: name == SessionSyncProgress.changed) }
            })
        }
    }
    private weak var progressAnchor: UIView?
    private var channelId: String?
    private var isEncrypted: (() -> Bool)?

    public func show(on host: UIViewController, anchor: UIView? = nil, channelId: String? = nil, isEncrypted: (() -> Bool)? = nil) {
        panel?.removeFromSuperview(); panel = nil; progressHost = host; progressAnchor = anchor
        self.channelId = channelId
        self.isEncrypted = isEncrypted
        refresh(replayTerminal: false)
    }
    public func hide(from host: UIViewController) {
        guard progressHost === host else { return }
        panel?.removeFromSuperview(); panel = nil; progressHost = nil; progressAnchor = nil; channelId = nil; isEncrypted = nil
    }
    func refresh(replayTerminal: Bool = true) {
        guard let progress = currentProgress() else { panel?.removeFromSuperview(); panel = nil; owner = nil; cycle = nil; dismissed = nil; return }
        if owner !== progress { panel?.removeFromSuperview(); panel = nil; owner = progress; cycle = nil; dismissed = nil }
        guard let state = progress.snapshot else { panel?.removeFromSuperview(); panel = nil; cycle = nil; dismissed = nil; return }
        if isEncrypted?() == false || (state.historyCid != nil && state.historyCid != channelId) {
            panel?.removeFromSuperview(); panel = nil
            return
        }
        if cycle != state.cycleId || state.status != "done" {
            completionTimer?.cancel(); completionTimer = nil; timerCycle = nil; timerToken = UUID()
        }
        cycle = state.cycleId
        guard dismissed != state.cycleId else { panel?.removeFromSuperview(); panel = nil; return }
        // Navigation must not replay a previous page's completed notification.
        guard replayTerminal || state.status == "running" || state.isChannelReadiness else { return }
        guard let progressHost, let host = progressHost.viewIfLoaded, host.window != nil else { panel?.removeFromSuperview(); panel = nil; return }
        let anchor = progressAnchor ?? host
        if panel == nil {
            let box = UIView(); box.translatesAutoresizingMaskIntoConstraints = false; box.backgroundColor = .systemBackground
            box.layer.cornerRadius = 20; box.layer.shadowOpacity = 0.08; box.layer.shadowRadius = 8; box.layer.shadowOffset = CGSize(width: 0, height: 3)
            box.layer.borderWidth = 0.5; box.layer.borderColor = UIColor.separator.withAlphaComponent(0.3).cgColor
            label.font = .preferredFont(forTextStyle: .caption1); label.adjustsFontForContentSizeCategory = true; label.textColor = .secondaryLabel; label.numberOfLines = 2; label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            retry.configuration = nil; retry.setTitleColor(.systemPurple, for: .normal)
            retry.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
            retry.titleLabel?.numberOfLines = 1
            retry.setContentCompressionResistancePriority(.required, for: .horizontal)
            retry.contentHorizontalAlignment = .leading
            retry.setTitle(localized("session_progress.retry"), for: .normal)
            retry.addTarget(self, action: #selector(retryWork), for: .touchUpInside)
            close.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)), for: .normal)
            close.tintColor = .tertiaryLabel; close.backgroundColor = .tertiarySystemFill; close.layer.cornerRadius = 13
            close.accessibilityLabel = localized("session_progress.dismiss")
            close.addTarget(self, action: #selector(dismissPanel), for: .touchUpInside)
            let indicators = UIStackView(arrangedSubviews: [spinner, statusIcon]); indicators.axis = .horizontal; indicators.alignment = .center
            spinner.color = .systemPurple; statusIcon.contentMode = .scaleAspectFit
            let stack = UIStackView(arrangedSubviews: [indicators, label, retry, close]); stack.axis = .horizontal; stack.spacing = 8; stack.alignment = .center
            stack.translatesAutoresizingMaskIntoConstraints = false; box.addSubview(stack); host.addSubview(box)
            NSLayoutConstraint.activate([box.centerXAnchor.constraint(equalTo: anchor.safeAreaLayoutGuide.centerXAnchor),
                box.leadingAnchor.constraint(greaterThanOrEqualTo: anchor.safeAreaLayoutGuide.leadingAnchor, constant: 12),
                box.trailingAnchor.constraint(lessThanOrEqualTo: anchor.safeAreaLayoutGuide.trailingAnchor, constant: -12),
                box.widthAnchor.constraint(lessThanOrEqualToConstant: 300),
                box.topAnchor.constraint(equalTo: anchor.safeAreaLayoutGuide.topAnchor, constant: 12),
                stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12), stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -4),
                stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 4), stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -4),
                indicators.widthAnchor.constraint(equalToConstant: 20), statusIcon.heightAnchor.constraint(equalToConstant: 18), statusIcon.widthAnchor.constraint(equalToConstant: 18),
                close.widthAnchor.constraint(equalToConstant: 32), close.heightAnchor.constraint(equalToConstant: 32), retry.heightAnchor.constraint(equalToConstant: 32)])
            panel = box
        }
        let working = state.status == "running"
        let key = working ? (state.phase == "restoring_page" ? "restoring_page" : state.phase == "preparing" ? "preparing" : "syncing") : state.status == "partial" ? "partial" : "done"
        if state.isChannelReadiness {
            if working && state.phase == "preparing" {
                label.text = localized("session_progress.preparing")
            } else if let total = state.totalChannels, state.phase != "inventory" {
                let countKey = state.status == "partial" ? "channels_partial" : state.status == "done" ? "channels_done" : "channels_syncing"
                label.text = String(format: localized("session_progress." + countKey), state.readyChannels, total)
            } else {
                label.text = localized("session_progress." + (state.status == "partial" ? "inventory_partial" : "inventory"))
            }
        } else { label.text = localized("session_progress." + key) }
        label.accessibilityLabel = label.text
        spinner.isAccessibilityElement = false; statusIcon.isAccessibilityElement = false
        retry.isHidden = working || state.status != "partial"
        spinner.isHidden = !working; statusIcon.isHidden = working
        if working { spinner.startAnimating() } else {
            spinner.stopAnimating()
            statusIcon.image = UIImage(systemName: state.status == "partial" ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
            statusIcon.tintColor = state.status == "partial" ? .systemOrange : .systemGreen
        }
        if state.status == "done", timerCycle != state.cycleId {
            let completedCycle = state.cycleId, completedOwner = owner, token = UUID()
            timerToken = token; timerCycle = completedCycle
            let task = DispatchWorkItem { [weak self] in
                guard let self, self.timerToken == token, self.owner === completedOwner,
                      self.owner?.snapshot?.cycleId == completedCycle, self.owner?.snapshot?.status == "done" else { return }
                self.dismissed = completedCycle; self.panel?.removeFromSuperview(); self.panel = nil
            }
            completionTimer = task
            scheduleCompletion { task.perform() }
        }
        panel?.accessibilityIdentifier = "session-progress-" + state.cycleId.uuidString
    }
    @objc func dismissPanel() { completionTimer?.cancel(); timerToken = UUID(); dismissed = cycle; panel?.removeFromSuperview(); panel = nil }
    @objc func retryWork() { owner?.retry() }
}
