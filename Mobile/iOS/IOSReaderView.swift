import SwiftUI
import UIKit
import WebKit
import MailternalInterfaces
import MailternalSanitizer

struct IOSReaderView: View {
    @Bindable var state: IOSAppState
    @State private var section: ReaderSection = .body
    @State private var showHeaders = false
    @State private var renderedHTML: String?
    @State private var rawSource: String?
    @State private var isLoadingRaw = false
    @State private var attachmentURLs: [String: URL] = [:]
    @State private var loadingAttachment: String?
    @State private var attachmentTasks: [String: Task<Void, Never>] = [:]
    @State private var attachmentGenerations: [String: UInt64] = [:]
    // Do not reuse a generation after switching away and back to a message.
    @State private var nextAttachmentGeneration: UInt64 = 0
    @State private var rawSourceTask: Task<Void, Never>?
    @State private var htmlIsolationError: String?
    enum ReaderSection: String, CaseIterable, Identifiable {
        case body
        case headers
        case source
        var id: String { rawValue }
        var title: String {
            switch self { case .body: "Message"; case .headers: "Headers"; case .source: "Raw Source" }
        }
    }

    var body: some View {
        Group {
            if state.isLoadingDetail {
                ProgressView("Loading message…")
            } else if let detail = state.detail {
                reader(detail)
            } else {
                ContentUnavailableView {
                    Label("No message selected", systemImage: "envelope.open")
                } description: {
                    Text("Choose a message to read it here.")
                }
            }
        }
        .navigationTitle(state.detail?.envelope.subject.isEmpty == false ? state.detail?.envelope.subject ?? "Reader" : "Reader")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { Task { await state.openAdjacent(delta: -1) } } label: { Label("Previous", systemImage: "chevron.up") }
                    .disabled(!state.canNavigatePrevious)
                Button { Task { await state.openAdjacent(delta: 1) } } label: { Label("Next", systemImage: "chevron.down") }
                    .disabled(!state.canNavigateNext)
                Menu {
                    Button {
                        let flagged = state.selectedMessageIsFlagged
                        let ids = state.selectedMessageID.map { Set([$0]) } ?? []
                        Task { await state.setFlagged(!flagged, ids: ids) }
                    } label: {
                        Label(
                            state.selectedMessageIsFlagged ? "Unflag" : "Flag",
                            systemImage: state.selectedMessageIsFlagged ? "flag.slash" : "flag"
                        )
                    }
                    Button { Task { await state.archiveSelected(state.selectedMessageID.map { Set([$0]) }) } } label: { Label("Archive", systemImage: "archivebox") }
                    Button(role: .destructive) { Task { await state.trashSelected(state.selectedMessageID.map { Set([$0]) }) } } label: { Label("Trash", systemImage: "trash") }
                    Divider()
                    Button("Refresh") { Task { await state.refresh() } }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                .disabled(state.selectedMessageID == nil)
            }
        }
        .onChange(of: state.selectedMessageID) { _, _ in
            section = .body
            showHeaders = false
            rawSourceTask?.cancel()
            rawSourceTask = nil
            attachmentTasks.values.forEach { $0.cancel() }
            attachmentTasks.removeAll()
            attachmentGenerations.removeAll()
            rawSource = nil
            isLoadingRaw = false
            loadingAttachment = nil
            attachmentURLs.removeAll()
            renderedHTML = nil
            htmlIsolationError = nil
        }

    }
    @ViewBuilder
    private func reader(_ detail: MessageDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(detail.envelope.subject.isEmpty ? "(No subject)" : detail.envelope.subject)
                        .font(.title2.weight(.semibold))
                        .textSelection(.enabled)
                    HStack(spacing: 8) {
                        Text(detail.envelope.internalDate, format: .dateTime.month(.abbreviated).day().year().hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if detail.isQuarantined {
                            Label("Message body quarantined", systemImage: "exclamationmark.shield")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                IOSEnvelopeView(envelope: detail.envelope, expanded: $showHeaders)
                Picker("Reader section", selection: $section) {
                    ForEach(ReaderSection.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Reader section")
                switch section {
                case .body:
                    bodyView(detail)
                case .headers:
                    IOSHeaderList(envelope: detail.envelope)
                case .source:
                    rawSourceView
                }
                if section == .body, !detail.attachments.isEmpty {
                    IOSAttachmentsView(
                        attachments: detail.attachments,
                        urls: attachmentURLs,
                        loadingID: loadingAttachment,
                        fetch: { attachment in
                            let messageID = detail.id
                            attachmentTasks[attachment.id]?.cancel()
                            nextAttachmentGeneration &+= 1
                            let generation = nextAttachmentGeneration
                            attachmentGenerations[attachment.id] = generation
                            loadingAttachment = attachment.id
                            let task = Task { @MainActor in
                                defer {
                                    if attachmentGenerations[attachment.id] == generation {
                                        attachmentTasks[attachment.id] = nil
                                        if loadingAttachment == attachment.id {
                                            loadingAttachment = nil
                                        }
                                    }
                                }
                                let url = await state.fetchAttachment(attachment, for: messageID)
                                guard !Task.isCancelled,
                                      attachmentGenerations[attachment.id] == generation,
                                      state.selectedMessageID == messageID else { return }
                                if let url { attachmentURLs[attachment.id] = url }
                            }
                            attachmentTasks[attachment.id] = task
                        }
                    )
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color(uiColor: .systemBackground))
        .task(id: detail.id) {
            let messageID = detail.id
            let html = await state.renderedHTML(for: detail)
            guard !Task.isCancelled, state.selectedMessageID == messageID else { return }
            renderedHTML = html
        }
    }

    @ViewBuilder
    private func bodyView(_ detail: MessageDetail) -> some View {
        if detail.hasRemoteImageReferences && !state.remoteImagesAllowed.contains(detail.id) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "photo.on.rectangle.angled")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Remote images are blocked")
                        .font(.subheadline.weight(.semibold))
                    Text("Loading them can reveal when and where this message is opened.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Load Remote Images") { state.setRemoteImagesAllowed(true) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .padding(14)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        if detail.isQuarantined {
            VStack(alignment: .leading, spacing: 8) {
                Label("Message body quarantined", systemImage: "exclamationmark.shield")
                    .font(.subheadline.weight(.semibold))
                Text("Mailternal kept this message quarantined so it cannot stall the folder. Inspect the capped raw source to view its contents as plain text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Inspect Capped Raw Source") { section = .source }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(uiColor: .secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else if let html = renderedHTML ?? detail.sanitizedHTML, !html.isEmpty {
            if let htmlIsolationError {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Message body unavailable", systemImage: "exclamationmark.shield")
                        .font(.subheadline.weight(.semibold))
                    Text(htmlIsolationError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color(uiColor: .secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                IOSMessageHTMLView(
                    html: html,
                    messageID: detail.id,
                    readingMode: state.readingMode,
                    blocksRemoteImages: detail.hasRemoteImageReferences && !state.remoteImagesAllowed.contains(detail.id),
                    partProvider: partProvider(for: detail),
                    onIsolationStateChange: { message in
                        guard state.selectedMessageID == detail.id else { return }
                        htmlIsolationError = message
                    }
                )
                .frame(minHeight: 180)
            }
        } else if let text = detail.bodyText, !text.isEmpty {
            Text(text)
                .font(.body)
                .lineSpacing(4)
                .textSelection(.enabled)
                .textCase(nil)
        } else {
            Text("This message has no locally stored body.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var rawSourceView: some View {
        if let rawSource {
            ScrollView(.horizontal) {
                Text(rawSource)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            VStack(spacing: 10) {
                Text("The capped raw source is fetched only when requested.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button(isLoadingRaw ? "Loading…" : "Load Raw Source") {
                    guard let messageID = state.selectedMessageID else { return }
                    rawSourceTask?.cancel()
                    isLoadingRaw = true
                    let task = Task { @MainActor in
                        defer {
                            if state.selectedMessageID == messageID {
                                isLoadingRaw = false
                            }
                            rawSourceTask = nil
                        }
                        let source = await state.rawSource(for: messageID)
                        guard !Task.isCancelled,
                              state.selectedMessageID == messageID else { return }
                        rawSource = source
                    }
                    rawSourceTask = task
                }
                .buttonStyle(.borderedProminent)
                .disabled(isLoadingRaw)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        }
    }

    private func partProvider(for detail: MessageDetail) -> PartProvider {
        let fetcher = IOSMailFacadePartFetch(facade: state.facade, messageID: detail.id, attachments: detail.attachments)
        return { reference in
            try await PartFetchRouting.dispatch(
                reference: reference,
                imap: { part in try await fetcher.fetch(part: part) },
                remote: { url in try await RemoteImageFetch.load(url) }
            )
        }
    }

}

private struct IOSEnvelopeView: View {
    let envelope: Envelope
    @Binding var expanded: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Text("From").font(.caption).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
                Text(addresses(envelope.from)).font(.subheadline).textSelection(.enabled)
                Spacer()
            }
            HStack(alignment: .top, spacing: 10) {
                Text("To").font(.caption).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
                Text(addresses(envelope.to)).font(.subheadline).textSelection(.enabled)
                Spacer()
            }
            if expanded {
                if !envelope.cc.isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        Text("Cc").font(.caption).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
                        Text(addresses(envelope.cc)).font(.subheadline).textSelection(.enabled)
                    }
                }
                if !envelope.replyTo.isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        Text("Reply-To").font(.caption).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
                        Text(addresses(envelope.replyTo)).font(.subheadline).textSelection(.enabled)
                    }
                }
                if let headerDate = envelope.headerDate {
                    HStack(spacing: 10) {
                        Text("Date").font(.caption).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
                        Text(headerDate.formatted(date: .complete, time: .shortened)).font(.subheadline)
                    }
                }
            }
            Button(expanded ? "Hide details" : "Show details") { expanded.toggle() }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func addresses(_ values: [MailAddress]) -> String {
        values.map { address in
            if let name = address.displayName, !name.isEmpty { return "\(name) <\(address.address)>" }
            return address.address
        }.joined(separator: ", ")
    }
}

private struct IOSHeaderList: View {
    let envelope: Envelope
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("Subject", envelope.subject)
            header("From", envelope.from.map(\.address).joined(separator: ", "))
            header("To", envelope.to.map(\.address).joined(separator: ", "))
            if !envelope.cc.isEmpty { header("Cc", envelope.cc.map(\.address).joined(separator: ", ")) }
            if let date = envelope.headerDate { header("Date", date.formatted(date: .complete, time: .shortened)) }
            if let messageID = envelope.rfcMessageID { header("Message-ID", messageID) }
            if let inReplyTo = envelope.inReplyTo { header("In-Reply-To", inReplyTo) }
            if !envelope.references.isEmpty { header("References", envelope.references.joined(separator: " ")) }
        }
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func header(_ name: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(name).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
            Text(value).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct IOSAttachmentsView: View {
    let attachments: [AttachmentInfo]
    let urls: [String: URL]
    let loadingID: String?
    let fetch: (AttachmentInfo) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Attachments").font(.headline)
            ForEach(attachments) { attachment in
                HStack(spacing: 10) {
                    Image(systemName: "paperclip")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(attachment.filename ?? "Untitled attachment").font(.subheadline).lineLimit(1)
                        Text(attachment.sizeEstimate.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? attachment.mimeType)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let url = urls[attachment.id] {
                        ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                            .labelStyle(.iconOnly)
                            .accessibilityLabel("Share attachment")
                    } else {
                        Button { fetch(attachment) } label: {
                            if loadingID == attachment.id { ProgressView().controlSize(.small) }
                            else { Image(systemName: "arrow.down.circle") }
                        }
                        .accessibilityLabel("Download attachment")
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }
}


private struct IOSMailFacadePartFetch: @unchecked Sendable {
    let facade: any MailFacade
    let messageID: MessageID
    let attachments: [AttachmentInfo]

    func fetch(part: String) async throws -> (data: Data, mimeType: String) {
        let url = try await facade.fetchAttachment(messageID, part: part)
        let data = try Data(contentsOf: url)
        let mime = AttachmentMIME.declared(
            for: part,
            attachments: attachments.map { ($0.id, $0.mimeType, $0.contentID) }
        ) ?? "application/octet-stream"
        return (data, mime)
    }
}

private struct IOSMessageHTMLView: UIViewRepresentable {
    let html: String
    let messageID: MessageID
    let readingMode: IOSReadingMode
    let blocksRemoteImages: Bool
    let partProvider: PartProvider
    let onIsolationStateChange: (String?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onIsolationStateChange: onIsolationStateChange)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = false
        configuration.defaultWebpagePreferences = preferences
        let handler = PartSchemeHandler()
        handler.update(provider: partProvider, remoteAllowed: !blocksRemoteImages)
        configuration.setURLSchemeHandler(handler, forURLScheme: PartURL.scheme)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        context.coordinator.handler = handler
        context.coordinator.webView = view
        load(view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.handler?.update(provider: partProvider, remoteAllowed: !blocksRemoteImages)
        context.coordinator.onIsolationStateChange = onIsolationStateChange
        guard context.coordinator.lastMessageID != messageID
                || context.coordinator.lastHTML != html
                || context.coordinator.lastMode != readingMode
                || context.coordinator.lastBlocks != blocksRemoteImages else { return }
        load(view, coordinator: context.coordinator)
    }

    private func load(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.lastMessageID = messageID
        coordinator.lastHTML = html
        coordinator.lastMode = readingMode
        coordinator.lastBlocks = blocksRemoteImages
        coordinator.loadGeneration &+= 1
        let generation = coordinator.loadGeneration
        let canvas = readingMode == .dark ? "#101114" : "#ffffff"
        let foreground = readingMode == .dark ? "#f2f3f5" : "#16181d"
        let styled = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1.0"><style>
        :root { color-scheme: \(readingMode == .dark ? "dark" : "light"); }
        html, body { background: \(canvas); color: \(foreground); font: -apple-system-body; line-height: 1.45; margin: 0; padding: 0; }
        img { max-width: 100%; height: auto; }
        a { color: -webkit-link; }
        </style></head><body>\(html)</body></html>
        """
        // Do not leave the previous message visible while the new fence
        // compiles; the reader must never show stale body content.
        view.isHidden = true
        view.stopLoading()
        view.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: nil)
        view.configuration.userContentController.removeAllContentRuleLists()
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "mailternal-ios-network-fence",
            encodedContentRuleList: Self.networkBlockList
        ) { [weak coordinator] list, error in
            let errorDescription = error?.localizedDescription
            Task { @MainActor [weak coordinator] in
                guard let coordinator, let view = coordinator.webView else { return }
                guard coordinator.loadGeneration == generation,
                      coordinator.lastMessageID == messageID,
                      coordinator.lastHTML == html,
                      coordinator.lastMode == readingMode,
                      coordinator.lastBlocks == blocksRemoteImages else { return }
                guard let list else {
                    coordinator.onIsolationStateChange(
                        errorDescription
                            ?? "The message security fence could not be installed."
                    )
                    return
                }
                view.configuration.userContentController.add(list)
                coordinator.onIsolationStateChange(nil)
                view.loadHTMLString(styled, baseURL: nil)
                view.isHidden = false
            }
        }
    }

    private static let networkBlockList = """
    [
      { "trigger": { "url-filter": ".*", "resource-type": ["document", "image", "style-sheet", "script", "font", "media", "raw", "svg-document", "popup", "ping", "fetch", "websocket", "other"] }, "action": { "type": "block" } },
      { "trigger": { "url-filter": "^about:" }, "action": { "type": "ignore-previous-rules" } },
      { "trigger": { "url-filter": "^applewebdata:" }, "action": { "type": "ignore-previous-rules" } },
      { "trigger": { "url-filter": "^mailternal-part:" }, "action": { "type": "ignore-previous-rules" } },
      { "trigger": { "url-filter": "^data:image/" }, "action": { "type": "ignore-previous-rules" } }
    ]
    """

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var lastMessageID: MessageID?
        var lastHTML: String?
        var lastMode: IOSReadingMode?
        var lastBlocks: Bool?
        var loadGeneration: UInt64 = 0
        var handler: PartSchemeHandler?
        weak var webView: WKWebView?
        var onIsolationStateChange: (String?) -> Void

        init(onIsolationStateChange: @escaping (String?) -> Void) {
            self.onIsolationStateChange = onIsolationStateChange
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            let scheme = url.scheme?.lowercased()
            if navigationAction.navigationType == .linkActivated {
                guard scheme == "http" || scheme == "https" || scheme == "mailto" else {
                    decisionHandler(.cancel)
                    return
                }
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            let isInternal = scheme == nil
                || scheme == "about"
                || scheme == "applewebdata"
                || scheme == PartURL.scheme
                || (scheme == "data" && url.absoluteString.lowercased().hasPrefix("data:image/"))
            decisionHandler(isInternal ? .allow : .cancel)
        }

        func webView(
            _ webView: WKWebView,
            contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
            completionHandler: @escaping @MainActor @Sendable (UIContextMenuConfiguration?) -> Void
        ) {
            guard let link = elementInfo.linkURL else {
                completionHandler(nil)
                return
            }
            let configuration = UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { suggestedActions in
                let linkActions: [UIMenuElement] = [
                    UIAction(title: "Open Link", image: UIImage(systemName: "safari")) { _ in
                        UIApplication.shared.open(link)
                    },
                    UIAction(title: "Copy Link", image: UIImage(systemName: "doc.on.doc")) { _ in
                        UIPasteboard.general.url = link
                    }
                ]
                return UIMenu(
                    title: "",
                    children: linkActions + Self.textSelectionActions(from: suggestedActions)
                )
            }
            completionHandler(configuration)
        }

        private static func textSelectionActions(from elements: [UIMenuElement]) -> [UIMenuElement] {
            elements.compactMap { element in
                if let action = element as? UIAction {
                    guard !action.attributes.contains(.disabled) else { return nil }
                    let title = action.title
                    guard title == "Copy"
                        || title == "Share"
                        || title == "Services"
                        || title.hasPrefix("Look Up")
                        || title.hasPrefix("Search")
                        || title.hasPrefix("Translate") else { return nil }
                    return action
                }
                if let menu = element as? UIMenu,
                   !textSelectionActions(from: menu.children).isEmpty {
                    return menu
                }
                return nil
            }
        }
    }
}
