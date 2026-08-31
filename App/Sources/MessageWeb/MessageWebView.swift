#if os(macOS)
import AppKit
import WebKit
import MailternalSanitizer

/// Isolated HTML message surface (spec: `docs/spec/sync.md` HTML isolation).
///
/// JavaScript is off, website data is nonpersistent, a compiled content-rule
/// list blocks every network load, and the only subresource scheme the page
/// may use is `mailternal-part:`. User-activated links are forwarded to
/// ``onExternalLink`` and never loaded in-view. Revealing remote images does
/// not lift the content-rule block — consented tokens become fetchable
/// through the scheme handler only.
@MainActor
public final class MessageWebView: NSView, WKNavigationDelegate, WKUIDelegate {
    /// Invoked for user-activated links (http(s), mailto, …). Never loaded in-view.
    public var onExternalLink: ((URL) -> Void)?

    private let webView: WKWebView
    private let handler: PartSchemeHandler
    private let userContentController: WKUserContentController
    private var remoteImagesAllowed = false
    private var lastHTML = ""
    private var lastProvider: PartProvider?
    private var blockListReady = false
    private var pendingRender = false

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
        self.handler = handler
        self.userContentController = userContentController
        self.webView = webView
        super.init(frame: frame)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.underPageBackgroundColor = .clear
        webView.autoresizingMask = [.width, .height]
        webView.frame = bounds
        addSubview(webView)
        installNetworkBlockList()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    public override func layout() {
        super.layout()
        webView.frame = bounds
    }

    /// Display already-sanitized HTML. `partProvider` is called with the original
    /// reference (`cid:…` or an absolute `http(s)` URL) for each
    /// `mailternal-part://` token the page requests. Remote tokens are not
    /// fetched until ``setRemoteImagesAllowed(_:)`` is `true`.
    public func render(
        html: String,
        partProvider: @escaping @Sendable (String) async throws -> (data: Data, mimeType: String)
    ) {
        lastHTML = html
        lastProvider = partProvider
        handler.update(provider: partProvider, remoteAllowed: remoteImagesAllowed)
        requestLoad()
    }

    /// Re-render so consented remote tokens become fetchable through the scheme
    /// handler. The categorical network content-rule block stays active.
    public func setRemoteImagesAllowed(_ allowed: Bool) {
        guard allowed != remoteImagesAllowed else { return }
        remoteImagesAllowed = allowed
        handler.setRemoteAllowed(allowed)
        if lastProvider != nil {
            requestLoad()
        }
    }

    private func requestLoad() {
        guard blockListReady else {
            pendingRender = true
            return
        }
        pendingRender = false
        webView.loadHTMLString(Self.wrap(lastHTML), baseURL: nil)
    }

    private func installNetworkBlockList() {
        let json = Self.blockListJSON
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "mailternal.block-all.v1",
            encodedContentRuleList: json
        ) { [weak self] list, _ in
            Task { @MainActor in
                guard let self else { return }
                if let list {
                    self.userContentController.add(list)
                }
                self.blockListReady = true
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
