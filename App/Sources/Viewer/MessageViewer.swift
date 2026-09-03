import AppKit
import SwiftUI
import MailternalInterfaces

struct MessageViewer: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var viewerFocus
    @State private var findIndex: Int?
    @State private var findBackwards = false
    @State private var findTick: UInt64 = 0
    @State private var headersStore: MessageHeadersStore
    @State private var htmlContentHeight: CGFloat = 0

    init(model: AppModel) {
        self.model = model
        _headersStore = State(initialValue: MessageHeadersStore(facade: model.facade))
    }
    private var findHaystack: String {
        MessageFind.haystack(
            bodyText: model.detail?.bodyText,
            html: model.detail?.sanitizedHTML,
            raw: model.rawSource,
            showingRaw: model.isShowingRawSource
        )
    }

    private var findSnapshot: MessageFind.Snapshot {
        MessageFind.make(text: findHaystack, query: model.findQuery, index: findIndex)
    }

    private var activeFindQuery: String {
        model.isFindPresented ? model.findQuery : ""
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            content
            if model.isFindPresented {
                FindBar(
                    query: $model.findQuery,
                    matchCount: findSnapshot.count,
                    selectedMatchNumber: findSnapshot.selectedMatchNumber,
                    next: { stepFind(.next) },
                    previous: { stepFind(.previous) },
                    close: { model.isFindPresented = false }
                )
                .padding(.top, 12)
                .padding(.trailing, 16)
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                .zIndex(1)
            }
        }
        .animation(MailMotion.disclosure, value: model.isFindPresented)
        .focusScope(viewerFocus)
        .accessibilityIdentifier(UIIdentifier.messageViewer)
        .onExitCommand {
            if model.isFindPresented {
                model.isFindPresented = false
            }
        }
        .onChange(of: model.findQuery) { _, _ in
            restartFind()
        }
        .onChange(of: model.isShowingRawSource) { _, _ in
            restartFind()
        }
        .onChange(of: model.isFindPresented) { _, presented in
            if presented { restartFind() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let title = MessageReaderStatePolicy.emptyStateTitle(
            selectionCount: model.selectedMessageIDs.count
        ) {
            EmptyMailboxState(
                title: title,
                detail: MessageReaderStatePolicy.emptyStateDetail(
                    selectionCount: model.selectedMessageIDs.count
                ) ?? "Choose one message to read it."
            )
        } else if let detail = model.detail {
            reader(detail)
        } else if model.isLoadingDetail {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyMailboxState(
                title: "No Message Selected",
                detail: "Choose a message from the list to read it."
            )
        }
    }

    /// One scroll owner, two disjoint floating islands: a continuous header
    /// surface (subject, envelope, and source headers) followed by the body.
    /// The web view reports its document height and does not own a scrolling
    /// viewport, so the reader scrolls the whole message as one page.
    private func reader(_ detail: MessageDetail) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: MessageViewerLayoutPolicy.islandSpacing) {
                MessageSubjectRegion(
                    subject: detail.envelope.subject,
                    envelope: detail.envelope,
                    attachments: detail.attachments,
                    messageID: detail.id,
                    headersStore: headersStore,
                    backdropStyle: model.appearance.backdropStyle,
                    showsSenderIcons: model.appearance.showsSenderIcons,
                    isShowingRawSource: model.isShowingRawSource,
                    accent: model.appearance.accent.color
                )
                bodyRegion(detail)
            }
            .padding(.horizontal, MessageViewerLayoutPolicy.horizontalPadding)
            // The first subject glyph retains the old dissolve contract while
            // the card's top edge can softly enter the end of the ramp.
            .padding(
                .top,
                max(
                    MessageViewerLayoutPolicy.readerTopInset()
                        - MessageViewerLayoutPolicy.islandVerticalPadding,
                    0
                )
            )
            .padding(.bottom, MessageViewerLayoutPolicy.bottomPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background {
            ScrollEdgeEffectSuppressor()
        }
        .ignoresSafeArea(.container, edges: .top)
        .mailWindowDissolve(.viewer)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func bodyRegion(_ detail: MessageDetail) -> some View {
        VStack(alignment: .leading, spacing: MessageViewerLayoutPolicy.bodyContentSpacing) {
            if detail.isQuarantined {
                QuarantineBanner(
                    showingRaw: model.isShowingRawSource,
                    loadRaw: { Task { await model.loadRawSource() } }
                )
                .padding(.horizontal, MessageViewerLayoutPolicy.islandContentPadding)
                .padding(.top, MessageViewerLayoutPolicy.islandVerticalPadding)
            }
            bodyContent(detail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .readerIslandSurface(
            role: .body,
            backdropStyle: model.appearance.backdropStyle
        )
        .accessibilityIdentifier(UIIdentifier.messageBody)
    }

    @ViewBuilder
    private func bodyContent(_ detail: MessageDetail) -> some View {
        if model.isShowingRawSource {
            if let raw = model.rawSource {
                RawSourceView(
                    text: raw,
                    query: activeFindQuery,
                    selectedMatchIndex: findSnapshot.index,
                    findTick: findTick
                )
                .padding(.horizontal, MessageViewerLayoutPolicy.islandContentPadding)
                .padding(.vertical, MessageViewerLayoutPolicy.islandVerticalPadding)
            } else {
                ProgressView("Loading source…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, MessageViewerLayoutPolicy.islandContentPadding)
                    .padding(.vertical, MessageViewerLayoutPolicy.islandVerticalPadding)
            }
        } else if detail.isQuarantined {
            Text("The original source is available if you need it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, MessageViewerLayoutPolicy.islandContentPadding)
                .padding(.vertical, MessageViewerLayoutPolicy.islandVerticalPadding)
        } else if let html = detail.sanitizedHTML, !html.isEmpty {
            htmlBody(detail, html: html)
        } else if let text = detail.bodyText, !text.isEmpty {
            PlainTextBody(
                text: text,
                query: activeFindQuery,
                selectedMatchIndex: findSnapshot.index,
                findTick: findTick
            )
            .padding(.horizontal, MessageViewerLayoutPolicy.islandContentPadding)
            .padding(.vertical, MessageViewerLayoutPolicy.islandVerticalPadding)
            // The pane stays full width; only the plain-text measure narrows.
            .frame(maxWidth: MessageTypography.plainTextMeasure, alignment: .leading)
        } else {
            Text("This message has no text.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, MessageViewerLayoutPolicy.islandContentPadding)
                .padding(.vertical, MessageViewerLayoutPolicy.islandVerticalPadding)
        }
    }


    private func htmlBody(_ detail: MessageDetail, html: String) -> some View {
        let showRemoteImageNotice = model.hasRemoteImageReferences && !model.allowRemoteImages
        return VStack(alignment: .leading, spacing: 0) {
            // Keep a stable slot ahead of the representable. If the notice is
            // removed as a sibling, SwiftUI can shift MessageHTMLView's
            // structural identity and recreate its WKWebView instead of
            // delivering the consent update to updateNSView.
            ZStack(alignment: .topLeading) {
                if showRemoteImageNotice {
                    RemoteImageNotice { model.allowRemoteImages = true }
                        .padding(.horizontal, MessageViewerLayoutPolicy.islandContentPadding)
                        .padding(.top, MessageViewerLayoutPolicy.islandVerticalPadding)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(
                .bottom,
                showRemoteImageNotice ? MessageViewerLayoutPolicy.bodyContentSpacing : 0
            )
            MessageHTMLView(
                html: html,
                partProvider: model.partProvider(for: detail.id),
                onExternalLink: { url in
                    NSWorkspace.shared.open(url)
                },
                onContentHeightChange: { height in
                    guard height.isFinite, height > 0 else { return }
                    let messageID = detail.id
                    Task { @MainActor in
                        guard model.detail?.id == messageID else { return }
                        let measured = MessageViewerLayoutPolicy.htmlHeight(contentHeight: height)
                        guard abs(htmlContentHeight - measured) > 0.5 else { return }
                        htmlContentHeight = measured
                    }
                },
                allowRemoteImages: model.allowRemoteImages,
                emailReadingMode: model.effectiveEmailReadingMode,
                findQuery: activeFindQuery,
                findTick: findTick,
                findBackwards: findBackwards
            )
            // The web page is the body island's canvas. Its document height
            // exactly owns the island height, so the outer reader is the only
            // scroll view even for long HTML messages.
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: MessageViewerLayoutPolicy.htmlHeight(contentHeight: htmlContentHeight))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func restartFind() {
        findBackwards = false
        findIndex = MessageFind.restartIndex(
            count: MessageFind.ranges(in: findHaystack, query: model.findQuery).count
        )
        findTick += 1
    }

    private func stepFind(_ step: MessageFind.Step) {
        findBackwards = step == .previous
        findIndex = MessageFind.advance(
            index: findSnapshot.index,
            count: findSnapshot.count,
            step: step
        )
        findTick += 1
    }
}

private enum ReaderIslandRole: Equatable {
    case translucent
    case body
}

private struct ReaderIslandSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let role: ReaderIslandRole
    let backdropStyle: WindowBackdropStyle

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: AppShapeScale.card, style: .continuous)
        content
            .background {
                surfaceBackground(in: shape)
            }
            .overlay {
                if !reduceTransparency, role == .translucent,
                   let image = ReaderFilmGrain.image {
                    Image(decorative: image, scale: 1, orientation: .up)
                        .resizable(resizingMode: .tile)
                        .opacity(0.04)
                        .blendMode(.overlay)
                        .clipShape(shape)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                shape.strokeBorder(
                    contrast == .increased ? Color.primary : Color.primary.opacity(0.18),
                    lineWidth: contrast == .increased ? 1.5 : 0.75
                )
            }
            .clipShape(shape)
            .shadow(color: .black.opacity(0.14), radius: 12, y: 5)
    }

    @ViewBuilder
    private func surfaceBackground(in shape: RoundedRectangle) -> some View {
        if reduceTransparency || role == .body {
            shape.fill(Color(nsColor: .windowBackgroundColor))
        } else {
            switch backdropStyle {
            case .clearGlass, .regularGlass:
                shape
                    .fill(Color.clear)
                    .glassEffect(
                        backdropStyle == .clearGlass ? .clear : .regular,
                        in: shape
                    )
            case .frostedBlur:
                shape.fill(.ultraThinMaterial)
            }
        }
    }
}

private enum ReaderFilmGrain {
    static let image: CGImage? = {
        let side = 128
        var bytes = [UInt8](repeating: 0, count: side * side)
        var seed: UInt64 = 0x4D61696C7465726E
        for index in bytes.indices {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            bytes[index] = UInt8(truncatingIfNeeded: seed >> 56)
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else {
            return nil
        }
        return CGImage(
            width: side,
            height: side,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }()
}

private extension View {
    func readerIslandSurface(
        role: ReaderIslandRole = .translucent,
        backdropStyle: WindowBackdropStyle = .frostedBlur
    ) -> some View {
        modifier(ReaderIslandSurface(role: role, backdropStyle: backdropStyle))
    }
}

/// Reading anchor: the strongest contrast in the reader, wrapping without
/// limit, resting below the window's dissolve rather than inside its ramp.
/// The envelope and its source representation live inside this same surface,
/// so changing source mode animates one island rather than replacing a card.
struct MessageSubjectRegion: View {
    let subject: String
    let envelope: Envelope
    let attachments: [AttachmentInfo]
    let messageID: MessageID
    let headersStore: MessageHeadersStore
    let backdropStyle: WindowBackdropStyle
    let showsSenderIcons: Bool
    let isShowingRawSource: Bool
    let accent: Color

    var body: some View {
        let display = MessageHeaderPolicy.subject(subject)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(display.text)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(display.isPlaceholder ? Color.secondary : Color.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(UIIdentifier.messageSubject)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, MessageViewerLayoutPolicy.islandVerticalPadding)

            MessageEnvelopeRegion(
                envelope: envelope,
                attachments: attachments,
                messageID: messageID,
                headersStore: headersStore,
                showsSenderIcons: showsSenderIcons,
                isShowingRawSource: isShowingRawSource,
                accent: accent
            )
        }
        .padding(.horizontal, MessageViewerLayoutPolicy.islandContentPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .readerIslandSurface(backdropStyle: backdropStyle)
    }
}

/// The ordinary envelope is deliberately icon-led: the upward arrow means the
/// sender and the downward arrow means the recipient. This avoids repeating
/// the words “From” and “To” while preserving a consistent spatial pair.
struct MessageEnvelopeRegion: View {
    let envelope: Envelope
    let attachments: [AttachmentInfo]
    let messageID: MessageID
    let headersStore: MessageHeadersStore
    let showsSenderIcons: Bool
    let isShowingRawSource: Bool
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isShowingRawSource {
                rawHeaderContent
            } else {
                prettyEnvelope
                if !attachments.isEmpty {
                    attachmentRows
                        .padding(.top, MessageViewerLayoutPolicy.attachmentSpacing)
                }
            }
        }
        .font(.subheadline)
        .padding(.top, MessageViewerLayoutPolicy.envelopeTopPadding)
        .padding(.bottom, MessageViewerLayoutPolicy.envelopeBottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Text survives the source-mode switch in the same island and lets
        // numeric values roll rather than blink as a remove/insert.
        .contentTransition(.numericText())
        .task(id: messageID) {
            // Delivery time is useful in the ordinary envelope too. The store
            // still caches the result, so this remains one fetch per message.
            headersStore.loadIfNeeded(for: messageID)
        }
    }

    private var prettyEnvelope: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: MessageViewerLayoutPolicy.envelopePairSpacing) {
                senderItem
                receiverItem
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: MessageViewerLayoutPolicy.envelopePairSpacing) {
                sentItem
                if let deliveredDate {
                    deliveredItem(deliveredDate)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(minWidth: 156, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var senderItem: some View {
        if let sender = envelope.from.first {
            EnvelopeCopyItem(
                symbol: "arrow.up.right.circle",
                payload: MessageHeaderPolicy.copyPayload(for: sender),
                accessibilityLabel: "Sender, \(MessageHeaderPolicy.full(sender))",
                accent: accent
            ) {
                HStack(alignment: .center, spacing: 8) {
                    if showsSenderIcons {
                        MonogramView(
                            initials: MessageHeaderPolicy.initials(for: sender),
                            accent: accent
                        )
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(MessageHeaderPolicy.name(of: sender))
                            .font(.headline)
                            .lineLimit(1)
                        Text(sender.address)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        } else {
            Label("Unknown sender", systemImage: "arrow.up.right.circle")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var receiverItem: some View {
        if let recipients = MessageHeaderPolicy.collapseRecipients(envelope.to) {
            EnvelopeCopyItem(
                symbol: "arrow.down.left.circle",
                payload: MessageHeaderPolicy.copyPayload(for: recipients.first),
                accessibilityLabel: "Recipient, \(MessageHeaderPolicy.full(recipients.first))",
                accent: accent
            ) {
                HStack(alignment: .center, spacing: 8) {
                    if showsSenderIcons {
                        MonogramView(
                            initials: MessageHeaderPolicy.initials(for: recipients.first),
                            accent: accent
                        )
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(recipients.summary)
                            .font(.headline)
                            .lineLimit(1)
                        Text(recipients.first.address)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        } else {
            Label("No recipient", systemImage: "arrow.down.left.circle")
                .foregroundStyle(.secondary)
        }
    }

    private var sentItem: some View {
        let date = envelope.headerDate ?? envelope.internalDate
        return EnvelopeCopyItem(
            symbol: "paperplane",
            payload: MailDateFormat.envelope(date),
            accessibilityLabel: "Sent, \(MailDateFormat.envelope(date))",
            accent: accent
        ) {
            Text(MailDateFormat.envelope(date))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func deliveredItem(_ date: Date) -> some View {
        EnvelopeCopyItem(
            symbol: "tray.and.arrow.down",
            payload: MailDateFormat.envelope(date),
            accessibilityLabel: "Delivered, \(MailDateFormat.envelope(date))",
            accent: accent
        ) {
            Text(MailDateFormat.envelope(date))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var deliveredDate: Date? {
        guard case .loaded(let headers, _) = headersStore.state(for: messageID) else {
            return nil
        }
        return MessageHeaderPolicy.deliveredDate(from: headers)
    }

    private var attachmentRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(attachments) { attachment in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "paperclip")
                        .foregroundStyle(.secondary)
                    Text(MessageHeaderPolicy.attachmentName(attachment))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if let size = MessageHeaderPolicy.attachmentSize(attachment) {
                        Text(size)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Attachment, \(MessageHeaderPolicy.attachmentName(attachment))")
            }
        }
    }

    @ViewBuilder
    private var rawHeaderContent: some View {
        switch headersStore.state(for: messageID) {
        case .idle, .loading:
            if let headers = headersStore.headers(for: messageID, fallback: envelope) {
                RawHeadersBlock(
                    headers: headers,
                    text: MessageHeaderPolicy.rawHeaderBlock(from: headers)
                )
            } else {
                ProgressView("Loading headers…")
                    .controlSize(.small)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label("Couldn’t load headers", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry") {
                    headersStore.retry(messageID)
                }
                .buttonStyle(.link)
            }
            .accessibilityIdentifier("message-headers-error")
        case .loaded(let headers, let text):
            if headers.isEmpty {
                Text("No raw headers found.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                RawHeadersBlock(headers: headers, text: text)
            }
        }
    }

}

/// A small accent wash keeps the monogram legible without fetching an avatar.
private struct MonogramView: View {
    let initials: String
    let accent: Color

    var body: some View {
        Text(initials)
            .font(.caption.weight(.semibold))
            .foregroundStyle(accent)
            .frame(width: 26, height: 26)
            .background(accent.opacity(0.15), in: Circle())
            .accessibilityHidden(true)
    }
}

/// Replaces a copy target's text with a clipboard glyph without changing the
/// target's measured size. Reduced Motion swaps the two states immediately.
private struct CopyFeedbackLabel<Label: View>: View {
    let label: Label
    let isShowingCopy: Bool
    let reduceMotion: Bool

    init(
        isShowingCopy: Bool,
        reduceMotion: Bool,
        @ViewBuilder label: () -> Label
    ) {
        self.label = label()
        self.isShowingCopy = isShowingCopy
        self.reduceMotion = reduceMotion
    }

    var body: some View {
        ZStack(alignment: .leading) {
            label
                .opacity(isShowingCopy ? 0 : 1)
            Image(systemName: "doc.on.clipboard")
                .opacity(isShowingCopy ? 1 : 0)
                .accessibilityHidden(true)
        }
        .animation(
            reduceMotion
                ? nil
                : .easeOut(duration: isShowingCopy ? 0.12 : 0.15),
            value: isShowingCopy
        )
    }
}


/// A copy target presents the same interaction for identities and dates:
/// rounded hover wash, pointer cursor, and a brief clipboard confirmation in
/// place of the copied text.
private struct EnvelopeCopyItem<Label: View>: View {
    let symbol: String
    let payload: String
    let accessibilityLabel: String
    let accent: Color
    let label: Label
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var didCopy = false
    @State private var isShowingQRCode = false
    @State private var copyFeedbackGeneration = 0

    init(
        symbol: String,
        payload: String,
        accessibilityLabel: String,
        accent: Color,
        @ViewBuilder label: () -> Label
    ) {
        self.symbol = symbol
        self.payload = payload
        self.accessibilityLabel = accessibilityLabel
        self.accent = accent
        self.label = label()
    }

    var body: some View {
        Button(action: copy) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(accent)
                    .frame(width: 18, alignment: .center)
                CopyFeedbackLabel(
                    isShowingCopy: didCopy,
                    reduceMotion: reduceMotion
                ) {
                    label
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background {
                if isHovered {
                    RoundedRectangle(cornerRadius: AppShapeScale.row, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: AppShapeScale.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .contextMenu {
            Button("Copy", systemImage: "doc.on.clipboard", action: copy)
            Button("Show QR Code", systemImage: "qrcode", action: showQRCode)
                .disabled(!QRCodePolicy.canEncode(payload))
                .help(QRCodePolicy.menuHelp(for: payload))
        }
        .popover(isPresented: $isShowingQRCode, arrowEdge: .top) {
            QRCodeCard(payload: payload)
        }
        .onHover { hovered in
            isHovered = hovered
            if hovered {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .animation(MailMotion.hover, value: isHovered)
    }

    private func showQRCode() {
        guard QRCodePolicy.canEncode(payload) else { return }
        isShowingQRCode = true
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload, forType: .string)

        copyFeedbackGeneration &+= 1
        let generation = copyFeedbackGeneration
        didCopy = true

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, generation == copyFeedbackGeneration else { return }
            didCopy = false
        }
    }
}


/// The complete unfolded header block uses SF Mono. Each header name and
/// value is its own copy target; there is no block-level control.
private struct RawHeadersBlock: View {
    let headers: [MessageHeaderPolicy.HeaderItem]
    let text: String
    @FocusState private var blockFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: MessageViewerLayoutPolicy.envelopePairSpacing) {
            ForEach(headers) { header in
                RawHeaderRow(header: header)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .focusable()
        .focusEffectDisabled()
        .focused($blockFocused)
    }
}

private struct RawHeaderRow: View {
    let header: MessageHeaderPolicy.HeaderItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            RawHeaderField(
                text: "\(header.name):",
                payload: header.keyCopyText,
                accessibilityLabel: "\(header.name), header name",
                expands: false
            )
            RawHeaderField(
                text: header.value,
                payload: header.valueCopyText,
                accessibilityLabel: "\(header.name), header value",
                expands: true
            )
        }
        .font(.system(.callout, design: .monospaced))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RawHeaderField: View {
    let text: String
    let payload: String
    let accessibilityLabel: String
    let expands: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var didCopy = false
    @State private var isShowingQRCode = false
    @State private var copyFeedbackGeneration = 0

    var body: some View {
        Button(action: copy) {
            Text(text)
                .opacity(didCopy ? 0 : 1)
                .frame(
                    maxWidth: expands ? .infinity : nil,
                    alignment: expands ? .leading : .center
                )
                .fixedSize(horizontal: !expands, vertical: false)
                .overlay {
                    Image(systemName: "doc.on.clipboard")
                        .opacity(didCopy ? 1 : 0)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background {
                    if isHovered {
                        RoundedRectangle(cornerRadius: AppShapeScale.row, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: AppShapeScale.row, style: .continuous))
                .animation(
                    reduceMotion
                        ? nil
                        : .easeOut(duration: didCopy ? 0.12 : 0.15),
                    value: didCopy
                )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Copies \(payload)")
        .contextMenu {
            Button("Copy", systemImage: "doc.on.clipboard", action: copy)
            Button("Show QR Code", systemImage: "qrcode", action: showQRCode)
                .disabled(!QRCodePolicy.canEncode(payload))
                .help(QRCodePolicy.menuHelp(for: payload))
        }
        .popover(isPresented: $isShowingQRCode, arrowEdge: .top) {
            QRCodeCard(payload: payload)
        }
        .onHover { hovered in
            isHovered = hovered
            if hovered {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .animation(MailMotion.hover, value: isHovered)
    }

    private func showQRCode() {
        guard QRCodePolicy.canEncode(payload) else { return }
        isShowingQRCode = true
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload, forType: .string)

        copyFeedbackGeneration &+= 1
        let generation = copyFeedbackGeneration
        didCopy = true

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, generation == copyFeedbackGeneration else { return }
            didCopy = false
        }
    }
}




/// Blocked remote content is a body state the reader discloses before the
/// message is read, not a permanently disabled control after it.
private struct RemoteImageNotice: View {
    let load: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
            Text("Remote images are blocked in this message.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Load Images", action: load)
                .buttonStyle(.link)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }
}

struct PlainTextBody: View {
    let text: String
    let query: String
    let selectedMatchIndex: Int?
    let findTick: UInt64

    var body: some View {
        HighlightedMessageText(
            text: text,
            query: query,
            selectedMatchIndex: selectedMatchIndex,
            findTick: findTick,
            font: MessageTypography.bodyFont,
            paragraphStyle: MessageTypography.bodyParagraphStyle
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A parse failure is a message state: it sits at the top of the body island,
/// above the source text it replaces.
struct QuarantineBanner: View {
    let showingRaw: Bool
    let loadRaw: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("This message couldn’t be parsed")
                    .font(.headline)
                Text("Mailternal kept it quarantined so it can’t stall the folder. You can inspect the capped raw source.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(showingRaw ? "Showing Raw Source" : "Show Raw Source", action: loadRaw)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(showingRaw)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 14)
        .accessibilityIdentifier(UIIdentifier.quarantineBanner)
    }
}

struct RawSourceView: View {
    let text: String
    var query: String = ""
    var selectedMatchIndex: Int?
    var findTick: UInt64 = 0

    var body: some View {
        HighlightedMessageText(
            text: text,
            query: query,
            selectedMatchIndex: selectedMatchIndex,
            findTick: findTick,
            font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            paragraphStyle: .default
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct HighlightedMessageText: NSViewRepresentable {
    let text: String
    let query: String
    let selectedMatchIndex: Int?
    let findTick: UInt64
    var font: NSFont = MessageTypography.bodyFont
    var paragraphStyle: NSParagraphStyle = MessageTypography.bodyParagraphStyle

    final class Coordinator {
        var lastTick: UInt64 = .max
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.backgroundColor = .clear
        view.isRichText = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        applyText(to: view)
        guard context.coordinator.lastTick != findTick else { return }
        context.coordinator.lastTick = findTick
        scrollToSelection(in: view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? nsView.bounds.width
        guard width.isFinite, width > 0 else { return nil }
        nsView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        nsView.frame.size.width = width
        applyText(to: nsView)
        guard let container = nsView.textContainer else {
            return CGSize(width: width, height: MessageTypography.bodyLineHeight)
        }
        nsView.layoutManager?.ensureLayout(for: container)
        let used = nsView.layoutManager?.usedRect(for: container) ?? .zero
        return CGSize(width: width, height: max(ceil(used.height), MessageTypography.bodyLineHeight))
    }

    private func applyText(to view: NSTextView) {
        let storage = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraphStyle,
            ]
        )
        let matches = MessageFind.ranges(in: text, query: query)
        for (offset, range) in matches.enumerated() {
            let nsRange = NSRange(range, in: text)
            let isSelected = offset == selectedMatchIndex
            storage.addAttribute(
                .backgroundColor,
                value: isSelected ? NSColor.selectedContentBackgroundColor : NSColor.findHighlightColor,
                range: nsRange
            )
            if isSelected {
                storage.addAttribute(
                    .foregroundColor,
                    value: NSColor.alternateSelectedControlTextColor,
                    range: nsRange
                )
            }
        }
        view.textStorage?.setAttributedString(storage)
    }

    private func scrollToSelection(in view: NSTextView) {
        let matches = MessageFind.ranges(in: text, query: query)
        guard let selectedMatchIndex, matches.indices.contains(selectedMatchIndex) else { return }
        let nsRange = NSRange(matches[selectedMatchIndex], in: text)
        DispatchQueue.main.async {
            view.scrollRangeToVisible(nsRange)
            if nsRange.length > 0 {
                view.showFindIndicator(for: nsRange)
            }
        }
    }
}

struct FindBar: View {
    @Binding var query: String
    let matchCount: Int
    let selectedMatchNumber: Int?
    let next: () -> Void
    let previous: () -> Void
    let close: () -> Void
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find in message", text: $query)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .onSubmit(next)
            Text(countLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button(action: previous) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .disabled(matchCount == 0)
            Button(action: next) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            .disabled(matchCount == 0)
            Button(action: close) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thickMaterial, in: .capsule)
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        .onAppear { fieldFocused = true }
        .onExitCommand(perform: close)
        .defaultFocus($fieldFocused, true)
    }

    private var countLabel: String {
        if query.isEmpty { return "" }
        if matchCount == 0 { return "No results" }
        if let selectedMatchNumber {
            return "\(selectedMatchNumber) of \(matchCount)"
        }
        return "\(matchCount)"
    }
}
