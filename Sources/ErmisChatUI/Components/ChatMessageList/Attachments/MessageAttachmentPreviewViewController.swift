//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit
import WebKit

open class MessageAttachmentPreviewViewController: _ViewController, WKNavigationDelegate, UIProvider {
    public var content: Content? {
        didSet { updateContentIfNeeded() }
    }

    public var client: ErmisClient? {
        didSet {
            // The router can provide content before the client. Re-evaluate an already loaded
            // controller so an opaque E2EE URL never falls through to WKWebView.
            guard isViewLoaded else { return }
            contentDidChanged()
        }
    }

    public private(set) lazy var attachmentSaver = client?.attachmentSaver(
        presentingFrom: navigationController?.presentingViewController ?? presentingViewController ?? self
    )

    private var previewResolutionTask: _Concurrency.Task<Void, Never>?
    private var previewOriginalLease: E2eeAttachmentOriginalLease?

    public private(set) lazy var alertRouter = components.alertsRouter.init(rootViewController: self)

    // MARK: - Subviews

    public private(set) lazy var webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "webView")

    public private(set) lazy var activityIndicatorView = UIActivityIndicatorView(style: .gray)
        .withAccessibilityIdentifier(identifier: "activityIndicatorView")

    public private(set) lazy var closeButton = UIBarButtonItem(
        image: theme.icons.close,
        style: .plain,
        target: self,
        action: #selector(close)
    )

    public private(set) lazy var downloadButton = {
        let button = self.components.downloadButton.init()
            .withoutAutoresizingMaskConstraints
            .withAccessibilityIdentifier(identifier: "downloadButton")
        button.addTarget(self, action: #selector(download), for: .touchUpInside)
        return UIBarButtonItem(customView: button)
    }()

    public private(set) lazy var goBackButton = UIBarButtonItem(
        title: "←",
        style: .plain,
        target: self,
        action: #selector(goBack)
    )

    public private(set) lazy var goForwardButton = UIBarButtonItem(
        title: "→",
        style: .plain,
        target: self,
        action: #selector(goForward)
    )

    // MARK: - Life Cycle

    override open func setUpTheme() {
        super.setUpTheme()
        view.backgroundColor = theme.colors.surface
        closeButton.tintColor = theme.colors.text
        downloadButton.tintColor = theme.colors.text
        navigationItem.leftBarButtonItem = closeButton
        navigationItem.rightBarButtonItems = [
            goForwardButton,
            goBackButton,
            downloadButton,
            UIBarButtonItem(customView: activityIndicatorView)
        ]
    }

    override open func setUp() {
        super.setUp()

        webView.navigationDelegate = self
    }

    override open func setUpUI() {
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.pin(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.pin(equalTo: view.leadingAnchor),
            webView.trailingAnchor.pin(equalTo: view.trailingAnchor),
            webView.bottomAnchor.pin(equalTo: view.bottomAnchor)
        ])
    }

    override open func contentDidChanged() {
        previewResolutionTask?.cancel()
        previewResolutionTask = nil
        webView.stopLoading()
        previewOriginalLease?.release()
        previewOriginalLease = nil
        goBackButton.isEnabled = false
        goForwardButton.isEnabled = false
        title = content?.title
        if let channelAttachment = content?.channelAttachment, channelAttachment.attachmentType == .linkPreview {
            downloadButton.isEnabled = false
        } else {
            downloadButton.isEnabled = true
        }

        if let fileAttachment = content?.fileAttachment,
           Self.isOpaqueE2eeURL(fileAttachment.assetURL) {
            resolveE2eeFilePreview(fileAttachment)
        } else if let url = content?.url {
            webView.load(URLRequest(url: url))
        } else {
            activityIndicatorView.stopAnimating()
        }
    }

    // MARK: Actions

    @objc open func goBack() {
        if let item = webView.backForwardList.backItem {
            webView.go(to: item)
        }
    }

    @objc open func goForward() {
        if let item = webView.backForwardList.forwardItem {
            webView.go(to: item)
        }
    }

    @objc open func close() {
        previewResolutionTask?.cancel()
        previewResolutionTask = nil
        webView.stopLoading()
        previewOriginalLease?.release()
        previewOriginalLease = nil
        dismiss(animated: true)
    }

    @objc open func download() {
        downloadButton.isEnabled = false
        let handleDownloadResult: ((Error?) -> Void) = { [weak self] error in
            self?.downloadButton.isEnabled = true
            self?.alertRouter.showDownloadAttachmentAlertResult(isSuccess: error == nil)
        }
        if let channelAttachment = content?.channelAttachment {
            attachmentSaver?.downloadChannelAttachment(attachment: channelAttachment, completion: handleDownloadResult)
        } else if let fileAttachment = content?.fileAttachment {
            let attachment = fileAttachment.asAnyAttachment
            guard let client, client.requiresVerifiedE2eeOriginal(attachment) else {
                attachmentSaver?.downloadAttachments(attachments: [attachment], completion: handleDownloadResult)
                return
            }
            guard let attachmentSaver else {
                handleDownloadResult(ClientError.Unknown("Attachment saver is unavailable"))
                return
            }

            // Save is an explicit action and owns an independent requester. It is intentionally
            // not tied to the preview task, so closing the preview does not discard a requested
            // export after its verified plaintext is ready.
            _Concurrency.Task { [weak self, client, attachmentSaver] in
                do {
                    let lease = try await client.acquireAttachmentForViewing(attachment)
                    try _Concurrency.Task.checkCancellation()
                    attachmentSaver.saveVerifiedAttachment(
                        at: lease.localURL,
                        attachment: attachment,
                        completion: { error in
                            lease.release()
                            handleDownloadResult(error)
                        }
                    )
                } catch {
                    log.error("[E2EE_FILE_PREVIEW] operation=save state=failed error=\(type(of: error))")
                    DispatchQueue.main.async {
                        self?.downloadButton.isEnabled = true
                        handleDownloadResult(error)
                    }
                }
            }
        } else {
            handleDownloadResult(ClientError.Unknown("Attachment not valid for download"))
        }
    }

    private func resolveE2eeFilePreview(_ fileAttachment: MessageFileAttachment) {
        guard let client else {
            // Client assignment is allowed to arrive after content assignment. Keep the opaque
            // reference inert until the router supplies the authenticated resolver.
            activityIndicatorView.stopAnimating()
            downloadButton.isEnabled = false
            return
        }

        let attachment = fileAttachment.asAnyAttachment
        activityIndicatorView.startAnimating()
        downloadButton.isEnabled = true
        previewResolutionTask = _Concurrency.Task { [weak self, client] in
            do {
                let lease = try await client.acquireAttachmentForViewing(attachment)
                try _Concurrency.Task.checkCancellation()
                await MainActor.run {
                    guard let self else {
                        lease.release()
                        return
                    }
                    self.previewResolutionTask = nil
                    self.previewOriginalLease?.release()
                    self.previewOriginalLease = lease
                    self.webView.loadFileURL(
                        lease.localURL,
                        allowingReadAccessTo: lease.localURL.deletingLastPathComponent()
                    )
                }
            } catch is CancellationError {
                await MainActor.run {
                    self?.previewResolutionTask = nil
                    self?.activityIndicatorView.stopAnimating()
                }
            } catch {
                log.error("[E2EE_FILE_PREVIEW] operation=preview state=failed error=\(type(of: error))")
                await MainActor.run {
                    self?.previewResolutionTask = nil
                    self?.activityIndicatorView.stopAnimating()
                }
            }
        }
    }

    static func isOpaqueE2eeURL(_ url: URL?) -> Bool {
        url?.scheme?.lowercased() == "ermis-e2ee-attachment"
    }

    // MARK: - WKNavigationDelegate

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        activityIndicatorView.startAnimating()
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard !Self.isOpaqueE2eeURL(navigationAction.request.url) else {
            log.error("[E2EE_FILE_PREVIEW] operation=navigation state=blocked_opaque_url")
            activityIndicatorView.stopAnimating()
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        activityIndicatorView.stopAnimating()

        webView.evaluateJavaScript("document.title") { data, _ in
            if let title = data as? String, !title.isEmpty {
                self.title = title
            }
        }

        goBackButton.isEnabled = webView.canGoBack
        goForwardButton.isEnabled = webView.canGoForward
    }

    public func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        activityIndicatorView.stopAnimating()
    }

    deinit {
        previewResolutionTask?.cancel()
        previewOriginalLease?.release()
    }
}

public extension MessageAttachmentPreviewViewController {
    struct Content {
        public let channelAttachment: ChannelAttachmentPayload?
        public let fileAttachment: MessageFileAttachment?

        public var title: String? {
            return channelAttachment?.fileName ?? fileAttachment?.title
        }

        public var url: URL? {
            if let channelAttachment = channelAttachment {
                return URL(string: channelAttachment.url ?? "")
            }
            return fileAttachment?.assetURL
        }

        public init(channelAttachment: ChannelAttachmentPayload?) {
            self.channelAttachment = channelAttachment
            fileAttachment = nil
        }

        public init(fileAttachment: MessageFileAttachment?) {
            self.fileAttachment = fileAttachment
            channelAttachment = nil
        }
    }
}
