import SwiftUI
import MailternalInterfaces

/// Fixed actions at the trailing edge of the reader tab row. Archive and Trash
/// stay one click away; every other message action is deliberately behind More.
struct ReaderActionsCluster: View {
    @Bindable var model: AppModel

    private var activeMessage: MessageID? {
        model.tabs.active?.message
    }

    private var selection: Set<MessageID> {
        activeMessage.map { [$0] } ?? []
    }

    private var flagStates: [MessageID: Bool] {
        Dictionary(uniqueKeysWithValues: model.listRows.map { ($0.id, $0.isFlagged) })
    }

    private var readStates: [MessageID: Bool] {
        Dictionary(uniqueKeysWithValues: model.listRows.map { ($0.id, $0.isRead) })
    }

    private var visibleItems: [MessageToolbarPolicy.VisibleItem] {
        MessageToolbarPolicy.visibleItems(
            selection: selection,
            flagStates: flagStates,
            effectiveEmailReadingMode: model.effectiveEmailReadingMode,
            isShowingRawSource: model.isShowingRawSource
        )
    }

    private var archiveTitle: String {
        visibleItems.first { $0.identifier == .archive }?.title ?? "Archive"
    }

    private var trashTitle: String {
        visibleItems.first { $0.identifier == .trash }?.title ?? "Trash"
    }

    var body: some View {
        HStack(spacing: ReaderTabLayoutPolicy.actionSpacing) {
            actionButton(
                systemImage: "archivebox",
                title: archiveTitle,
                enabled: activeMessage != nil
            ) {
                if let activeMessage { model.perform(.archive, on: activeMessage) }
            }
            actionButton(
                systemImage: "trash",
                title: trashTitle,
                enabled: activeMessage != nil
            ) {
                if let activeMessage { model.perform(.trash, on: activeMessage) }
            }
            moreMenu
        }
        .padding(.trailing, ReaderTabLayoutPolicy.actionsTrailingInset)
        .frame(
            width: ReaderTabLayoutPolicy.actionsClusterWidth,
            height: ReaderTabLayoutPolicy.rowHeight,
            alignment: .trailing
        )
        .accessibilityElement(children: .contain)
    }

    private func actionButton(
        systemImage: String,
        title: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(
                    width: ReaderTabLayoutPolicy.actionControlSize,
                    height: ReaderTabLayoutPolicy.actionControlSize
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.borderless)
        .focusEffectDisabled(true)
        .modifier(ReaderActionGlassModifier())
        .help(title)
        .accessibilityLabel(title)
        .disabled(!enabled)
    }

    private var moreMenu: some View {
        Menu {
            if let flag = visibleItems.first(where: { $0.identifier == .flag }), activeMessage != nil {
                Button(flag.title, systemImage: flag.imageName) {
                    if let activeMessage {
                        model.perform(.toggleFlag, on: activeMessage)
                    }
                }
                .disabled(!flag.isEnabled)
                Divider()
            }

            ForEach(Array(overflowItems.enumerated()), id: \.offset) { entry in
                policyMenuItem(entry.element)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(
                    width: ReaderTabLayoutPolicy.actionControlSize,
                    height: ReaderTabLayoutPolicy.actionControlSize
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .focusEffectDisabled(true)
        .buttonStyle(.borderless)
        .modifier(ReaderActionGlassModifier())
        .help("More message actions")
        .accessibilityLabel("More message actions")
        .disabled(activeMessage == nil)
    }

    private var overflowItems: [MessageContextMenuPolicy.Item] {
        MessageToolbarPolicy.overflowItems(
            selection: selection,
            isReadStates: readStates,
            flagStates: flagStates,
            folders: model.folders,
            current: model.selectedFolderID
        )
    }

    private func policyMenuItem(_ item: MessageContextMenuPolicy.Item) -> AnyView {
        if item.isSeparator {
            return AnyView(Divider())
        }
        if !item.children.isEmpty {
            return AnyView(
                Menu(item.title) {
                    ForEach(Array(item.children.enumerated()), id: \.offset) { entry in
                        policyMenuItem(entry.element)
                    }
                }
            )
        }
        return AnyView(
            Button(item.title) {
                perform(item.action)
            }
            .disabled(!item.isEnabled)
        )
    }


    private func perform(_ action: MessageContextMenuPolicy.Action?) {
        guard let action, let activeMessage else { return }
        let selected: Set<MessageID> = [activeMessage]
        switch action {
        case .markRead, .markUnread:
            model.perform(.toggleRead, on: selected)
        case .moveToJunk:
            guard let junk = model.folders.first(where: { $0.role == .junk }) else { return }
            model.move(ids: selected, to: junk.id)
        case .moveTo(let folder):
            model.move(ids: selected, to: folder)
        case .openInNewWindow:
            model.openMessageWindow(activeMessage)
        case .copyLink:
            Task { await model.copyDeepLink(for: activeMessage) }
        case .copySubject:
            model.copySubject(for: activeMessage)
        case .viewRawSource:
            model.toggleRawSource()
        case .toggleEmailReadingOverride:
            model.toggleEmailReadingOverride()
        case .delete:
            model.perform(.trash, on: activeMessage)
        case .archive:
            model.perform(.archive, on: activeMessage)
        case .flag, .unflag:
            model.perform(.toggleFlag, on: activeMessage)
        case .reply, .replyAll, .forward:
            break
        }
    }
}
private struct ReaderActionGlassModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background {
                Capsule()
                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.18))
            }
        } else {
            content.glassEffect(.regular.interactive(), in: .capsule)
        }
    }
}
