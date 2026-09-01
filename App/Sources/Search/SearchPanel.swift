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
    @State private var query = ""
    @State private var results: [MessageRow] = []
    @State private var selectedIndex: Int?
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            let panelWidth = min(680, max(280, geometry.size.width - 48))
            let maximumHeight = geometry.size.height / 3

            ZStack(alignment: .top) {
                SearchPanelBackdrop()
                    .opacity(hasAppeared ? 1 : 0)
                    .ignoresSafeArea()
                Rectangle()
                    .fill(.clear)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: dismiss)
                    .accessibilityHidden(true)

                SearchPanelSurface(
                    query: $query,
                    fieldFocused: $fieldFocused,
                    results: results,
                    selectedIndex: selectedIndex,
                    isSearching: isSearching,
                    errorMessage: errorMessage,
                    maximumHeight: maximumHeight,
                    contrast: contrast,
                    coverage: coverageDisclosure,
                    onMove: moveSelection,
                    onActivate: activateSelection,
                    onOpen: { row in
                        model.openSearchResult(row)
                        model.toasts.isSuppressed = false
                    },
                    onCopyDeepLink: { messageID in
                        Task { await model.copyDeepLink(for: messageID) }
                    },
                    onClear: { query = "" },
                    onDismiss: dismiss,
                    onRetry: { runSearch(query) }
                )
                .frame(width: panelWidth)
                .padding(.top, geometry.size.height / 3)
                .opacity(hasAppeared ? 1 : 0)
                .scaleEffect(reduceMotion ? 1 : (hasAppeared ? 1 : 0.985), anchor: .top)
                .offset(y: reduceMotion ? 0 : (hasAppeared ? 0 : -10))
            }
            .animation(MailMotion.searchPanel(reduceMotion: reduceMotion), value: hasAppeared)
            .onAppear { hasAppeared = true }
            .onDisappear { fieldFocused = false }
            .task {
                await Task.yield()
                guard !Task.isCancelled else { return }
                fieldFocused = true
            }
            .onExitCommand(perform: dismiss)
            .focusScope(searchFocusScope)
            .defaultFocus($fieldFocused, true)
            .onChange(of: query) { _, newValue in
                runSearch(newValue)
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
        model.isSearchPresented = false
        model.toasts.isSuppressed = false
    }

    private func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        let current = selectedIndex ?? (delta > 0 ? -1 : results.count)
        let next = min(max(current + delta, 0), results.count - 1)
        selectedIndex = next
    }

    private func activateSelection() {
        let index = selectedIndex ?? 0
        guard results.indices.contains(index) else { return }
        model.openSearchResult(results[index])
        model.toasts.isSuppressed = false
    }

    private func runSearch(_ text: String) {
        searchTask?.cancel()
        guard let trimmed = SearchQueryPolicy.normalizedQuery(text) else {
            results = []
            selectedIndex = nil
            isSearching = false
            errorMessage = nil
            return
        }
        isSearching = true
        errorMessage = nil
        searchTask = Task {
            try? await Task.sleep(for: SearchQueryPolicy.debounce)
            guard !Task.isCancelled else { return }
            do {
                let hits = try await model.facade.search(trimmed, limit: 40)
                guard !Task.isCancelled else { return }
                results = hits
                selectedIndex = hits.isEmpty ? nil : 0
                isSearching = false
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                isSearching = false
            }
        }
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
    let selectedIndex: Int?
    let isSearching: Bool
    let errorMessage: String?
    let maximumHeight: CGFloat
    let contrast: ColorSchemeContrast
    let coverage: String?
    let onMove: (Int) -> Void
    let onActivate: () -> Void
    let onOpen: (MessageRow) -> Void
    let onCopyDeepLink: (MessageID) -> Void
    let onClear: () -> Void
    let onDismiss: () -> Void
    let onRetry: () -> Void
    @Environment(AccentSource.self) private var accent

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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, row in
                        Button { onOpen(row) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.subject)
                                    .font(.body.weight(selectedIndex == index ? .semibold : .regular))
                                    .lineLimit(2)
                                HStack {
                                    Text(row.from)
                                    Spacer()
                                    Text(MailDateFormat.listRow(row.date))
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                selectedIndex == index
                                    ? accent.color.opacity(contrast == .increased ? 0.24 : 0.12)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: AppShapeScale.row, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
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
