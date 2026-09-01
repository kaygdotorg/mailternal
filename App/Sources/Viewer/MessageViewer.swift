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
        .onChange(of: model.detail?.id) { _, _ in
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
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    EnvelopeHeader(envelope: detail.envelope, attachments: detail.attachments)
                    if detail.isQuarantined {
                        QuarantineBanner(
                            showingRaw: model.isShowingRawSource,
                            loadRaw: { Task { await model.loadRawSource() } }
                        )
                    }
                    bodyBlock(detail)
                }
                .frame(maxWidth: MessageTypography.readingMeasure, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(MessageTypography.transcriptInset)
                .padding(.bottom, 40)
            }
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.001))
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

    @ViewBuilder
    private func bodyBlock(_ detail: MessageDetail) -> some View {
        if model.isShowingRawSource, let raw = model.rawSource {
            RawSourceView(
                text: raw,
                query: activeFindQuery,
                selectedMatchIndex: findSnapshot.index,
                findTick: findTick
            )
        } else if detail.isQuarantined {
            Text("The original source is available if you need it.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if let html = detail.sanitizedHTML, !html.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                MessageHTMLView(
                    html: html,
                    partProvider: model.partProvider(for: detail.id),
                    onExternalLink: { url in
                        NSWorkspace.shared.open(url)
                    },
                    allowRemoteImages: model.allowRemoteImages,
                    findQuery: activeFindQuery,
                    findTick: findTick,
                    findBackwards: findBackwards
                )
                .frame(minHeight: 280)
                Button(model.allowRemoteImages ? "Remote Images On" : "Load Remote Images") {
                    model.allowRemoteImages = true
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .disabled(model.allowRemoteImages)
            }
        } else if let text = detail.bodyText, !text.isEmpty {
            PlainTextBody(
                text: text,
                query: activeFindQuery,
                selectedMatchIndex: findSnapshot.index,
                findTick: findTick
            )
        } else {
            Text("This message has no text.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
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

struct EnvelopeHeader: View {
    let envelope: Envelope
    let attachments: [AttachmentInfo]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(envelope.subject)
                .font(.title2)
                .textSelection(.enabled)
            LabeledContent("From") {
                Text(format(envelope.from))
                    .textSelection(.enabled)
            }
            if !envelope.to.isEmpty {
                LabeledContent("To") {
                    Text(format(envelope.to))
                        .textSelection(.enabled)
                }
            }
            if !envelope.cc.isEmpty {
                LabeledContent("Cc") {
                    Text(format(envelope.cc))
                        .textSelection(.enabled)
                }
            }
            LabeledContent("Date") {
                Text(MailDateFormat.envelope(envelope.internalDate))
            }
            if !attachments.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "paperclip")
                        .foregroundStyle(.secondary)
                    Text(attachments.map { $0.filename ?? $0.id }.joined(separator: ", "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .font(.subheadline)
        .labeledContentStyle(.automatic)
        .padding(.bottom, 4)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func format(_ addresses: [MailAddress]) -> String {
        addresses.map { address in
            if let name = address.displayName, !name.isEmpty {
                return "\(name) <\(address.address)>"
            }
            return address.address
        }.joined(separator: ", ")
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
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: AppShapeScale.compact, style: .continuous))
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
        let width = proposal.width ?? MessageTypography.readingMeasure
        nsView.textContainer?.containerSize = NSSize(width: max(width, 1), height: .greatestFiniteMagnitude)
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
