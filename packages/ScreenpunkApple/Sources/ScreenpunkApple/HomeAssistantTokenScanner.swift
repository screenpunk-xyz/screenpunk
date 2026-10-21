#if os(iOS)
import AVFoundation
import SwiftUI
import UIKit

struct HomeAssistantTokenScanner: View {
    @Environment(\.dismiss) private var dismiss
    let onToken: (String) -> Void
    @State private var error: String?
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Point the camera at the token QR code shown by Home Assistant.").padding(.horizontal)
                if let error {
                    Text(error).padding()
                    Button("Open iPad Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                } else {
                    TokenCamera(onToken: onToken, onError: { error = $0 })
                        .clipShape(RoundedRectangle(cornerRadius: 16)).padding()
                }
                Text("The code is read on this device. It is never opened in a browser.").font(.footnote).padding()
            }.navigationTitle("Scan access token")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
private struct TokenCamera: UIViewControllerRepresentable {
    let onToken: (String) -> Void
    let onError: (String) -> Void
    func makeUIViewController(context: Context) -> TokenCameraController { TokenCameraController(onToken: onToken, onError: onError) }
    func updateUIViewController(_ controller: TokenCameraController, context: Context) { }
    static func dismantleUIViewController(_ controller: TokenCameraController, coordinator: ()) { controller.stop() }
}
private final class TokenCameraController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "xyz.screenpunk.token-qr")
    private var preview: AVCaptureVideoPreviewLayer?
    private var active = false
    private var delivered = false
    private let onToken: (String) -> Void
    private let onError: (String) -> Void
    init(onToken: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
        self.onToken = onToken; self.onError = onError
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black; active = true
        let layer = AVCaptureVideoPreviewLayer(session: session); layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer); preview = layer
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: start()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.active else { return }
                    if granted { self.start() } else { self.onError("Allow camera access in Settings to scan a token, or cancel and paste the token instead.") }
                }
            }
        default: onError("Allow camera access in Settings to scan a token, or cancel and paste the token instead.")
        }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews(); preview?.frame = view.bounds
        guard let connection = preview?.connection, connection.isVideoOrientationSupported,
              let orientation = view.window?.windowScene?.interfaceOrientation else { return }
        switch orientation {
        case .landscapeLeft: connection.videoOrientation = .landscapeLeft
        case .landscapeRight: connection.videoOrientation = .landscapeRight
        case .portraitUpsideDown: connection.videoOrientation = .portraitUpsideDown
        default: connection.videoOrientation = .portrait
        }
    }
    private func start() {
        let session = self.session
        queue.async { [weak self] in
            do {
                guard let camera = AVCaptureDevice.default(for: .video) else { throw CameraError.unavailable }
                let input = try AVCaptureDeviceInput(device: camera)
                let output = AVCaptureMetadataOutput()
                session.beginConfiguration()
                guard session.canAddInput(input), session.canAddOutput(output) else { session.commitConfiguration(); throw CameraError.unavailable }
                session.addInput(input); session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main)
                guard output.availableMetadataObjectTypes.contains(.qr) else { session.commitConfiguration(); throw CameraError.unavailable }
                output.metadataObjectTypes = [.qr]
                session.commitConfiguration(); session.startRunning()
            } catch { DispatchQueue.main.async { [weak self] in guard let self, self.active else { return }; self.onError("The camera is unavailable. Cancel and paste the access token instead.") } }
        }
    }
    func stop() { active = false; let session = self.session; queue.async { if session.isRunning { session.stopRunning() } } }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); stop() }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard active, !delivered, let code = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first(where: { $0.type == .qr }), let value = code.stringValue else { return }
        delivered = true; stop(); onToken(value)
    }
    private enum CameraError: Error { case unavailable }
}
#endif
