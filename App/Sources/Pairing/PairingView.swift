import Foundation
import SwiftUI
import MailternalInterfaces
import MailternalPairing
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// Shared pairing surface used by the macOS and iOS shells.
///
/// Pairing remains direction-free until both devices authenticate. The caller
/// owns durable account and workspace persistence; this view only asks for a
/// bundle after an explicit Send action and imports it after explicit review.
struct PairingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let accounts: [AccountConfig]
    let makeBundle: @MainActor (Set<AccountID>, Bool) async throws -> PairingBundle
    let importBundle: @MainActor (PairingBundle, Set<AccountID>, Bool, Bool) async throws -> Void

    @State private var session: PairingSession
    @State private var selectedAccountIDs: Set<AccountID>
    @State private var includeSettings = false
    @State private var replaceExisting = false
    @State private var importSettings = false
    @State private var isScannerPresented = false
    @State private var isFileImporterPresented = false
    @State private var isFileExporterPresented = false
    @State private var offlineImportData: Data?
    @State private var offlineReceivedBundle: PairingBundle?
    @State private var offlineExportPassphrase: String?
    @State private var offlinePassphrase = ""
    @State private var offlineExportDocument: PairingEncryptedFileDocument?
    @State private var offlineImportCompleted = false
    #if os(macOS)
    @State private var isImageImporterPresented = false
    #endif
    @State private var isWorking = false
    @State private var viewError: String?
    @State private var didConfirmImport = false
    @State private var importTask: Task<Void, Never>?
    @State private var importOperationID = UUID()
    @State private var offlineTask: Task<Void, Never>?
    @State private var offlineOperationID = UUID()


    init(
        accounts: [AccountConfig],
        makeBundle: @escaping @MainActor (Set<AccountID>, Bool) async throws -> PairingBundle,
        importBundle: @escaping @MainActor (PairingBundle, Set<AccountID>, Bool, Bool) async throws -> Void
    ) {
        self.accounts = accounts
        self.makeBundle = makeBundle
        self.importBundle = importBundle
        let deviceName = PairingView.defaultDeviceName
        _session = State(initialValue: PairingSession(deviceName: deviceName))
        _selectedAccountIDs = State(initialValue: Set(accounts.map(\.id)))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    content
                }
                .frame(maxWidth: 620, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .navigationTitle("Pair Device")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) {
                        cancelAndDismiss()
                    }
                    .accessibilityLabel("Cancel pairing")
                }
            }
        }
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
            }
        }
        .onDisappear {
            // A dismissal must never leave an authenticated transport or an
            // in-flight durable import alive.
            cancelActiveImport()
            session.cancel()
            isScannerPresented = false
            clearOfflineTransfer()
        }
        .sheet(isPresented: $isScannerPresented) {
            PairingCameraScannerView { code in
                isScannerPresented = false
                join(code)
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.mailternalPairingBundle, .data],
            allowsMultipleSelection: false
        ) { result in
            handlePairingFileImport(result)
        }
        .fileExporter(
            isPresented: $isFileExporterPresented,
            document: offlineExportDocument,
            contentType: .mailternalPairingBundle,
            defaultFilename: "Mailternal Pairing.\(PairingFileTransfer.fileExtension)"
        ) { result in
            if case .failure(let error) = result {
                viewError = error.localizedDescription
            }
        }
        #if os(macOS)
        .fileImporter(
            isPresented: $isImageImporterPresented,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            handleImageImport(result)
        }
        #endif
        .onChange(of: session.receivedBundle?.accounts.map(\.id) ?? []) { _, ids in
            guard !ids.isEmpty else { return }
            selectedAccountIDs = Set(ids)
            replaceExisting = false
            importSettings = false
            didConfirmImport = false
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Secure device pairing", systemImage: "qrcode")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Connect two trusted devices with an encrypted, one-time pairing code. Passwords stay in Keychain and never appear in the QR code or this screen.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var content: some View {
        if offlineImportCompleted {
            completedContent(isOffline: true)
        } else if let offlineReceivedBundle {
            incomingBundleContent(offlineReceivedBundle, isOffline: true)
        } else {
            switch session.state {
            case .idle:
                idleContent
            case .advertising, .connecting:
                invitationContent
            case .connected, .sending:
                connectedContent
            case .received:
                receivedContent
            case .completed:
                completedContent()
            case .expired:
                terminalContent(
                    title: "Pairing expired",
                    message: "This invitation is no longer valid. Start a new pairing to try again.",
                    symbol: "clock.badge.xmark"
                )
            case .failed:
                terminalContent(
                    title: "Pairing failed",
                    message: session.errorMessage ?? viewError ?? "The secure pairing could not be completed.",
                    symbol: "exclamationmark.triangle"
                )
            }
        }
    }

    private var idleContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            PairingSurface {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Start on either device")
                        .font(.headline)
                    Text("Show a QR code on one device or scan a code shown on the other. Neither action chooses who sends the accounts.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button {
                            showCode()
                        } label: {
                            Label("Show QR", systemImage: "qrcode")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isWorking)
                        .accessibilityHint("Advertise a one-time pairing invitation")

                        Button {
                            isScannerPresented = true
                        } label: {
                            Label("Scan QR", systemImage: "qrcode.viewfinder")
                        }
                        .buttonStyle(.bordered)
                        .disabled(isWorking)
                        .accessibilityHint("Scan a pairing invitation with the camera")
                    }
                    #if os(macOS)
                    Button {
                        isImageImporterPresented = true
                    } label: {
                        Label("Scan an image file instead", systemImage: "photo.on.rectangle")
                    }
                    .buttonStyle(.link)
                    .disabled(isWorking)
                    .accessibilityHint("Choose a QR code image from this Mac")
                    #endif
                }
            }
            offlineContent
            if let viewError {
                errorBanner(viewError)
            }
        }
    }

    private var offlineContent: some View {
        PairingSurface {
            VStack(alignment: .leading, spacing: 14) {
                Label("Transfer without a network", systemImage: "externaldrive.fill")
                    .font(.headline)
                Text("Export an encrypted pairing file when the devices cannot reach the same network. Convey the generated passphrase separately from the file.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Include workspace settings", isOn: $includeSettings)
                    .disabled(isWorking)
                PairingAccountSelectionList(
                    title: "Accounts to export",
                    accounts: accounts,
                    selectedIDs: $selectedAccountIDs,
                    emptyMessage: "No accounts are configured on this device."
                )
                .disabled(isWorking)

                Button {
                    exportOfflineBundle()
                } label: {
                    Label(isWorking ? "Preparing encrypted file…" : "Export encrypted file", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking || selectedAccountIDs.isEmpty)
                .accessibilityHint("Encrypt the selected accounts and choose where to save the pairing file")

                if let offlineExportPassphrase {
                    Divider()
                    Label("Passphrase for this file", systemImage: "key.fill")
                        .font(.subheadline.weight(.medium))
                    Text(offlineExportPassphrase)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .accessibilityLabel("Generated file passphrase")
                    Text("Share this passphrase through a separate trusted channel. It is not stored in the file.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()
                Button {
                    isFileImporterPresented = true
                } label: {
                    Label("Import encrypted file", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .disabled(isWorking)
                .accessibilityHint("Choose a Mailternal pairing file to decrypt")

                if offlineImportData != nil {
                    SecureField("Generated passphrase", text: $offlinePassphrase)
                        .textContentType(.password)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isWorking)
                        .accessibilityHint("Enter the passphrase conveyed separately from the file")
                    Button {
                        decryptOfflineBundle()
                    } label: {
                        Label(isWorking ? "Decrypting…" : "Decrypt and review", systemImage: "lock.open")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isWorking || offlinePassphrase.isEmpty)
                }
            }
        }
    }

    private var invitationContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            PairingSurface {
                VStack(alignment: .center, spacing: 14) {
                    if let invitation = session.invitation,
                       !isInvitationExpired(invitation) {
                        PairingQRCodeView(invitation: invitation)
                        PairingExpiryLabel(expiresAt: invitation.expiresAt)
                    } else {
                        ProgressView()
                            .controlSize(.large)
                            .frame(width: 240, height: 240)
                        Text("Preparing secure invitation…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if session.state == .connecting {
                        Label("Connecting securely…", systemImage: "lock.rotation")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Have the other device scan this code, or start a fresh session to scan theirs.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    HStack(spacing: 10) {
                        Button {
                            scanDifferentCode()
                        } label: {
                            Label("Scan a different QR", systemImage: "qrcode.viewfinder")
                        }
                        .buttonStyle(.bordered)
                        .disabled(isWorking)

                    #if os(macOS)
                    Button {
                        scanDifferentImage()
                    } label: {
                        Label("Use image file", systemImage: "photo.on.rectangle")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isWorking)
                    #endif
                    }
                }
                .frame(maxWidth: .infinity)
            }
            connectionStatus
            if let viewError {
                errorBanner(viewError)
            }
            PairingCancelButton(action: cancelPairing)
        }
    }

    private var connectedContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            connectionStatus
            PairingSurface {
                VStack(alignment: .leading, spacing: 14) {
                    Label("Pairing code verified", systemImage: "checkmark.shield.fill")
                        .font(.headline)
                        .foregroundStyle(.green)
                    Text(session.peerName ?? "Paired device")
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)
                        .accessibilityLabel("Device-provided name \(session.peerName ?? "Paired device")")
                    Text("Choose what to do next. Either device may send or wait to receive.")
                        .font(.subheadline)

                    Toggle("Include workspace settings", isOn: $includeSettings)
                        .disabled(isWorking)
                        .accessibilityHint("This is separate from ongoing iCloud sync participation")
                    Text("Imported settings are a one-time choice and do not change your ongoing iCloud sync preference.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    PairingAccountSelectionList(
                        title: "Accounts to send",
                        accounts: accounts,
                        selectedIDs: $selectedAccountIDs,
                        emptyMessage: "No accounts are configured on this device. You can still wait to receive accounts."
                    )
                        .disabled(isWorking)

                    Button {
                        sendSelectedAccounts()
                    } label: {
                        Label(isWorking ? "Sending…" : "Send selected accounts", systemImage: "arrow.up.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking || selectedAccountIDs.isEmpty || session.state != .connected)
                    .accessibilityHint("Encrypt and send the selected accounts after confirmation")

                    Label("Waiting to receive keeps this session ready for the other device.", systemImage: "arrow.down.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let viewError {
                errorBanner(viewError)
            }
            PairingCancelButton(action: cancelPairing)
        }
    }

    @ViewBuilder
    private var receivedContent: some View {
        if let bundle = session.receivedBundle {
            incomingBundleContent(bundle)
        } else {
            connectionStatus
            ProgressView("Receiving encrypted accounts…")
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func incomingBundleContent(
        _ bundle: PairingBundle,
        isOffline: Bool = false
    ) -> some View {
        let incomingAccounts = bundle.accounts
        let existingIDs = Set(incomingAccounts.compactMap { incoming in
            existingAccount(for: incoming.config) == nil ? nil : incoming.id
        })
        return VStack(alignment: .leading, spacing: 14) {
            if !isOffline {
                connectionStatus
            }
            PairingSurface {
                VStack(alignment: .leading, spacing: 14) {
                    Label(
                        isOffline ? "Encrypted file ready to import" : "Accounts ready to import",
                        systemImage: isOffline ? "lock.doc.fill" : "arrow.down.circle.fill"
                    )
                    .font(.headline)
                    Text(
                        isOffline
                            ? "Review the authenticated contents before they are saved. Passwords are written directly to Keychain and are never shown here."
                            : "Review the accounts before they are saved. Passwords are written directly to Keychain and are never shown here."
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    PairingIncomingAccountList(
                        accounts: incomingAccounts,
                        selectedIDs: $selectedAccountIDs,
                        existingIDs: existingIDs
                    )
                    .disabled(isWorking)

                    if !existingIDs.isEmpty {
                        Toggle("Replace existing matching accounts", isOn: $replaceExisting)
                            .disabled(isWorking)
                            .accessibilityHint("Replace matching account settings and credential; the shared identity is adopted either way")
                        Text("Matching means the same account link identity or the same IMAP endpoint and username. Existing account settings and mailbox data remain unchanged by default, but a matching account adopts the transferred shared identity.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !bundle.settings.isEmpty {
                        Toggle("Import workspace settings", isOn: $importSettings)
                            .disabled(isWorking)
                            .accessibilityHint("This one-time import is separate from ongoing iCloud sync participation")
                        Text("This choice does not alter the ongoing iCloud sync preference.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        confirmImport(bundle, isOffline: isOffline)
                    } label: {
                        Label(
                            isWorking ? "Importing…" : "Confirm import",
                            systemImage: "checkmark.circle.fill"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking || selectedAccountIDs.isEmpty || didConfirmImport)
                    .accessibilityHint(
                        isOffline
                            ? "Save the selected accounts from this encrypted file"
                            : "Save the selected accounts and acknowledge receipt"
                    )
                }
            }
            if let viewError {
                errorBanner(viewError)
            }
            if isOffline {
                PairingCancelButton(title: "Cancel import", action: cancelOfflineImport)
            } else {
                PairingCancelButton(action: cancelPairing)
            }
        }
    }

    private func completedContent(isOffline: Bool = false) -> some View {
        PairingSurface {
            VStack(alignment: .leading, spacing: 14) {
                Label(
                    isOffline ? "Import complete" : "Pairing complete",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.title3.weight(.semibold))
                .foregroundStyle(.green)
                Text(
                    isOffline
                        ? "The selected encrypted data was imported locally and durably."
                        : "The selected encrypted data was acknowledged by the other device."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                Button("Pair another device", action: resetForFreshPairing)
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Discard this invitation and start a new secure pairing")
            }
        }
    }


    private func terminalContent(title: String, message: String, symbol: String) -> some View {
        PairingSurface {
            VStack(alignment: .leading, spacing: 14) {
                Label(title, systemImage: symbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Start a new pairing", action: resetForFreshPairing)
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Use a fresh invitation rather than reusing this one")
            }
        }
    }

    private var connectionStatus: some View {
        Group {
            if let peerName = session.peerName {
                Label("Pairing code verified for \(peerName)", systemImage: "lock.shield")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else if session.state == .connecting {
                Label("Verifying pairing code…", systemImage: "lock")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.subheadline)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityAddTraits(.isStaticText)
    }

    private func showCode() {
        guard !isWorking else { return }
        isWorking = true
        viewError = nil
        Task { @MainActor in
            do {
                try await session.showCode()
            } catch {
                viewError = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func join(_ qrString: String) {
        guard !isWorking, !qrString.isEmpty else { return }
        isWorking = true
        viewError = nil
        Task { @MainActor in
            do {
                try await session.join(qrString: qrString)
            } catch {
                viewError = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func sendSelectedAccounts() {
        guard !isWorking, !selectedAccountIDs.isEmpty, session.state == .connected else { return }
        isWorking = true
        viewError = nil
        Task { @MainActor in
            do {
                // Bundle creation intentionally happens only after explicit Send.
                let bundle = try await makeBundle(selectedAccountIDs, includeSettings)
                try await session.send(bundle)
            } catch {
                viewError = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func exportOfflineBundle() {
        guard !isWorking, !selectedAccountIDs.isEmpty else { return }
        isWorking = true
        viewError = nil
        let operationID = UUID()
        offlineOperationID = operationID
        let task = Task { @MainActor in
            defer {
                if offlineOperationID == operationID {
                    offlineTask = nil
                    isWorking = false
                }
            }
            do {
                // Bundle creation intentionally happens only after explicit export.
                let bundle = try await makeBundle(selectedAccountIDs, includeSettings)
                let passphrase = try PairingFileTransfer.makePassphrase()
                let data = try PairingFileTransfer.encrypt(bundle, passphrase: passphrase)
                try Task.checkCancellation()
                guard offlineOperationID == operationID else { return }
                offlineExportPassphrase = passphrase
                offlineExportDocument = PairingEncryptedFileDocument(data: data)
                isFileExporterPresented = true
            } catch is CancellationError {
                return
            } catch {
                guard offlineOperationID == operationID else { return }
                viewError = error.localizedDescription
            }
        }
        offlineTask = task
    }

    private func decryptOfflineBundle() {
        guard !isWorking, let data = offlineImportData else { return }
        isWorking = true
        viewError = nil
        let operationID = UUID()
        offlineOperationID = operationID
        let task = Task { @MainActor in
            defer {
                if offlineOperationID == operationID {
                    offlineTask = nil
                    isWorking = false
                }
            }
            do {
                let bundle = try PairingFileTransfer.decrypt(data, passphrase: offlinePassphrase)
                try Task.checkCancellation()
                guard offlineOperationID == operationID else { return }
                offlineReceivedBundle = bundle
                offlineImportData = nil
                offlinePassphrase = ""
                selectedAccountIDs = Set(bundle.accounts.map(\.id))
                replaceExisting = false
                importSettings = false
                didConfirmImport = false
            } catch is CancellationError {
                return
            } catch {
                guard offlineOperationID == operationID else { return }
                viewError = error.localizedDescription
            }
        }
        offlineTask = task
    }

    private func handlePairingFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let values = try url.resourceValues(forKeys: [.fileSizeKey])
                guard let fileSize = values.fileSize,
                      fileSize >= 0,
                      fileSize <= PairingFileTransfer.maximumFileBytes else {
                    throw PairingFileTransferError.fileTooLarge
                }
                let securityScoped = url.startAccessingSecurityScopedResource()
                defer {
                    if securityScoped {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                let fileHandle = try FileHandle(forReadingFrom: url)
                defer { try? fileHandle.close() }
                let data = try fileHandle.read(
                    upToCount: PairingFileTransfer.maximumFileBytes + 1
                ) ?? Data()
                guard data.count <= PairingFileTransfer.maximumFileBytes else {
                    throw PairingFileTransferError.fileTooLarge
                }
                offlineImportData = data
                offlinePassphrase = ""
                offlineReceivedBundle = nil
                offlineImportCompleted = false
                offlineExportPassphrase = nil
                offlineExportDocument = nil
                viewError = nil
            } catch {
                viewError = error.localizedDescription
            }
        case .failure(let error):
            // User cancellation is not an error surface.
            if (error as NSError).code != NSUserCancelledError {
                viewError = error.localizedDescription
            }
        }
    }

    private func cancelOfflineImport() {
        cancelActiveImport()
        offlineReceivedBundle = nil
        offlineImportData = nil
        offlinePassphrase = ""
        offlineImportCompleted = false
        selectedAccountIDs = Set(accounts.map(\.id))
        replaceExisting = false
        importSettings = false
        didConfirmImport = false
        viewError = nil
        isWorking = false
    }

    private func clearOfflineTransfer() {
        cancelOfflineImport()
        offlineExportPassphrase = nil
        offlineExportDocument = nil
        isFileImporterPresented = false
        isFileExporterPresented = false
    }

    private func cancelOfflineTask() {
        offlineOperationID = UUID()
        offlineTask?.cancel()
        offlineTask = nil
    }

    private func cancelActiveImport() {
        importOperationID = UUID()
        importTask?.cancel()
        importTask = nil
        cancelOfflineTask()
    }

    private func cancelPairing() {
        cancelActiveImport()
        isWorking = false
        session.cancel()
        isScannerPresented = false
        viewError = nil
    }

    private func cancelAndDismiss() {
        cancelActiveImport()
        isWorking = false
        session.cancel()
        isScannerPresented = false
        clearOfflineTransfer()
        dismiss()
    }

    private func resetForFreshPairing() {
        cancelActiveImport()
        session.cancel()
        clearOfflineTransfer()
        session = PairingSession(deviceName: Self.defaultDeviceName)
        selectedAccountIDs = Set(accounts.map(\.id))
        includeSettings = false
        replaceExisting = false
        importSettings = false
        didConfirmImport = false
        viewError = nil
        isWorking = false
    }

    private func confirmImport(_ bundle: PairingBundle, isOffline: Bool = false) {
        guard !isWorking, !selectedAccountIDs.isEmpty, !didConfirmImport else { return }
        isWorking = true
        viewError = nil
        didConfirmImport = true
        let operationID = UUID()
        importOperationID = operationID
        let pairingSession = session
        let task = Task { @MainActor in
            defer {
                if importOperationID == operationID {
                    importTask = nil
                    isWorking = false
                }
            }
            do {
                try await importBundle(bundle, selectedAccountIDs, replaceExisting, importSettings)
                try Task.checkCancellation()
                guard importOperationID == operationID else { return }
                if isOffline {
                    offlineReceivedBundle = nil
                    offlineExportPassphrase = nil
                    offlineImportData = nil
                    offlinePassphrase = ""
                    offlineImportCompleted = true
                } else {
                    try await pairingSession.completeImport()
                }
            } catch is CancellationError {
                return
            } catch {
                guard importOperationID == operationID else { return }
                didConfirmImport = false
                viewError = error.localizedDescription
            }
        }
        importTask = task
    }

    private func scanDifferentCode() {
        guard !isWorking else { return }
        resetForFreshPairing()
        isScannerPresented = true
    }
    #if os(macOS)
    private func scanDifferentImage() {
        guard !isWorking else { return }
        resetForFreshPairing()
        isImageImporterPresented = true
    }
    #endif


    private func isInvitationExpired(_ invitation: PairingInvitation?) -> Bool {
        guard let invitation else { return false }
        return invitation.expiresAt <= Date()
    }

    private func existingAccount(for config: AccountConfig) -> AccountConfig? {
        pairingMatchingAccount(config, in: accounts)
    }

    #if os(macOS)
    private func handleImageImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let code = try PairingQRScanner.qrString(from: url)
                join(code)
            } catch {
                viewError = error.localizedDescription
            }
        case .failure(let error):
            // User cancellation is not an error surface.
            if (error as NSError).code != NSUserCancelledError {
                viewError = error.localizedDescription
            }
        }
    }
    #endif

    private static var defaultDeviceName: String {
        #if os(iOS)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #endif
    }
}

private struct PairingEncryptedFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.mailternalPairingBundle] }
    static var writableContentTypes: [UTType] { [.mailternalPairingBundle] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw PairingFileTransferError.invalidFile
        }
        guard contents.count <= PairingFileTransfer.maximumFileBytes else {
            throw PairingFileTransferError.fileTooLarge
        }
        data = contents
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private extension UTType {
    static var mailternalPairingBundle: UTType {
        UTType(
            filenameExtension: PairingFileTransfer.fileExtension,
            conformingTo: .data
        ) ?? .data
    }
}

private struct PairingSurface<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.separator.opacity(0.45), lineWidth: 0.5)
            }
    }
}

private struct PairingCancelButton: View {
    let action: () -> Void
    let title: String

    init(title: String = "Cancel pairing", action: @escaping () -> Void) {
        self.action = action
        self.title = title
    }
    var body: some View {
        Button(title, role: .cancel, action: action)
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityHint(
                title == "Cancel import"
                    ? "Discard the decrypted pairing file without importing it"
                    : "End the authenticated pairing and discard this invitation"
            )
    }
}

private struct PairingExpiryLabel: View {
    let expiresAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = max(0, Int(expiresAt.timeIntervalSince(context.date).rounded(.up)))
            Label(
                seconds == 0 ? "Invitation expired" : "Expires in \(seconds.formatted()) seconds",
                systemImage: seconds == 0 ? "clock.badge.xmark" : "clock"
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(seconds > 15 ? Color.secondary : Color.orange)
            .accessibilityLabel(seconds == 0 ? "Invitation expired" : "Invitation expires in \(seconds) seconds")
        }
    }
}

/// Displays a QR invitation with one bounded 0.48-second grid reveal for each
/// distinct non-empty payload; Reduce Motion and lifecycle interruption show it
/// statically without replaying on unrelated state updates.
private struct PairingQRCodeView: View {
    let invitation: PairingInvitation

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealProgress: CGFloat = 0
    @State private var lastAnimatedPayload: String?

    var body: some View {
        Group {
            if let image = PairingQRRenderer.image(for: invitation.qrString) {
                Image(decorative: image, scale: 1, orientation: .up)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: 226, height: 226)
                    .mask {
                        PairingQRRevealMask(progress: revealProgress)
                    }
                    .padding(12)
                    .frame(width: 250, height: 250)
                    .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityLabel("Secure pairing QR code")
                    .accessibilityHint("Scan this code on the other device")
            } else {
                Label("QR code could not be generated", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .frame(width: 250, height: 250)
                    .accessibilityLabel("Secure pairing QR code unavailable")
            }
        }
        .accessibilityElement(children: .contain)
        // A new payload gets one 0.48-second, deterministic grid reveal.
        // Reduce Motion and lifecycle interruption force the complete code visible.
        .onChange(of: invitation.qrString, initial: true) { _, payload in
            beginReveal(for: payload)
        }
        .onChange(of: reduceMotion) { _, isReduced in
            if isReduced {
                revealCompletely()
            }
        }
        .onDisappear {
            revealCompletely()
        }
    }

    private func revealCompletely() {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            revealProgress = 1
        }
    }

    private func beginReveal(for payload: String) {
        guard !payload.isEmpty else {
            lastAnimatedPayload = nil
            revealCompletely()
            return
        }
        guard lastAnimatedPayload != payload else { return }

        lastAnimatedPayload = payload
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            revealProgress = 0
        }

        guard !reduceMotion else {
            revealCompletely()
            return
        }
        withAnimation(.easeOut(duration: 0.48)) {
            revealProgress = 1
        }
    }
}

/// Reveals the fixed QR image as deterministic grid tiles over 0.48 seconds.
/// The mask is payload-independent, so unrelated view updates never replay it.
nonisolated private struct PairingQRRevealMask: View, Animatable {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    private static let columns = 16
    private static let rows = 16
    private static let fadeWindow: CGFloat = 0.14

    var body: some View {
        Canvas { context, size in
            let progress = min(max(progress, 0), 1)
            guard progress > 0 else { return }
            if progress >= 1 {
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
                return
            }

            let columnWidth = size.width / CGFloat(Self.columns)
            let rowHeight = size.height / CGFloat(Self.rows)
            for row in 0..<Self.rows {
                for column in 0..<Self.columns {
                    let tile = row * Self.columns + column
                    let threshold = Self.threshold(for: tile)
                    let opacity = min(
                        1,
                        max(0, (progress - threshold) / Self.fadeWindow)
                    )
                    guard opacity > 0 else { continue }

                    let rect = CGRect(
                        x: CGFloat(column) * columnWidth,
                        y: CGFloat(row) * rowHeight,
                        width: columnWidth + 0.5,
                        height: rowHeight + 0.5
                    )
                    context.fill(
                        Path(rect),
                        with: .color(.white.opacity(Double(opacity)))
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }

    private static func threshold(for tile: Int) -> CGFloat {
        // A stable integer mix avoids Swift's process-randomized hash seed.
        var value = UInt64(tile) &* 2_654_435_761
        value ^= value >> 16
        return CGFloat(value % 1_000) / 1_000 * (1 - fadeWindow)
    }
}

private struct PairingAccountSelectionList: View {
    let title: String
    let accounts: [AccountConfig]
    @Binding var selectedIDs: Set<AccountID>
    let emptyMessage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            if accounts.isEmpty {
                Text(emptyMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(accounts, id: \.id) { account in
                        Toggle(isOn: selectionBinding(for: account.id)) {
                            PairingAccountRow(account: account)
                        }
                        .toggleStyle(.switch)
                        .padding(.vertical, 8)
                        .accessibilityLabel("Select \(PairingAccountRow.title(for: account))")
                        .accessibilityValue(selectedIDs.contains(account.id) ? "Selected" : "Not selected")
                        if account.id != accounts.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func selectionBinding(for id: AccountID) -> Binding<Bool> {
        Binding(
            get: { selectedIDs.contains(id) },
            set: { isSelected in
                if isSelected { selectedIDs.insert(id) } else { selectedIDs.remove(id) }
            }
        )
    }
}

private struct PairingIncomingAccountList: View {
    let accounts: [PairingAccount]
    @Binding var selectedIDs: Set<AccountID>
    let existingIDs: Set<AccountID>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Accounts received")
                .font(.headline)
            VStack(spacing: 0) {
                ForEach(accounts, id: \.id) { account in
                    Toggle(isOn: selectionBinding(for: account.id)) {
                        VStack(alignment: .leading, spacing: 3) {
                            PairingAccountRow(account: account.config)
                            if existingIDs.contains(account.id) {
                                Label("Existing account", systemImage: "arrow.triangle.2.circlepath")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    .toggleStyle(.switch)
                    .padding(.vertical, 8)
                    .accessibilityLabel("Select \(PairingAccountRow.title(for: account.config))")
                    .accessibilityValue(
                        existingIDs.contains(account.id)
                            ? (selectedIDs.contains(account.id) ? "Selected, existing" : "Not selected, existing")
                            : (selectedIDs.contains(account.id) ? "Selected" : "Not selected")
                    )
                    if account.id != accounts.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private func selectionBinding(for id: AccountID) -> Binding<Bool> {
        Binding(
            get: { selectedIDs.contains(id) },
            set: { isSelected in
                if isSelected { selectedIDs.insert(id) } else { selectedIDs.remove(id) }
            }
        )
    }
}

private struct PairingAccountRow: View {
    let account: AccountConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(Self.title(for: account))
                .font(.subheadline.weight(.medium))
            Text("\(account.imap.host):\(String(account.imap.port)) · \(account.username)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    static func title(for account: AccountConfig) -> String {
        let displayName = account.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return displayName.isEmpty ? account.emailAddress : displayName
    }
}
