import AppKit
import SwiftUI
import MailternalInterfaces

struct MessageViewer: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var viewerFocus

    var body: some View {
        ZStack(alignment: .topTrailing) {
            content
            if model.isFindPresented {
                FindBar(
                    query: $model.findQuery,
                    matchCount: findMatches.count,
                    selectedMatchNumber: findMatches.isEmpty ? nil : 1,
                    next: {},
                    previous: {},
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
            RawSourceView(text: raw)
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
                    allowRemoteImages: model.allowRemoteImages
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
            PlainTextBody(text: text, query: model.findQuery)
        } else {
            Text("This message has no text.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var findMatches: [Range<String.Index>] {
        guard let text = model.detail?.bodyText, !model.findQuery.isEmpty else { return [] }
        return text.ranges(of: model.findQuery)
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

    var body: some View {
        Text(attributed)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var attributed: AttributedString {
        let storage = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: MessageTypography.bodyFont,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: MessageTypography.bodyParagraphStyle,
            ]
        )
        if !query.isEmpty {
            let ns = NSString(string: text)
            var search = NSRange(location: 0, length: ns.length)
            while true {
                let found = ns.range(of: query, options: [.caseInsensitive], range: search)
                if found.location == NSNotFound { break }
                storage.addAttribute(.backgroundColor, value: NSColor.findHighlightColor, range: found)
                let next = found.location + max(found.length, 1)
                if next >= ns.length { break }
                search = NSRange(location: next, length: ns.length - next)
            }
        }
        return AttributedString(storage)
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

    var body: some View {
        Text(text)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
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

private extension String {
    func ranges(of query: String) -> [Range<String.Index>] {
        guard !query.isEmpty else { return [] }
        var result: [Range<String.Index>] = []
        var search = startIndex
        while let found = range(of: query, options: [.caseInsensitive], range: search..<endIndex) {
            result.append(found)
            search = found.upperBound
        }
        return result
    }
}
