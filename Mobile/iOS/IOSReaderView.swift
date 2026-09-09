import SwiftUI
import UIKit
import WebKit
import MailternalInterfaces
import MailternalSanitizer

/// Presents the selected message as a reading-first surface while keeping
/// diagnostic views available through the native More menu. The subject belongs
/// to the reading content, not a second large navigation heading.
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

    /// The reader's primary message view and its explicitly requested diagnostics.
    enum ReaderSection: String, CaseIterable, Identifiable {
        case body
        case headers
        case source
        var id: String { rawValue }
        var title: String {
            switch self { case .body: "Message"; case .headers: "Headers"; case .source: "Raw Source" }
        }
        var systemImage: String {
            switch self {
            case .body: "envelope.open"
            case .headers: "list.bullet.rectangle"
            case .source: "doc.plaintext"
            }
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
        .navigationTitle("Reader")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { Task { await state.openAdjacent(delta: -1) } } label: { Label("Previous", systemImage: "chevron.up") }
                    .disabled(!state.canNavigatePrevious)
                Button { Task { await state.openAdjacent(delta: 1) } } label: { Label("Next", systemImage: "chevron.down") }
                    .disabled(!state.canNavigateNext)
                Menu {
                    if let id = state.selectedMessageID {
                        Button { Task { await state.composer.reply(to: id, all: false) } } label: {
                            Label("Reply", systemImage: "arrowshape.turn.up.left")
                        }
                        Button { Task { await state.composer.reply(to: id, all: true) } } label: {
                            Label("Reply All", systemImage: "arrowshape.turn.up.left.2")
                        }
                        Button { Task { await state.composer.forward(id) } } label: {
                            Label("Forward", systemImage: "arrowshape.turn.up.right")
                        }
                        Divider()
                    }
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
                    Divider()
                    Section("Reader view") {
                        Picker("Reader view", selection: $section) {
                            ForEach(ReaderSection.allCases) { view in
                                Label(view.title, systemImage: view.systemImage).tag(view)
                            }
                        }
                        .accessibilityLabel("Reader view")
                    }
                    if section != .body {
                        Button { section = .body } label: {
                            Label("Return to Message", systemImage: "arrow.uturn.backward")
                        }
                    }
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
                IOSEnvelopeView(
                    envelope: detail.envelope,
                    showSenderIcons: state.showSenderIcons,
                    expanded: $showHeaders
                )
                if section != .body {
                    HStack(alignment: .center, spacing: 12) {
                        Label(section.title, systemImage: section.systemImage)
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                        Spacer(minLength: 0)
                        Button("Return to Message") { section = .body }
                            .buttonStyle(.borderless)
                            .frame(minHeight: 44)
                    }
                    .accessibilityElement(children: .contain)
                }
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

    /// Keeps ordinary reading in the body path; HTML remains unconstrained while
    /// plain text receives the design language's 490-point readable measure.
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
                    Button("Load Remote Images") { state.setRemoteImagesAllowed(true) }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                }
            }
            .padding(14)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                    .controlSize(.regular)
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
                .frame(maxWidth: 490, alignment: .leading)
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

/// Shows the envelope as compact, individually copyable native targets.
private struct IOSEnvelopeView: View {
    let envelope: Envelope
    let showSenderIcons: Bool
    @Binding var expanded: Bool
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            addressRow("From", values: envelope.from, role: "sender", row: .sender)
            addressRow("To", values: envelope.to, role: "recipient", row: .recipient)
            if expanded {
                if !envelope.cc.isEmpty {
                    detailRow("Cc", addresses(envelope.cc))
                }
                if !envelope.replyTo.isEmpty {
                    detailRow("Reply-To", addresses(envelope.replyTo))
                }
                if let headerDate = envelope.headerDate {
                    detailRow("Date", headerDate.formatted(date: .complete, time: .shortened))
                }
            }
            Button(expanded ? "Hide details" : "Show details") { expanded.toggle() }
                .font(.caption)
                .buttonStyle(.borderless)
                .foregroundStyle(.tint)
                .frame(minHeight: 44, alignment: .leading)
                .accessibilityLabel(expanded ? "Hide message details" : "Show message details")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .padding(.leading, 30)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .coordinateSpace(name: "envelope")
        .overlayPreferenceValue(IOSEnvelopeRowCenterPreferenceKey.self) { centers in
            GeometryReader { proxy in
                if let senderY = centers[.sender], let recipientY = centers[.recipient] {
                    IOSEnvelopeConnectorShape(senderY: senderY, recipientY: recipientY)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .frame(width: 24, height: proxy.size.height)
                        .scaleEffect(x: layoutDirection == .rightToLeft ? -1 : 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    @ViewBuilder
    private func addressRow(
        _ label: String,
        values: [MailAddress],
        role: String,
        row: IOSEnvelopeRow
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
                .padding(.top, 12)
            IOSAddressTargetLayout(
                horizontalSpacing: 8,
                verticalSpacing: 8,
                layoutDirection: layoutDirection
            ) {
                if values.isEmpty {
                    Text(role == "sender" ? "Unknown sender" : "No recipients")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(Array(values.enumerated()), id: \.offset) { _, address in
                        IOSAddressCopyTarget(
                            address: address,
                            role: role,
                            showsMonogram: showSenderIcons
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: IOSEnvelopeRowCenterPreferenceKey.self,
                    value: [row: proxy.frame(in: .named("envelope")).midY]
                )
            }
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
            Text(value)
                .font(.subheadline)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func addresses(_ values: [MailAddress]) -> String {
        values.map { address in
            if let name = address.displayName, !name.isEmpty { return "\(name) <\(address.address)>" }
            return address.address
        }.joined(separator: ", ")
    }
}

private enum IOSEnvelopeRow: Hashable {
    case sender
    case recipient
}

private struct IOSEnvelopeRowCenterPreferenceKey: PreferenceKey {
    static let defaultValue: [IOSEnvelopeRow: CGFloat] = [:]

    static func reduce(
        value: inout [IOSEnvelopeRow: CGFloat],
        nextValue: () -> [IOSEnvelopeRow: CGFloat]
    ) {
        for (row, center) in nextValue() {
            value[row] = center
        }
    }
}

/// Draws the static rounded sender-to-recipient direction connector.
private struct IOSEnvelopeConnectorShape: Shape {
    let senderY: CGFloat
    let recipientY: CGFloat

    func path(in rect: CGRect) -> Path {
        let leftX = min(7, rect.width / 3)
        let tipX = max(leftX + 2, rect.width - 2)
        let radius = min(6, max(2, abs(recipientY - senderY) / 2))
        var path = Path()
        path.move(to: CGPoint(x: tipX, y: senderY))
        path.addLine(to: CGPoint(x: leftX + radius, y: senderY))
        if recipientY >= senderY {
            path.addQuadCurve(
                to: CGPoint(x: leftX, y: senderY + radius),
                control: CGPoint(x: leftX, y: senderY)
            )
            path.addLine(to: CGPoint(x: leftX, y: recipientY - radius))
            path.addQuadCurve(
                to: CGPoint(x: leftX + radius, y: recipientY),
                control: CGPoint(x: leftX, y: recipientY)
            )
        } else {
            path.addQuadCurve(
                to: CGPoint(x: leftX, y: senderY - radius),
                control: CGPoint(x: leftX, y: senderY)
            )
            path.addLine(to: CGPoint(x: leftX, y: recipientY + radius))
            path.addQuadCurve(
                to: CGPoint(x: leftX + radius, y: recipientY),
                control: CGPoint(x: leftX, y: recipientY)
            )
        }
        path.addLine(to: CGPoint(x: tipX, y: recipientY))
        path.move(to: CGPoint(x: tipX - 8, y: recipientY - 5))
        path.addLine(to: CGPoint(x: tipX, y: recipientY))
        path.addLine(to: CGPoint(x: tipX - 8, y: recipientY + 5))
        return path
    }
}

/// A content-sized native copy button that copies only the exact address value.
private struct IOSAddressCopyTarget: View {
    let address: MailAddress
    let role: String
    let showsMonogram: Bool

    var body: some View {
        Button {
            UIPasteboard.general.string = address.address
        } label: {
            HStack(alignment: .center, spacing: 8) {
                if showsMonogram {
                    Text(monogram)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                        .frame(width: 28, height: 28)
                        .background(Color.accentColor.opacity(0.12), in: Circle())
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 1) {
                    if let displayName = address.displayName, !displayName.isEmpty {
                        Text(displayName)
                            .font(.subheadline.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(address.address)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.leading)
            }
        }
        .buttonStyle(.bordered)
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Copy \(role) address")
        .accessibilityValue(address.address)
        .accessibilityHint("Copies the exact email address")
    }

    private var monogram: String {
        let source = address.displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? address.displayName!
            : address.address.split(separator: "@", maxSplits: 1).first.map(String.init) ?? address.address
        let words = source.split(whereSeparator: { $0.isWhitespace })
        let initials = words.prefix(2).compactMap { $0.first.map(String.init) }.joined()
        return (initials.isEmpty ? String(source.prefix(2)) : initials).uppercased()
    }
}

/// Wraps address targets without stretching short targets into unused reader width.
private struct IOSAddressTargetLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat
    let layoutDirection: LayoutDirection

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let availableWidth = proposal.width ?? .infinity
        let sizes = targetSizes(subviews, availableWidth: availableWidth)
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var maxLineWidth: CGFloat = 0
        for size in sizes {
            if lineWidth > 0, lineWidth + horizontalSpacing + size.width > availableWidth {
                maxLineWidth = max(maxLineWidth, lineWidth)
                totalHeight += lineHeight + verticalSpacing
                lineWidth = 0
                lineHeight = 0
            }
            lineWidth = lineWidth == 0 ? size.width : lineWidth + horizontalSpacing + size.width
            lineHeight = max(lineHeight, size.height)
        }
        maxLineWidth = max(maxLineWidth, lineWidth)
        totalHeight += lineHeight
        return CGSize(
            width: proposal.width.map { min($0, maxLineWidth) } ?? maxLineWidth,
            height: totalHeight
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let sizes = targetSizes(subviews, availableWidth: bounds.width)
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        if layoutDirection == .rightToLeft {
            var x = bounds.maxX
            for (index, subview) in subviews.enumerated() {
                let size = sizes[index]
                if x < bounds.maxX, x - horizontalSpacing - size.width < bounds.minX {
                    x = bounds.maxX
                    y += lineHeight + verticalSpacing
                    lineHeight = 0
                }
                if x < bounds.maxX {
                    x -= horizontalSpacing
                }
                x -= size.width
                subview.place(
                    at: CGPoint(x: x + size.width / 2, y: y + size.height / 2),
                    anchor: .center,
                    proposal: ProposedViewSize(size)
                )
                lineHeight = max(lineHeight, size.height)
            }
        } else {
            var x = bounds.minX
            for (index, subview) in subviews.enumerated() {
                let size = sizes[index]
                if x > bounds.minX, x + horizontalSpacing + size.width > bounds.maxX {
                    x = bounds.minX
                    y += lineHeight + verticalSpacing
                    lineHeight = 0
                }
                if x > bounds.minX {
                    x += horizontalSpacing
                }
                subview.place(
                    at: CGPoint(x: x + size.width / 2, y: y + size.height / 2),
                    anchor: .center,
                    proposal: ProposedViewSize(size)
                )
                x += size.width
                lineHeight = max(lineHeight, size.height)
            }
        }
    }

    private func targetSizes(_ subviews: Subviews, availableWidth: CGFloat) -> [CGSize] {
        subviews.map { subview in
            let ideal = subview.sizeThatFits(.unspecified)
            guard availableWidth.isFinite, ideal.width > availableWidth else { return ideal }
            return subview.sizeThatFits(
                ProposedViewSize(width: availableWidth, height: nil)
            )
        }
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
                            .frame(minWidth: 44, minHeight: 44)
                            .accessibilityLabel("Share attachment")
                    } else {
                        Button { fetch(attachment) } label: {
                            if loadingID == attachment.id { ProgressView().controlSize(.small) }
                            else { Image(systemName: "arrow.down.circle") }
                        }
                        .frame(minWidth: 44, minHeight: 44)
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
