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
    /// Titlebar depth measured where the pane still has a safe area, i.e.
    /// outside the scrolling surface's own `ignoresSafeArea`.
    @State private var safeAreaTop: CGFloat = 0
    @State private var htmlContentHeight: CGFloat = 0
    @State private var isDetailsExpanded = false

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
        // Read here, not on the scrolling surface: the reader deliberately
        // ignores the container safe area so its dissolve can start at the
        // physical window top, which leaves this the only place the titlebar
        // depth is still measurable.
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.safeAreaInsets.top
        } action: { safeAreaTop = $0 }
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
        .onChange(of: model.detail?.id) { _, _ in
            isDetailsExpanded = false
            htmlContentHeight = 0
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
        if let detail = model.detail {
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

    /// One scroll owner, three disjoint floating islands: subject, envelope,
    /// and body. The web view reports its document height and does not own a
    /// scrolling viewport, so the reader scrolls the whole message as one page.
    private func reader(_ detail: MessageDetail) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: MessageViewerLayoutPolicy.islandSpacing) {
                MessageSubjectRegion(
                    subject: detail.envelope.subject,
                    isShowingRawSource: model.isShowingRawSource,
                    showRawSource: { Task { await model.loadRawSource() } },
                    showFormatted: { model.isShowingRawSource = false },
                    copySubject: { model.copySelectedSubject() },
                    backdropKind: model.appearance.backdropKind
                )
                MessageEnvelopeRegion(
                    envelope: detail.envelope,
                    attachments: detail.attachments,
                    isDetailsExpanded: $isDetailsExpanded,
                    backdropKind: model.appearance.backdropKind
                )
                bodyRegion(detail)
            }
            .padding(.horizontal, MessageViewerLayoutPolicy.horizontalPadding)
            // The first subject glyph retains the old dissolve contract while
            // the card's top edge can softly enter the end of the ramp.
            .padding(
                .top,
                max(
                    MessageViewerLayoutPolicy.readerTopInset(safeAreaTop: safeAreaTop)
                        - MessageViewerLayoutPolicy.islandVerticalPadding,
                    0
                )
            )
            .padding(.bottom, MessageViewerLayoutPolicy.bottomPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(
                reduceMotion ? .easeOut(duration: 0.01) : MailMotion.disclosure,
                value: isDetailsExpanded
            )
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
            backdropKind: model.appearance.backdropKind
        )
        .accessibilityIdentifier(UIIdentifier.messageBody)
    }

    @ViewBuilder
    private func bodyContent(_ detail: MessageDetail) -> some View {
        if model.isShowingRawSource, let raw = model.rawSource {
            RawSourceView(
                text: raw,
                query: activeFindQuery,
                selectedMatchIndex: findSnapshot.index,
                findTick: findTick
            )
            .padding(.horizontal, MessageViewerLayoutPolicy.islandContentPadding)
            .padding(.vertical, MessageViewerLayoutPolicy.islandVerticalPadding)
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
        return VStack(alignment: .leading, spacing: MessageViewerLayoutPolicy.bodyContentSpacing) {
            if showRemoteImageNotice {
                RemoteImageNotice { model.allowRemoteImages = true }
                    .padding(.horizontal, MessageViewerLayoutPolicy.islandContentPadding)
                    .padding(.top, MessageViewerLayoutPolicy.islandVerticalPadding)
            }
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
                emailReadingMode: model.appearance.emailReadingMode,
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
    let backdropKind: WindowBackdropKind

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
            switch backdropKind {
            case .glass:
                shape
                    .fill(Color.clear)
                    .glassEffect(.regular, in: shape)
            case .blur:
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
        backdropKind: WindowBackdropKind = .blur
    ) -> some View {
        modifier(ReaderIslandSurface(role: role, backdropKind: backdropKind))
    }
}

/// Reading anchor: the strongest contrast in the reader, wrapping without
/// limit, resting below the window's dissolve rather than inside its ramp.
struct MessageSubjectRegion: View {
    let subject: String
    let isShowingRawSource: Bool
    let showRawSource: () -> Void
    let showFormatted: () -> Void
    let copySubject: () -> Void
    let backdropKind: WindowBackdropKind

    var body: some View {
        let display = MessageHeaderPolicy.subject(subject)
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
            actions
        }
        .padding(.horizontal, MessageViewerLayoutPolicy.islandContentPadding)
        .padding(.vertical, MessageViewerLayoutPolicy.islandVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .readerIslandSurface(backdropKind: backdropKind)
    }

    private var actions: some View {
        Menu {
            if isShowingRawSource {
                Button("Show Formatted Message", action: showFormatted)
            } else {
                Button("View Raw Source", action: showRawSource)
            }
            Button("Copy Subject", action: copySubject)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Message actions")
    }
}


/// Envelope: who sent it, who received it, when, what came attached — and a
/// disclosure for every remaining header the store actually parsed.
struct MessageEnvelopeRegion: View {
    let envelope: Envelope
    let attachments: [AttachmentInfo]
    @Binding var isDetailsExpanded: Bool
    let backdropKind: WindowBackdropKind

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            senderRow
            if !recipientGroups.isEmpty {
                recipients
                    .padding(.top, MessageViewerLayoutPolicy.envelopeRowSpacing)
            }
            if !attachments.isEmpty {
                attachmentRows
                    .padding(.top, MessageViewerLayoutPolicy.attachmentSpacing)
            }
            details
                .padding(.top, MessageViewerLayoutPolicy.envelopeRowSpacing)
        }
        .font(.subheadline)
        .padding(.horizontal, MessageViewerLayoutPolicy.islandContentPadding)
        .padding(.top, MessageViewerLayoutPolicy.envelopeTopPadding)
        .padding(.bottom, MessageViewerLayoutPolicy.envelopeBottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .readerIslandSurface(backdropKind: backdropKind)
    }

    /// Sender and date share a line until the line no longer fits — at a narrow
    /// pane or a large text size the date drops below instead of squeezing the
    /// identity.
    private var senderRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                senderIdentity
                Spacer(minLength: 16)
                dateText
            }
            VStack(alignment: .leading, spacing: MessageViewerLayoutPolicy.envelopePairSpacing) {
                senderIdentity
                dateText
            }
        }
    }

    @ViewBuilder
    private var senderIdentity: some View {
        if envelope.from.isEmpty {
            Text("Unknown sender")
                .font(.headline)
                .foregroundStyle(.secondary)
        } else if envelope.from.count == 1, let sender = envelope.from.first {
            // Name and address are separate runs, both in the primary text
            // role: an address a recipient may need to check is never dimmed
            // into a caption.
            VStack(alignment: .leading, spacing: 2) {
                Text(MessageHeaderPolicy.name(of: sender))
                    .font(.headline)
                if MessageHeaderPolicy.name(of: sender) != sender.address {
                    Text(sender.address)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .textSelection(.enabled)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("From, \(MessageHeaderPolicy.full(sender))")
        } else {
            Text(MessageHeaderPolicy.list(envelope.from))
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private var dateText: some View {
        Text(MailDateFormat.envelope(envelope.internalDate))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }

    /// A recipient group the message actually carries. Absent groups never
    /// reach the grid, so the reader stays silent about what it does not know.
    private struct RecipientGroup: Identifiable {
        let id: String
        let summary: String
        let spoken: String
    }

    private var recipientGroups: [RecipientGroup] {
        let groups = [
            (label: "To", addresses: envelope.to),
            (label: "Cc", addresses: envelope.cc),
        ]
        return groups.compactMap { group in
            guard let summary = MessageHeaderPolicy.summary(group.addresses),
                  let spoken = MessageHeaderPolicy.spokenSummary(group.addresses)
            else { return nil }
            return RecipientGroup(id: group.label, summary: summary, spoken: spoken)
        }
    }

    /// Label and value stay separate grid cells so the columns align at every
    /// text size; the value carries the spoken form, because "+2" is a visual
    /// abbreviation rather than something to read aloud.
    private var recipients: some View {
        Grid(
            alignment: .leadingFirstTextBaseline,
            horizontalSpacing: 10,
            verticalSpacing: MessageViewerLayoutPolicy.envelopePairSpacing
        ) {
            ForEach(recipientGroups) { group in
                GridRow {
                    Text(group.id)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.leading)
                    Text(group.summary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityLabel(group.spoken)
                }
            }
        }
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

    /// A real disclosure control: tab reaches it, Space and Return toggle it,
    /// and VoiceOver speaks its expanded state. It holds every stored header
    /// with a value — raw MIME stays behind the separate raw-source action.
    private var details: some View {
        DisclosureGroup(isExpanded: $isDetailsExpanded) {
            Grid(
                alignment: .leadingFirstTextBaseline,
                horizontalSpacing: 10,
                verticalSpacing: MessageViewerLayoutPolicy.envelopePairSpacing
            ) {
                ForEach(MessageHeaderPolicy.detailRows(for: envelope)) { row in
                    GridRow {
                        Text(row.label)
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.leading)
                        Text(row.value)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.top, MessageViewerLayoutPolicy.envelopePairSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            // The label names the control; keeping the accessibility label here
            // leaves the expanded rows as their own elements.
            Text("Details")
                .font(.subheadline)
                .accessibilityLabel("Message details")
        }
        .accessibilityIdentifier(UIIdentifier.messageDetails)
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
