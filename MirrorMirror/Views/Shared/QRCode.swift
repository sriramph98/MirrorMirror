import SwiftUI
import MirrorUI
import AVFoundation
import CoreImage.CIFilterBuiltins

struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = Self.render(text) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        } else {
            Color.gray
        }
    }

    private static func render(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// The pairing-code scanner in a viewfinder: live camera, large accent focus brackets, a caps
/// readout, and a plain message (with a way out) when there is no camera to scan with.
struct PairingScanner: View {
    let onCode: (String) -> Void
    var onUseLink: (() -> Void)? = nil
    @State private var unavailable: String?

    var body: some View {
        Viewfinder {
            QRScannerView(onCode: onCode, onUnavailable: { unavailable = $0 })
            if let unavailable {
                VStack(spacing: Space.m) {
                    Image(systemName: "camera.metering.unknown").font(.title).foregroundStyle(Palette.textTertiary)
                    Text(unavailable).type(.callout, color: Palette.textSecondary).multilineTextAlignment(.center)
                    if let onUseLink {
                        Button("Paste a link instead", action: onUseLink).buttonStyle(.pill())
                    }
                }
                .padding(Space.xl)
            }
        } topLeading: {
            LED(unavailable == nil ? Palette.ok : Palette.textTertiary, label: unavailable == nil ? "Scanning" : "No camera",
                pulsing: unavailable == nil)
        } topTrailing: {
            Badge("QR")
        } bottomLeading: {
            ReadoutLine(["Align the pairing code"], color: Palette.textPrimary)
        }
        .overlay {
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height) * 0.62
                Color.clear
                    .frame(width: side, height: side)
                    .focusBrackets(unavailable == nil ? Palette.accent : Palette.textTertiary,
                                   length: Space.xxxl, lineWidth: Space.xs, inset: 0)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .allowsHitTesting(false)
            .opacity(unavailable == nil ? 1 : 0.3)
        }
    }
}

/// Camera-based QR scanner. Reports each distinct code it sees.
struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    /// When set, problems (no camera, no permission) are reported here instead of drawn by UIKit.
    var onUnavailable: ((String) -> Void)? = nil

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onCode = onCode
        controller.onUnavailable = onUnavailable
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        var onUnavailable: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var previewLayer: AVCaptureVideoPreviewLayer?
        private var lastCode: String?
        private let messageLabel = UILabel()

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = UIColor(Palette.frame)
            messageLabel.textColor = UIColor(Palette.textSecondary)
            messageLabel.numberOfLines = 0
            messageLabel.textAlignment = .center
            messageLabel.font = .preferredFont(forTextStyle: .subheadline)
            messageLabel.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(messageLabel)
            NSLayoutConstraint.activate([
                messageLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                messageLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                messageLabel.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.8),
            ])

            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { granted ? self.configure() : self.show("Allow camera access in Settings to scan a pairing code.") }
            }
        }

        private func configure() {
            guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                show("No camera available. Paste the pairing link instead.")
                return
            }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]

            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            view.layer.insertSublayer(layer, at: 0)
            previewLayer = layer
            DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
        }

        private func show(_ message: String) {
            if let onUnavailable { onUnavailable(message) } else { messageLabel.text = message }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            previewLayer?.frame = view.bounds
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            DispatchQueue.global(qos: .userInitiated).async { self.session.stopRunning() }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard let code = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue, code != lastCode else { return }
            lastCode = code
            onCode?(code)
        }
    }
}
