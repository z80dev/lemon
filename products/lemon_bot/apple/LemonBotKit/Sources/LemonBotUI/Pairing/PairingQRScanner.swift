#if os(iOS)
import SwiftUI
import UIKit
@preconcurrency import AVFoundation

struct PairingQRScanner: UIViewControllerRepresentable {
    let completion: (Result<String, Error>) -> Void
    func makeUIViewController(context: Context) -> PairingScannerController {
        let controller = PairingScannerController()
        controller.completion = completion
        return controller
    }
    func updateUIViewController(_ controller: PairingScannerController, context: Context) {}
    static func dismantleUIViewController(_ controller: PairingScannerController, coordinator: ()) { controller.stop() }
}

final class PairingScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var completion: ((Result<String, Error>) -> Void)?
    private let session = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "org.lemonbot.pairing.camera")
    private var preview: AVCaptureVideoPreviewLayer?
    private var stopped = false
    private var finished = false
    private var backgroundObserver: NSObjectProtocol?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let cancel = UIButton(type: .system)
        cancel.setTitle("Cancel scan", for: .normal)
        cancel.addTarget(self, action: #selector(cancelScan), for: .touchUpInside)
        cancel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cancel)
        NSLayoutConstraint.activate([cancel.centerXAnchor.constraint(equalTo: view.centerXAnchor), cancel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24)])
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.cancelScan() }
        }
        // This controller is only created by the explicit Scan button.
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            Task { @MainActor in
                guard let self, !self.stopped else { return }
                if granted { self.configure() }
                else { self.finish(.failure(ScanError.permission)) }
            }
        }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
    override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); stop() }
    deinit { if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) } }

    private func configure() {
        do {
            guard let camera = AVCaptureDevice.default(for: .video) else { throw ScanError.unavailable }
            let input = try AVCaptureDeviceInput(device: camera)
            let output = AVCaptureMetadataOutput()
            session.beginConfiguration()
            guard session.canAddInput(input), session.canAddOutput(output) else { session.commitConfiguration(); throw ScanError.unavailable }
            session.addInput(input); session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            guard output.availableMetadataObjectTypes.contains(.qr) else { session.commitConfiguration(); throw ScanError.unavailable }
            output.metadataObjectTypes = [.qr]
            session.commitConfiguration()
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            view.layer.insertSublayer(layer, at: 0)
            preview = layer
            let session = session
            captureQueue.async { session.startRunning() }
        } catch { finish(.failure(ScanError.unavailable)) }
    }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !finished, !stopped,
              let code = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first(where: { $0.type == .qr }),
              let raw = code.stringValue else { return }
        finish(.success(raw))
    }
    func stop() {
        stopped = true
        let session = session
        captureQueue.async { if session.isRunning { session.stopRunning() } }
    }
    @objc private func cancelScan() { finish(.failure(ScanError.cancelled)) }
    private func finish(_ result: Result<String, Error>) {
        guard !finished else { return }
        finished = true; stop(); completion?(result)
    }
    private enum ScanError: LocalizedError {
        case permission, unavailable, cancelled
        var errorDescription: String? {
            switch self {
            case .permission: return "Camera permission is denied. Enable Camera in iOS Settings or paste the pairing link instead."
            case .unavailable: return "QR camera capture is unavailable. Paste the pairing link instead."
            case .cancelled: return "Scan stopped. Tap Scan explicitly to start again, or paste the pairing link."
            }
        }
    }
}
#endif
