import AppKit
import SwiftUI
import MailternalInterfaces

struct SearchPanel: View {
    @Bindable var model: AppModel
    @FocusState private var fieldFocused: Bool
    @Namespace private var searchFocusScope
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hasAppeared = false

    var body: some View {
        GeometryReader { geometry in
            let panelWidth = min(680, max(280, geometry.size.width - 48))
            let maximumHeight = geometry.size.height / 3

            ZStack(alignment: .top) {
                // The backdrop lags the surface on both ends: it arrives as
                // the card lands and it is the last thing to go, so the card
                // never lingers as a ghost over an already-clear window.
                SearchPanelBackdrop()
                    .opacity(hasAppeared ? 1 : 0)
                    .animation(
                        hasAppeared
                            ? MailMotion.searchPanel(reduceMotion: reduceMotion)
                            : MailMotion.searchBackdropExit,
                        value: hasAppeared
                    )
                    .ignoresSafeArea()
                Rectangle()
                    .fill(.clear)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: dismiss)
                    .accessibilityHidden(true)

                SearchPanelSurface(
                    query: Binding(
                        get: { model.searchPresentation.query },
                        set: { model.setSearchQuery($0) }
                    ),
                    fieldFocused: $fieldFocused,
                    results: model.searchPresentation.results,
                    selectedResultID: model.searchPresentation.selectedResultID,
                    isSearching: model.searchPresentation.isSearching,
                    errorMessage: model.searchPresentation.errorMessage,
                    maximumHeight: maximumHeight,
                    contrast: contrast,
                    coverage: coverageDisclosure,
                    onMove: moveSelection,
                    onActivate: activateSelection,
                    onOpen: { messageID in
                        model.openSearchResult(messageID)
                    },
                    onCopyDeepLink: { messageID in
                        Task { await model.copyDeepLink(for: messageID) }
                    },
                    onClear: { model.setSearchQuery("") },
                    onDismiss: dismiss,
                    onRetry: { model.setSearchQuery(model.searchPresentation.query) }
                )
                .frame(width: panelWidth)
                .padding(.top, geometry.size.height / 3)
                .opacity(hasAppeared ? 1 : 0)
                .scaleEffect(reduceMotion ? 1 : (hasAppeared ? 1 : 0.985), anchor: .top)
                .offset(y: reduceMotion ? 0 : (hasAppeared ? 0 : -10))
                .animation(
                    hasAppeared
                        ? MailMotion.searchPanel(reduceMotion: reduceMotion)
                        : MailMotion.searchCardExit,
                    value: hasAppeared
                )
            }
            .onAppear {
                hasAppeared = true
            }
            .onDisappear {
                fieldFocused = false
                model.setSearchFieldFocused(false)
            }
            .task {
                await Task.yield()
                guard !Task.isCancelled else { return }
                fieldFocused = true
                model.setSearchFieldFocused(true)
            }
            .onExitCommand(perform: dismiss)
            .focusScope(searchFocusScope)
            .defaultFocus($fieldFocused, true)
            .onChange(of: fieldFocused) { _, focused in
                model.setSearchFieldFocused(focused)
            }
            .onChange(of: model.searchFieldFocused) { _, focused in
                guard fieldFocused != focused else { return }
                fieldFocused = focused
            }
        }
    }

    /// Windowed mode is a degraded state the app has to keep disclosing. The
    /// statement belongs where the user is actually searching, so it rides the
    /// search panel instead of standing as permanent chrome over the message
    /// list.
    private var coverageDisclosure: String? {
        guard case .windowed(let since) = model.syncStatus.mode else { return nil }
        return "Search covers mail since \(MailDateFormat.syncedThrough(since))"
    }

    private func dismiss() {
        fieldFocused = false
        model.setSearchFieldFocused(false)
        model.cancelSearch()
        guard hasAppeared else {
            guard model.isSearchPresented else { return }
            model.toggleSearch()
            return
        }
        // Card first, then backdrop, then remove the overlay once both
        // have finished; removing it immediately would cut the backdrop
        // (an AppKit view) before the card had faded.
        hasAppeared = false
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(MailMotion.searchDismissDuration))
            guard !hasAppeared, model.isSearchPresented else { return }
            model.toggleSearch()
        }
    }

    private func moveSelection(_ delta: Int) {
        let presentation = model.searchPresentation
        guard !presentation.results.isEmpty else { return }
        let current = presentation.selectedResultID
            .flatMap { id in presentation.results.firstIndex { $0.id == id } }
            ?? (delta > 0 ? -1 : presentation.results.count)
        let next = min(max(current + delta, 0), presentation.results.count - 1)
        model.selectSearchResult(presentation.results[next].id)
    }

    private func activateSelection() {
        let presentation = model.searchPresentation
        let messageID = presentation.selectedResultID ?? presentation.results.first?.id
        guard let messageID else { return }
        model.openSearchResult(messageID)
    }
}

private struct SearchPanelBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .fullScreenUI
        view.blendingMode = .withinWindow
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.state = .active
    }
}

private struct SearchPanelSurface: View {
    @Binding var query: String
    var fieldFocused: FocusState<Bool>.Binding
    let results: [MessageRow]
    let selectedResultID: MessageID?
    let isSearching: Bool
    let errorMessage: String?
    let maximumHeight: CGFloat
    let contrast: ColorSchemeContrast
    let coverage: String?
    let onMove: (Int) -> Void
    let onActivate: () -> Void
    let onOpen: (MessageID) -> Void
    let onCopyDeepLink: (MessageID) -> Void
    let onClear: () -> Void
    let onDismiss: () -> Void
    let onRetry: () -> Void
    @Environment(AccentSource.self) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            field
                .padding(.horizontal, 18)
                .padding(.vertical, 15)
            if let coverage {
                Text(coverage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                    .accessibilityIdentifier(UIIdentifier.searchCoverage)
            }
            content
        }
        .frame(maxHeight: maximumHeight, alignment: .top)
        .accessibilityIdentifier(UIIdentifier.searchPanel)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: AppShapeScale.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppShapeScale.card, style: .continuous)
                .strokeBorder(
                    contrast == .increased ? Color.primary : Color.primary.opacity(0.18),
                    lineWidth: contrast == .increased ? 1.5 : 0.75
                )
        }
        .shadow(color: .black.opacity(0.28), radius: 28, y: 14)
        .onMoveCommand { direction in
            switch direction {
            case .up: onMove(-1)
            case .down: onMove(1)
            default: break
            }
        }
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("Search all messages", text: $query)
                .textFieldStyle(.plain)
                .accessibilityIdentifier(UIIdentifier.searchField)
                .font(.system(size: 17, weight: .regular, design: .rounded))
                .focused(fieldFocused)
                .onSubmit(onActivate)
                .onKeyPress(.downArrow) {
                    onMove(1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    onMove(-1)
                    return .handled
                }
                .onKeyPress(.escape) {
                    onDismiss()
                    return .handled
                }
            if !query.isEmpty {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
            Button(action: onDismiss) {
                Image(systemName: "escape")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Dismiss search")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .glassEffect(.clear.interactive(), in: .capsule)
    }

    @ViewBuilder
    private var content: some View {
        if query.isEmpty {
            empty
        } else if isSearching {
            HStack(spacing: 11) {
                ProgressView().controlSize(.small)
                Text("Searching messages…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(22)
        } else if let errorMessage {
            VStack(alignment: .leading, spacing: 8) {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Try Again", action: onRetry)
                    .controlSize(.small)
            }
            .padding(20)
        } else if results.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Text("No results for “\(query)”")
                    .font(.headline)
                Text("Search covers the mail that has been synced on this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(results) { row in
                            Button { onOpen(row.id) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(row.subject)
                                        .font(.body.weight(selectedResultID == row.id ? .semibold : .regular))
                                        .lineLimit(2)
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text(row.from)
                                        Spacer(minLength: 8)
                                        if let accountName = row.accountName, !accountName.isEmpty {
                                            Text(accountName)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                        if !row.folderName.isEmpty {
                                            Text(row.folderName)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                        Text(MailDateFormat.listRow(row.date))
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    selectedResultID == row.id
                                        ? accent.color.opacity(contrast == .increased ? 0.24 : 0.12)
                                        : Color.clear,
                                    in: RoundedRectangle(cornerRadius: AppShapeScale.row, style: .continuous)
                                )
                            }
                            .buttonStyle(.plain)
                            .id(row.id)
                            .contextMenu {
                                Button("Copy Deep Link") {
                                    onCopyDeepLink(row.id)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
                .onChange(of: selectedResultID) { _, messageID in
                    guard let messageID,
                          results.contains(where: { $0.id == messageID })
                    else { return }
                    if reduceMotion {
                        proxy.scrollTo(messageID, anchor: .center)
                    } else {
                        withAnimation(MailMotion.disclosure) {
                            proxy.scrollTo(messageID, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Search every message")
                .font(.headline)
            Text("Find words and phrases across the mail that has been synced.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Label("Use ↑ and ↓ to choose a result, then press Return", systemImage: "arrow.up.arrow.down")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
