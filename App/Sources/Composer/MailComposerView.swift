import SwiftUI
import QuickLook
import UniformTypeIdentifiers
import MailternalInterfaces

/// One system sheet hosts the editor and its saved drafts/outbox. It never
/// dismisses an unsaved edit; queued mail remains visible as delivery progresses.
struct MailComposerPresentation: ViewModifier {
    @Bindable var controller: MailComposerController

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $controller.isPresented) {
                NavigationStack {
                    if let editor = controller.editor {
                        MailComposerView(controller: controller, editor: editor)
                    } else {
                        MailOutgoingView(controller: controller)
                    }
                }
                #if os(macOS)
                .frame(minWidth: 560, idealWidth: 680, minHeight: 520, idealHeight: 680)
                #endif
                .interactiveDismissDisabled(
                    controller.editor?.isDirty == true || controller.editor?.isBusy == true
                )
            }
            .alert("Couldn’t open message", isPresented: Binding(
                get: { controller.errorMessage != nil && !controller.isPresented },
                set: { if !$0 { controller.errorMessage = nil } }
            )) {
                Button("OK") { controller.errorMessage = nil }
            } message: {
                Text(controller.errorMessage ?? "")
            }
    }
}

struct MailComposeButton: View {
    let controller: MailComposerController
    var preferredAccountID: AccountID?

    private var preferredAccount: AccountConfig? {
        controller.facade.accounts.first { $0.id == preferredAccountID }
            ?? controller.facade.accounts.first { $0.isEnabled }
            ?? controller.facade.accounts.first
    }

    var body: some View {
        Menu {
            ForEach(controller.facade.accounts, id: \.id) { account in
                Button(account.displayName.isEmpty ? account.emailAddress : "\(account.displayName) — \(account.emailAddress)") {
                    Task { await controller.newMessage(account: account) }
                }
            }
        } label: {
            Label("New Message", systemImage: "square.and.pencil")
        } primaryAction: {
            if let account = preferredAccount {
                Task { await controller.newMessage(account: account) }
            }
        }
        .disabled(preferredAccount == nil || controller.isOpening || controller.editor?.isBusy == true)
        .accessibilityIdentifier("compose-message")
    }
}

private struct MailComposerView: View {
    @Bindable var controller: MailComposerController
    @Bindable var editor: MailComposerModel
    @FocusState private var focusedField: String?
    @State private var showsOtherRecipients = false
    @State private var showsImporter = false
    @State private var confirmsDiscard = false
    @State private var previewURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("From", value: editor.draft.content.from.address)
                        .textSelection(.enabled)
                    recipient("To", text: $editor.toText, field: "to")
                    DisclosureGroup("Cc / Bcc", isExpanded: $showsOtherRecipients) {
                        recipient("Cc", text: $editor.ccText, field: "cc")
                        recipient("Bcc", text: $editor.bccText, field: "bcc")
                    }
                    TextField("Subject", text: $editor.subject)
                        .focused($focusedField, equals: "subject")
                        .accessibilityIdentifier("composer-subject")
                }
                Section {
                    TextEditor(text: $editor.body)
                        .font(.body)
                        .frame(minHeight: 220)
                        .focused($focusedField, equals: "body")
                        .accessibilityLabel("Message")
                        .accessibilityIdentifier("composer-body")
                }
                if !editor.attachments.isEmpty {
                    Section("Attachments") {
                        ForEach(editor.attachments) { attachment in
                            HStack {
                                Button {
                                    Task {
                                        do { previewURL = try await editor.attachmentURL(attachment) }
                                        catch { editor.errorMessage = error.localizedDescription }
                                    }
                                } label: {
                                    Label(attachment.filename, systemImage: "doc")
                                        .lineLimit(1)
                                }
                                .buttonStyle(.plain)
                                Spacer()
                                Text(attachment.byteCount.formatted(.byteCount(style: .file)))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button(role: .destructive) { editor.removeAttachment(attachment) } label: {
                                    Label("Remove \(attachment.filename)", systemImage: "xmark")
                                        .labelStyle(.iconOnly)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                if let conflict = editor.conflictMessage {
                    Section {
                        Label(conflict, systemImage: "doc.on.doc")
                            .foregroundStyle(.secondary)
                    }
                } else if editor.hasExternalChanges {
                    Section {
                        Text("This draft changed elsewhere. Saving your edits will keep both versions.")
                        if !editor.isDirty {
                            Button("Load Updated Draft") {
                                Task { await controller.openDraft(editor.draft.id) }
                            }
                        }
                    }
                }
                if let reason = editor.sendingUnavailableReason {
                    Section { Label(reason, systemImage: "exclamationmark.circle") }
                }
                if let error = editor.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                        if editor.isDirty {
                            Button("Save Again") {
                                Task {
                                    do { try await editor.flush() }
                                    catch { editor.errorMessage = error.localizedDescription }
                                }
                            }
                        }
                    }
                }
                Section {
                    Text(editor.saveStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("composer-save-status")
                }
            }
            .formStyle(.grouped)
            .disabled(editor.isBusy || editor.requiresReview)
            #if os(macOS)
            HStack {
                composerAccessories
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            #endif
        }
        .navigationTitle(editor.subject.isEmpty ? "New Message" : editor.subject)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .cancellationAction) {
                Button(editor.requiresReview ? "Review Drafts" : (controller.returnsToLibrary ? "Drafts & Outbox" : "Save Draft")) {
                    Task {
                        if editor.requiresReview { await controller.showLibrary() }
                        else { await controller.closeEditor() }
                    }
                }
                .keyboardShortcut(.cancelAction)
                .disabled(editor.isBusy)
            }
            #if os(iOS)
            ToolbarItemGroup(placement: .primaryAction) {
                composerAccessories
            }
            #endif
            ToolbarItem(placement: .confirmationAction) {
                Button { Task { await controller.send() } } label: {
                    Label("Send", systemImage: "paperplane")
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!editor.canSend)
                .accessibilityIdentifier("composer-send")
            }
        }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await editor.addAttachments(urls) }
            case .failure(let error): editor.errorMessage = error.localizedDescription
            }
        }
        .quickLookPreview($previewURL)
        .confirmationDialog("Discard this draft?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
            Button("Discard Draft", role: .destructive) { Task { await controller.discardEditor() } }
        } message: {
            Text("This deletes the saved draft, not any message already queued for delivery.")
        }
        .onAppear {
            showsOtherRecipients = !editor.ccText.isEmpty || !editor.bccText.isEmpty
            focusedField = editor.toText.isEmpty ? "to" : "body"
        }
        .onChange(of: focusedField) { _, value in editor.focusedField = value }
        .onChange(of: editor.focusedField) { _, value in focusedField = value }
    }

    /// macOS sheets keep accessories in a persistent footer because their
    /// custom hosting toolbar only presents the modal actions.
    @ViewBuilder
    private var composerAccessories: some View {
        Button { showsImporter = true } label: { Label("Attach File", systemImage: "paperclip") }
            .disabled(editor.isBusy || editor.requiresReview)
            .accessibilityIdentifier("composer-attach")
        Menu {
            Button("Discard Draft", role: .destructive) { confirmsDiscard = true }
        } label: { Label("More", systemImage: "ellipsis") }
        .disabled(editor.isBusy || editor.requiresReview)
    }

    private func recipient(_ title: String, text: Binding<String>, field: String) -> some View {
        TextField(title, text: text, axis: .vertical)
            #if os(iOS)
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            #endif
            .focused($focusedField, equals: field)
            .accessibilityIdentifier("composer-\(field)")
    }
}

private struct MailOutgoingView: View {
    @Bindable var controller: MailComposerController
    @State private var duplicateRisk: OutboxSummary?
    @State private var draftToDelete: DraftSummary?

    var body: some View {
        List {
            if let error = controller.errorMessage {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            }
            Section("Drafts") {
                if controller.outgoing.drafts.isEmpty {
                    Text("No saved drafts").foregroundStyle(.secondary)
                }
                ForEach(controller.outgoing.drafts) { draft in
                    Button { Task { await controller.openDraft(draft.id) } } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(draft.subject.isEmpty ? "No Subject" : draft.subject)
                                .foregroundStyle(.primary)
                            HStack {
                                Text(accountName(draft.accountID))
                                if draft.conflictOf != nil { Label("Saved conflict copy", systemImage: "doc.on.doc") }
                                if draft.attachmentCount > 0 {
                                    Label("\(draft.attachmentCount)", systemImage: "paperclip")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .contextMenu {
                        Button("Delete Draft", role: .destructive) { draftToDelete = draft }
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { draftToDelete = draft }
                    }
                }
            }
            Section("Outbox") {
                if controller.outgoing.outbox.isEmpty {
                    Text("No outgoing messages").foregroundStyle(.secondary)
                }
                ForEach(controller.outgoing.outbox) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.subject.isEmpty ? "No Subject" : item.subject)
                        Label(item.state.deliveryTitle, systemImage: item.state.deliverySymbol)
                            .font(.subheadline)
                            .foregroundStyle(item.state == .failed || item.state == .deliveryUnknown ? Color.red : Color.secondary)
                        Text(accountName(item.accountID)).font(.caption).foregroundStyle(.secondary)
                        if let failure = item.failure { Text(failure.message).font(.caption) }
                        HStack {
                            if item.state == .failed || item.state == .deliveryUnknown || item.state == .sentCopyPending {
                                Button(item.state == .sentCopyPending ? "Retry Sent Copy" : "Retry") {
                                    if item.state == .deliveryUnknown { duplicateRisk = item }
                                    else { Task { await controller.retry(item) } }
                                }
                            }
                            if [.queued, .preparing, .sending].contains(item.state) {
                                Button("Cancel Delivery", role: .destructive) {
                                    Task { await controller.cancel(item) }
                                }
                            }
                            if item.state == .failed || item.state == .cancelled {
                                Button("Open Draft") { Task { await controller.openDraft(item.draftID) } }
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .contain)
                }
            }
        }
        .navigationTitle("Drafts & Outbox")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { controller.isPresented = false; controller.returnsToLibrary = false }
            }
            ToolbarItem(placement: .primaryAction) { MailComposeButton(controller: controller) }
        }
        .confirmationDialog("Delivery status unknown", isPresented: Binding(
            get: { duplicateRisk != nil }, set: { if !$0 { duplicateRisk = nil } }
        ), titleVisibility: .visible) {
            if let item = duplicateRisk {
                Button("Send Again — Duplicate Possible", role: .destructive) {
                    Task { await controller.retry(item, acknowledgeDuplicateRisk: true) }
                    duplicateRisk = nil
                }
            }
        } message: {
            Text("The server may already have delivered this message. Retrying can send a duplicate. Check Sent or confirm with the recipient first.")
        }
        .confirmationDialog("Delete this saved draft?", isPresented: Binding(
            get: { draftToDelete != nil }, set: { if !$0 { draftToDelete = nil } }
        ), titleVisibility: .visible) {
            if let draft = draftToDelete {
                Button("Delete Draft", role: .destructive) {
                    Task { await controller.delete(draft) }
                    draftToDelete = nil
                }
            }
        }
    }

    private func accountName(_ id: AccountID) -> String {
        guard let account = controller.facade.accounts.first(where: { $0.id == id }) else { return "Unavailable account" }
        return account.displayName.isEmpty ? account.emailAddress : account.displayName
    }
}

private extension OutboxState {
    var deliveryTitle: String {
        switch self {
        case .queued: "Queued"
        case .preparing: "Preparing message"
        case .sending: "Sending"
        case .awaitingAcceptance: "Waiting for server confirmation"
        case .deliveryUnknown: "Delivery status unknown"
        case .failed: "Delivery failed"
        case .cancelled: "Delivery cancelled"
        case .sentCopyPending: "Sent · Saving Sent copy"
        case .sent: "Sent"
        }
    }
    var deliverySymbol: String {
        switch self {
        case .queued: "clock"
        case .preparing, .sending, .awaitingAcceptance: "paperplane"
        case .deliveryUnknown, .failed: "exclamationmark.triangle"
        case .cancelled: "xmark.circle"
        case .sentCopyPending: "tray.and.arrow.down"
        case .sent: "checkmark.circle"
        }
    }
}
