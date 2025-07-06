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

    public var client: ErmisClient?

    public private(set) lazy var attachmentSaver = client?.attachmentSaver(presentingFrom: self)

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
        goBackButton.isEnabled = false
        goForwardButton.isEnabled = false
        title = content?.title
        if let channelAttachment = content?.channelAttachment, channelAttachment.attachmentType == .linkPreview {
            downloadButton.isEnabled = false
        } else {
            downloadButton.isEnabled = true
        }

        if let url = content?.url {
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
            attachmentSaver?.downloadAttachments(attachments: [fileAttachment.asAnyAttachment], completion: handleDownloadResult)
        } else {
            handleDownloadResult(ClientError.Unknown("Attachment not valid for download"))
        }
    }

    // MARK: - WKNavigationDelegate

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        activityIndicatorView.startAnimating()
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
