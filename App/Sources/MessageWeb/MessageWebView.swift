#if os(macOS)
import AppKit
import os
import WebKit
import MailternalSanitizer

/// Failure to install the categorical `WKContentRuleList` network fence.
public struct MessageWebIsolationError: Error, LocalizedError, Sendable {
    public let reason: String
    public var errorDescription: String? { reason }
}

/// Isolated HTML message surface (spec: `docs/spec/sync.md` HTML isolation).
///
/// JavaScript is off, website data is nonpersistent, a compiled content-rule
/// list blocks every network load, and the only subresource scheme the page
/// may use is `mailternal-part:`. User-activated links are forwarded to
/// ``onExternalLink`` and never loaded in-view. Revealing remote images does
/// not lift the content-rule block — consented tokens become fetchable
/// through the scheme handler only.
///
/// If the content-rule list fails to compile, HTML is never loaded (fail closed).
@MainActor
public final class MessageWebView: NSView, WKNavigationDelegate, WKUIDelegate {
    /// Invoked for user-activated links (http(s), mailto, …). Never loaded in-view.
    public var onExternalLink: ((URL) -> Void)?
    /// Invoked if the categorical network fence cannot be installed.
    public var onError: ((any Error) -> Void)?

    private let webView: WKWebView
    private let errorLabel: NSTextField
    private let handler: PartSchemeHandler
    private let userContentController: WKUserContentController
    private var remoteImagesAllowed = false
    private var lastHTML = ""
    /// Identity last loaded or queued. Skip `loadHTMLString` when unchanged.
    private var lastHTMLIdentity: DisplayedHTMLIdentity?
    private var lastProvider: PartProvider?
    private var fence: NetworkFenceState = .compiling
    private var pendingRender = false

    private static let isolationLog = Logger(
        subsystem: "org.kayg.mailternal",
        category: "HTMLIsolation"
    )

    public override init(frame: NSRect) {
        let handler = PartSchemeHandler()
        let userContentController = WKUserContentController()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController = userContentController
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptEnabled = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isFraudulentWebsiteWarningEnabled = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.setURLSchemeHandler(handler, forURLScheme: PartURL.scheme)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let errorLabel = NSTextField(wrappingLabelWithString: "")
        errorLabel.isSelectable = true
        errorLabel.alignment = .center
        errorLabel.textColor = .secondaryLabelColor
        errorLabel.isHidden = true
        self.handler = handler
        self.userContentController = userContentController
        self.webView = webView
        self.errorLabel = errorLabel
        super.init(frame: frame)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.underPageBackgroundColor = .clear
        webView.autoresizingMask = [.width, .height]
        webView.frame = bounds
        errorLabel.autoresizingMask = [.width, .height]
        errorLabel.frame = bounds.insetBy(dx: 24, dy: 24)
        addSubview(webView)
        addSubview(errorLabel)
        installNetworkBlockList()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    public override func layout() {
        super.layout()
        webView.frame = bounds
        errorLabel.frame = bounds.insetBy(dx: 24, dy: 24)
    }

    /// Display already-sanitized HTML. `partProvider` is called with the original
    /// reference (`cid:…` or an absolute `http(s)` URL) for each
    /// `mailternal-part://` token the page requests. Remote tokens are not
    /// fetched until ``setRemoteImagesAllowed(_:)`` is `true`.
    ///
    /// SwiftUI `updateNSView` may call this on every observation tick. Identical
    /// `(html hash, remoteAllowed)` is a no-op: no `loadHTMLString`, so scroll
    /// and in-flight `mailternal-part://` fetches are preserved. Provider is
    /// still swapped. Remote-consent changes go through
    /// ``setRemoteImagesAllowed(_:)``, not a fresh render.
    public func render(
        html: String,
        partProvider: @escaping @Sendable (String) async throws -> (data: Data, mimeType: String)
    ) {
        lastProvider = partProvider
        handler.update(provider: partProvider, remoteAllowed: remoteImagesAllowed)
        let next = HTMLRenderIdempotence.identity(html: html, remoteAllowed: remoteImagesAllowed)
        if HTMLRenderIdempotence.action(displayed: lastHTMLIdentity, next: next) == .skip {
            return
        }
        lastHTML = html
        lastHTMLIdentity = next
        requestLoad()
    }

    /// Re-render so consented remote tokens become fetchable through the scheme
    /// handler. The categorical network content-rule block stays active.
    /// Does not go through ``render(html:partProvider:)``.
    public func setRemoteImagesAllowed(_ allowed: Bool) {
        guard allowed != remoteImagesAllowed else { return }
        remoteImagesAllowed = allowed
        handler.setRemoteAllowed(allowed)
        guard lastProvider != nil else { return }
        let next = HTMLRenderIdempotence.identity(html: lastHTML, remoteAllowed: allowed)
        if HTMLRenderIdempotence.action(displayed: lastHTMLIdentity, next: next) == .skip {
            return
        }
        lastHTMLIdentity = next
        requestLoad()
    }

    /// In-page find via `WKWebView.find`. JavaScript stays off.
    /// Empty `query` clears the highlight. Always case-insensitive and wrapping.
    @discardableResult
    public func findInPage(_ query: String, backwards: Bool = false) async -> Bool {
        lastFindQuery = query
        lastFindBackwards = backwards
        return await performFind()
    }

    private var lastFindQuery = ""
    private var lastFindBackwards = false

    private func performFind() async -> Bool {
        let configuration = WKFindConfiguration()
        configuration.backwards = lastFindBackwards
        configuration.caseSensitive = false
        configuration.wraps = true
        let result = await webView.find(lastFindQuery, configuration: configuration)
        return result.matchFound
    }

    private func requestLoad() {
        switch HTMLIsolationFence.decision(for: fence) {
        case .waitForFence:
            pendingRender = true
        case .loadHTML:
            pendingRender = false
            errorLabel.isHidden = true
            webView.isHidden = false
            webView.loadHTMLString(Self.wrap(lastHTML), baseURL: nil)
        case .refuseHTML:
            pendingRender = false
            presentFenceFailure()
        }
    }

    private func presentFenceFailure() {
        webView.stopLoading()
        webView.isHidden = true
        if let blank = URL(string: "about:blank") {
            webView.load(URLRequest(url: blank))
        }
        errorLabel.stringValue =
            "This message cannot be displayed because the network isolation layer failed to install."
        errorLabel.isHidden = false
    }

    private func installNetworkBlockList() {
        let json = Self.blockListJSON
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "mailternal.block-all.v1",
            encodedContentRuleList: json
        ) { [weak self] list, error in
            let compileReason = error.map { $0.localizedDescription }
            Task { @MainActor in
                guard let self else { return }
                self.fence = HTMLIsolationFence.state(compiledList: list != nil)
                if let list {
                    self.userContentController.add(list)
                } else {
                    let reason = compileReason
                        ?? "WKContentRuleList compile returned nil"
                    let failure = MessageWebIsolationError(reason: reason)
                    Self.isolationLog.error(
                        "Content-rule compile failed; refusing to load HTML. \(reason, privacy: .public)"
                    )
                    self.onError?(failure)
                }
                if self.pendingRender {
                    self.requestLoad()
                }
            }
        }
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        preferences.allowsContentJavaScript = false
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel, preferences)
            return
        }
        if isInternalDocumentLoad(navigationAction, url: url) {
            decisionHandler(.allow, preferences)
            return
        }
        if navigationAction.navigationType == .linkActivated {
            onExternalLink?(url)
        } else if navigationAction.targetFrame == nil, let link = navigationAction.request.url {
            onExternalLink?(link)
        }
        decisionHandler(.cancel, preferences)
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if navigationResponse.isForMainFrame,
           let url = navigationResponse.response.url,
           isInternalURL(url) {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
    }

    public func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    public func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        download.cancel()
    }

    public func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        download.cancel()
    }

    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            onExternalLink?(url)
        }
        return nil
    }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(false)
    }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        completionHandler(nil)
    }

    public func webViewDidClose(_ webView: WKWebView) {}

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !lastFindQuery.isEmpty else { return }
        Task { _ = await performFind() }
    }

    private func isInternalDocumentLoad(_ action: WKNavigationAction, url: URL) -> Bool {
        guard action.navigationType == .other else { return false }
        guard action.targetFrame?.isMainFrame ?? true else { return false }
        return isInternalURL(url)
    }

    private func isInternalURL(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        return scheme == "about" || scheme == "applewebdata"
    }

    /// Reader chrome. Semantic colors only; author colors in the HTML are not remapped.
    /// The 490 pt measure is the viewer's frame; this CSS supplies the 20 pt inset
    /// and body typography from `docs/spec/design.md`.
    private static let readerCSS = """
    html { color-scheme: light dark; background: transparent; }
    body {
      margin: 0; padding: 0 20px;
      font: -apple-system-body;
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
      font-size: 13px; line-height: 18px;
      color: -apple-system-label; background: transparent;
      word-wrap: break-word; overflow-wrap: break-word;
    }
    p { margin: 0 0 10px 0; }
    a { color: -apple-system-link; }
    h1 { font: -apple-system-title2; margin: 0 0 10px 0; }
    h2 { font: -apple-system-title3; margin: 0 0 10px 0; }
    h3, h4 { font: -apple-system-headline; margin: 0 0 10px 0; }
    blockquote {
      margin: 0 0 10px 0; padding: 0 0 0 12px;
      border-left: 2px solid -apple-system-separator;
      color: -apple-system-secondary-label;
    }
    pre, code, kbd, samp { font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 12px; }
    pre { white-space: pre-wrap; }
    img, svg { max-width: 100%; height: auto; }
    table { border-collapse: collapse; max-width: 100%; }
    """

    private static func wrap(_ html: String) -> String {
        let styleTag = "<meta charset=\"utf-8\"><style>\(readerCSS)</style>"
        if let head = html.range(of: "<head", options: .caseInsensitive) {
            var cursor = head.upperBound
            var quote: Character?
            while cursor < html.endIndex {
                let character = html[cursor]
                if let current = quote {
                    if character == current { quote = nil }
                } else if character == "\"" || character == "'" {
                    quote = character
                } else if character == ">" {
                    var output = html
                    output.insert(contentsOf: styleTag, at: html.index(after: cursor))
                    return output
                }
                cursor = html.index(after: cursor)
            }
        }
        return "<!DOCTYPE html><html><head>\(styleTag)</head><body>\(html)</body></html>"
    }

    /// Block every network load. `about:`, `mailternal-part:`, and `data:image/`
    /// are excepted so the initial document, scheme handler, and allowlisted
    /// data-image bytes can still resolve. Direct http(s) never reaches the page.
    private static let blockListJSON = """
    [
      { "trigger": { "url-filter": ".*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": "^about:" }, "action": { "type": "ignore-previous-rules" } },
      { "trigger": { "url-filter": "^applewebdata:" }, "action": { "type": "ignore-previous-rules" } },
      { "trigger": { "url-filter": "^mailternal-part:" }, "action": { "type": "ignore-previous-rules" } },
      { "trigger": { "url-filter": "^data:image/" }, "action": { "type": "ignore-previous-rules" } }
    ]
    """
}
#endif
