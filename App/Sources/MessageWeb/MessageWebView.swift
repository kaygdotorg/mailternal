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
    /// Reports the rendered document height so an outer reader can own scrolling.
    public var onContentHeightChange: ((CGFloat) -> Void)?

    private let webView: WKWebView
    private let errorLabel: NSTextField
    private let handler: PartSchemeHandler
    private let userContentController: WKUserContentController
    private var remoteImagesAllowed = false
    private var lastHTML = ""
    /// Identity last loaded or queued. Skip `loadHTMLString` when unchanged.
    private var lastHTMLIdentity: DisplayedHTMLIdentity?
    private var lastProvider: PartProvider?
    private var emailReadingMode: EmailReadingMode = .original
    private var pendingRender = false
    private var fence: NetworkFenceState = .compiling
    private var lastReportedContentHeight: CGFloat?
    /// The last height that completed a settle pass. During a new render or
    /// width change, provisional measurements may grow this value but never
    /// shrink below it until the document has settled.
    private var documentDidFinish = false
    private var lastMeasuredWidth: CGFloat?
    private var contentHeightTask: Task<Void, Never>?
    private var contentHeightMeasurementGeneration: UInt64 = 0
    #if DEBUG
    private var qaRenderSequence: UInt64 = 0
    #endif

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
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isFraudulentWebsiteWarningEnabled = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.setURLSchemeHandler(handler, forURLScheme: PartURL.scheme)
        let webView = DocumentWebView(frame: .zero, configuration: configuration)
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
        // macOS WKWebView is opaque by default (isOpaque is get-only here);
        // the mode-driven canvas is enforced via underPageBackgroundColor + CSS.
        webView.underPageBackgroundColor = Self.canvasColor(for: .original)
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
        scheduleContentHeightMeasurementIfNeeded()
    }

    /// Display already-sanitized HTML. `partProvider` is called with the original
    /// reference (`cid:…` or an absolute `http(s)` URL) for each
    /// `mailternal-part://` token the page requests. Remote tokens are not
    /// fetched until ``setRemoteImagesAllowed(_:)`` is `true`.
    ///
    /// SwiftUI `updateNSView` may call this on every observation tick. Identical
    /// `(html hash, remoteAllowed, reading mode)` is a no-op: no
    /// `loadHTMLString`, so scroll and in-flight `mailternal-part://` fetches are
    /// preserved. Provider is still swapped. Remote-consent changes go through
    /// ``setRemoteImagesAllowed(_:)``, not a fresh render.
    public func render(
        html: String,
        partProvider: @escaping @Sendable (String) async throws -> (data: Data, mimeType: String),
        emailReadingMode: EmailReadingMode = .original
    ) {
        lastProvider = partProvider
        handler.update(provider: partProvider, remoteAllowed: remoteImagesAllowed)
        let modeChanged = self.emailReadingMode != emailReadingMode
        self.emailReadingMode = emailReadingMode
        webView.underPageBackgroundColor = Self.canvasColor(for: emailReadingMode)
        let next = HTMLRenderIdempotence.identity(html: html, remoteAllowed: remoteImagesAllowed)
        if HTMLRenderIdempotence.action(displayed: lastHTMLIdentity, next: next) == .skip,
           !modeChanged {
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
        do {
            let result = try await webView.find(lastFindQuery, configuration: configuration)
            return result.matchFound
        } catch {
            return false
        }
    }

    private func requestLoad() {
        switch HTMLIsolationFence.decision(for: fence) {
        case .waitForFence:
            pendingRender = true
        case .loadHTML:
            pendingRender = false
            errorLabel.isHidden = true
            webView.isHidden = false
            invalidateContentHeightMeasurement()
            documentDidFinish = false
            // The host resets its island height when the message changes.
            // A re-render of the same document (reading mode, remote images)
            // keeps the current height until the new measurement lands, so
            // the island never collapses to its floor mid-toggle and the
            // host's async height application cannot reorder a stale zero
            // after the real measurement.
            #if DEBUG
            qaRenderSequence &+= 1
            if ProcessInfo.processInfo.environment["MAILTERNAL_QA"] == "1" {
                QALaunch.log(
                    "selection-perf event=html-requested serial=\(qaRenderSequence) t=\(DispatchTime.now().uptimeNanoseconds)"
                )
            }
            #endif
            webView.loadHTMLString(Self.wrap(lastHTML, emailReadingMode: emailReadingMode), baseURL: nil)
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

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["MAILTERNAL_QA"] == "1" {
            QALaunch.log(
                "selection-perf event=did-finish serial=\(qaRenderSequence) t=\(DispatchTime.now().uptimeNanoseconds)"
            )
        }
        #endif
        documentDidFinish = true
        // WebKit may publish the final content size one run-loop turn after
        // navigation completes. The measurement helper yields once, then
        // coalesces any layout callbacks until this document is stable.
        scheduleContentHeightMeasurementIfNeeded()
        guard !lastFindQuery.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.performFind()
        }
    }

    private func invalidateContentHeightMeasurement() {
        contentHeightMeasurementGeneration &+= 1
        contentHeightTask?.cancel()
        contentHeightTask = nil
        lastMeasuredWidth = nil
        lastReportedContentHeight = nil
    }

    private func scheduleContentHeightMeasurementIfNeeded() {
        guard documentDidFinish, bounds.width > 0 else { return }
        guard lastMeasuredWidth.map({ abs(bounds.width - $0) > 0.5 }) ?? true else { return }
        guard contentHeightTask == nil else { return }

        let expectedWidth = bounds.width
        let generation = contentHeightMeasurementGeneration
        contentHeightTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var rescheduled = false
            defer {
                if !rescheduled, self.contentHeightMeasurementGeneration == generation {
                    self.contentHeightTask = nil
                }
            }

            // A nested table can still be laying out after didFinish. Always
            // sample through a bounded settle window and report the largest
            // reading seen for this load. The reader resets to its floor before
            // every load, so "largest so far" can only ratchet within one
            // document, never across documents.
            let delays: [Duration] = [
                .zero,
                .milliseconds(100),
                .milliseconds(300),
                .milliseconds(1000),
                .milliseconds(2000),
            ]
            var largest: CGFloat = 0

            for delay in delays {
                if delay != .zero {
                    do {
                        try await Task.sleep(for: delay)
                    } catch {
                        return
                    }
                }
                guard !Task.isCancelled,
                      self.contentHeightMeasurementGeneration == generation,
                      self.documentDidFinish,
                      abs(self.bounds.width - expectedWidth) <= 0.5 else {
                    if self.contentHeightMeasurementGeneration == generation,
                       self.documentDidFinish,
                       abs(self.bounds.width - expectedWidth) > 0.5 {
                        rescheduled = true
                        self.contentHeightTask = nil
                        self.scheduleContentHeightMeasurementIfNeeded()
                    }
                    return
                }
                // The root's overflow is propagated to the viewport, so the
                // root box itself keeps its content height; the body's scroll
                // extent covers content that escapes the root (absolutely
                // positioned mail chrome).
                guard let result = try? await self.webView.evaluateJavaScript(
                    "Math.max(document.documentElement.offsetHeight, "
                        + "document.documentElement.scrollHeight, "
                        + "(document.body ? document.body.scrollHeight : 0))"
                ), let number = result as? NSNumber else {
                    continue
                }
                let height = CGFloat(truncating: number)
                guard height.isFinite, height > largest else { continue }
                largest = height
                self.reportContentHeight(largest)
            }
            guard largest > 0 else { return }

            guard abs(self.bounds.width - expectedWidth) <= 0.5 else {
                rescheduled = true
                self.contentHeightTask = nil
                self.scheduleContentHeightMeasurementIfNeeded()
                return
            }
            let resolvedHeight = largest
            self.reportContentHeight(resolvedHeight)
            self.lastMeasuredWidth = expectedWidth
        }
    }

    private func reportContentHeight(_ height: CGFloat) {
        guard height.isFinite, height > 0,
              lastReportedContentHeight.map({ abs(height - $0) > 0.5 }) ?? true else {
            return
        }
        lastReportedContentHeight = height
        onContentHeightChange?(height)
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

    /// Reader chrome. Author colors in the HTML are not remapped, but the
    /// reading canvas is always opaque so authored light or dark text has a
    /// stable surface beneath it.
    /// Matches the dark `NSColor.textBackgroundColor`.
    private static let darkCanvasHex = "#1e1e1e"

    private static func canvasColor(for mode: EmailReadingMode) -> NSColor {
        switch mode {
        case .original:
            .white
        case .dark:
            NSColor(calibratedWhite: 0.117647, alpha: 1)
        }
    }

    private static func readerCSS(for mode: EmailReadingMode) -> String {
        let colorScheme: String
        let canvas: String
        switch mode {
        case .original:
            colorScheme = "light"
            canvas = "#ffffff"
        case .dark:
            colorScheme = "dark"
            canvas = darkCanvasHex
        }
        return """
        /* The canvas lives on html and stays opaque so mail that declares no
           colors is readable; author body/background declarations must win,
           so only color-scheme is forced. */
        html { color-scheme: \(colorScheme) !important; background: \(canvas); height: auto; min-height: 0; }
        body {
          height: auto; min-height: 0; margin: 0; padding: 18px 20px;
          font: -apple-system-body;
          font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
          font-size: 13px; line-height: 18px;
          color: -apple-system-label; background: \(canvas);
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
    }

    private static func wrap(_ html: String, emailReadingMode: EmailReadingMode) -> String {
        let styleTag = "<meta charset=\"utf-8\"><style>\(readerCSS(for: emailReadingMode))</style>"
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

/// The message body is sized to its whole document (see the content-height
/// callback), so it never has anything to scroll vertically itself: the
/// reader is one scroll surface, like Mail. WKWebView still swallows wheel
/// events, so vertical scrolling is handed to the enclosing scroll view.
/// Horizontal deltas stay with the document so wide mail can still be panned.
@MainActor
private final class DocumentWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        let vertical = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
        if vertical, let scrollView = enclosingScrollView {
            scrollView.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}
#endif
