import AVFoundation
import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// A real AVFoundation QR scanner. The callback is invoked only for a decoded
/// QR payload; denied, restricted, and camera-less devices never synthesize a
/// scan result.
struct PairingCameraScannerView: View {
    @Environment(\.dismiss) private var dismiss
    let onCode: (String) -> Void

    @State private var status: PairingCameraStatus = .checking
    @State private var didDeliverCode = false

    var body: some View {
        NavigationStack {
            ZStack {
                switch status {
                case .checking:
                    ProgressView("Checking camera access…")
                case .ready:
                    PairingCameraPreview { code in
                        guard !didDeliverCode else { return }
                        didDeliverCode = true
                        onCode(code)
                    }
                    .accessibilityElement()
                    .accessibilityLabel("Camera viewfinder")
                    .accessibilityHint("Point the camera at a secure pairing QR code")
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(.white.opacity(0.55), lineWidth: 1)
                            .padding(1)
                    }
                    .overlay(alignment: .center) {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(.white.opacity(0.85), lineWidth: 2)
                            .frame(width: 240, height: 240)
                            .shadow(color: .black.opacity(0.35), radius: 8)
                            .accessibilityHidden(true)
                    }
                    .padding(18)
                case .denied:
                    PairingCameraUnavailableView(
                        title: "Camera access is off",
                        message: "Allow camera access in Settings to scan a pairing QR code. You can cancel and use another device to show a fresh code."
                    )
                case .restricted:
                    PairingCameraUnavailableView(
                        title: "Camera access is restricted",
                        message: "This device does not allow camera access. No QR code can be scanned here."
                    )
                case .unavailable:
                    PairingCameraUnavailableView(
                        title: "No camera available",
                        message: "This device has no usable camera. On Mac, choose a QR image file instead."
                    )
                }
            }
            .frame(minWidth: 320, minHeight: 420)
            .background(.black)
            .navigationTitle("Scan Pairing QR")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityLabel("Cancel QR scanning")
                }
            }
        }
        .task {
            await prepareCamera()
        }
    }

    private func prepareCamera() async {
        let authorization = AVCaptureDevice.authorizationStatus(for: .video)
        switch authorization {
        case .authorized:
            await setAvailability()
        case .notDetermined:
            let granted = await requestAccess()
            guard granted else {
                status = .denied
                return
            }
            await setAvailability()
        case .denied:
            status = .denied
        case .restricted:
            status = .restricted
        @unknown default:
            status = .restricted
        }
    }

    private func requestAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .video) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func setAvailability() async {
        let device = AVCaptureDevice.default(for: .video)
        status = device == nil ? .unavailable : .ready
    }
}

private enum PairingCameraStatus {
    case checking
    case ready
    case denied
    case restricted
    case unavailable
}

private struct PairingCameraUnavailableView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.slash")
                .font(.system(size: 38))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            #if os(iOS)
            Button("Open Settings") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
            .buttonStyle(.borderedProminent)
            #elseif os(macOS)
            Button("Open Camera Settings") {
                guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") else { return }
                NSWorkspace.shared.open(url)
            }
            .buttonStyle(.borderedProminent)
            #endif
        }
        .padding(28)
        .frame(maxWidth: 380)
        .accessibilityElement(children: .contain)
    }
}

#if os(iOS)
private struct PairingCameraPreview: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode)
    }

    func makeUIViewController(context: Context) -> PairingCameraViewController {
        PairingCameraViewController(onCode: context.coordinator.onCode)
    }

    func updateUIViewController(_ controller: PairingCameraViewController, context: Context) {}

    final class Coordinator {
        let onCode: (String) -> Void
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }
    }
}

private final class PairingCameraViewController: UIViewController {
    private let onCode: (String) -> Void
    private var pipeline: PairingCapturePipeline?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didDeliverCode = false

    init(onCode: @escaping (String) -> Void) {
        self.onCode = onCode
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let pipeline = PairingCapturePipeline(owner: self)
        pipeline.configure()
        self.pipeline = pipeline
        let preview = AVCaptureVideoPreviewLayer(session: pipeline.session)
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        previewLayer = preview
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        pipeline?.start()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        pipeline?.stop()
    }

    fileprivate func receive(code: String) {
        guard !didDeliverCode else { return }
        didDeliverCode = true
        onCode(code)
    }
}

/// AVCaptureSession is confined to this private serial queue. The unchecked
/// Sendable marker describes that ownership boundary; no session API is
/// accessed anywhere except through the queue's synchronized methods.
private final class PairingCapturePipeline: @unchecked Sendable {
    let session: AVCaptureSession
    private let queue = DispatchQueue(label: "org.kayg.mailternal.pairing.camera")
    private let metadataDelegate: PairingMetadataDelegate
    private var isConfigured = false

    init(owner: PairingCameraViewController) {
        session = AVCaptureSession()
        metadataDelegate = PairingMetadataDelegate(owner: owner)
    }

    func configure() {
        queue.sync {
            guard !isConfigured else { return }
            defer { isConfigured = true }
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input)
            else { return }
            session.beginConfiguration()
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                return
            }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(metadataDelegate, queue: queue)
            output.metadataObjectTypes = [.qr]
            session.commitConfiguration()
        }
    }

    func start() {
        queue.async {
            guard !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    func stop() {
        queue.async {
            guard self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }
}

private final class PairingMetadataDelegate: NSObject, AVCaptureMetadataOutputObjectsDelegate {
    weak var owner: PairingCameraViewController?

    init(owner: PairingCameraViewController) {
        self.owner = owner
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let code = metadataObjects
            .compactMap({ $0 as? AVMetadataMachineReadableCodeObject })
            .compactMap(\.stringValue)
            .first(where: { !$0.isEmpty })
        else { return }
        guard let owner else { return }
        Task { @MainActor in
            owner.receive(code: code)
        }
    }
}
#elseif os(macOS)
private struct PairingCameraPreview: NSViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode)
    }

    func makeNSViewController(context: Context) -> PairingCameraViewController {
        PairingCameraViewController(onCode: context.coordinator.onCode)
    }

    func updateNSViewController(_ controller: PairingCameraViewController, context: Context) {}

    final class Coordinator {
        let onCode: (String) -> Void
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }
    }
}

private final class PairingCameraViewController: NSViewController {
    private let onCode: (String) -> Void
    private var pipeline: PairingCapturePipeline?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didDeliverCode = false

    init(onCode: @escaping (String) -> Void) {
        self.onCode = onCode
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let pipeline = PairingCapturePipeline(owner: self)
        pipeline.configure()
        self.pipeline = pipeline
        let preview = AVCaptureVideoPreviewLayer(session: pipeline.session)
        preview.videoGravity = .resizeAspectFill
        view.layer?.addSublayer(preview)
        previewLayer = preview
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        pipeline?.start()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        pipeline?.stop()
    }

    fileprivate func receive(code: String) {
        guard !didDeliverCode else { return }
        didDeliverCode = true
        onCode(code)
    }
}

/// AVCaptureSession is confined to this private serial queue. The unchecked
/// Sendable marker describes that ownership boundary; no session API is
/// accessed anywhere except through the queue's synchronized methods.
private final class PairingCapturePipeline: @unchecked Sendable {
    let session: AVCaptureSession
    private let queue = DispatchQueue(label: "org.kayg.mailternal.pairing.camera")
    private let metadataDelegate: PairingMetadataDelegate
    private var isConfigured = false

    init(owner: PairingCameraViewController) {
        session = AVCaptureSession()
        metadataDelegate = PairingMetadataDelegate(owner: owner)
    }

    func configure() {
        queue.sync {
            guard !isConfigured else { return }
            defer { isConfigured = true }
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input)
            else { return }
            session.beginConfiguration()
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                return
            }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(metadataDelegate, queue: queue)
            output.metadataObjectTypes = [.qr]
            session.commitConfiguration()
        }
    }

    func start() {
        queue.async {
            guard !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    func stop() {
        queue.async {
            guard self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }
}

private final class PairingMetadataDelegate: NSObject, AVCaptureMetadataOutputObjectsDelegate {
    weak var owner: PairingCameraViewController?

    init(owner: PairingCameraViewController) {
        self.owner = owner
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let code = metadataObjects
            .compactMap({ $0 as? AVMetadataMachineReadableCodeObject })
            .compactMap(\.stringValue)
            .first(where: { !$0.isEmpty })
        else { return }
        guard let owner else { return }
        Task { @MainActor in
            owner.receive(code: code)
        }
    }
}
#endif
