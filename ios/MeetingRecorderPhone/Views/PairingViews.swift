import AVFoundation
import SwiftUI

@Observable @MainActor
final class PairingRunner {
    enum State: Equatable {
        case idle, working, failed(String)
    }

    private(set) var state = State.idle

    func run(_ pairing: PhonePairing, model: AppModel, keepAddress: Bool = false) async -> Bool {
        state = .working
        do {
            try await model.pair(pairing, keepAddress: keepAddress)
            state = .idle
            return true
        } catch let error as PairingError {
            state = .failed(error.message)
        } catch {
            state = .failed(error.localizedDescription)
        }
        return false
    }
}

struct WelcomeView: View {
    @State private var scanning = false
    @State private var typing = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 84))
                .foregroundStyle(.red.gradient)
                .accessibilityHidden(true)
            VStack(spacing: 10) {
                Text("Meeting Recorder").font(.largeTitle.bold())
                Text("Read your meetings, activity and pull requests from your Mac, on this phone. Nothing goes through a cloud.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 8) {
                Label("On your Mac: Settings, iPhone, turn on iPhone access", systemImage: "1.circle")
                Label("Choose Pair a device and keep the QR code open", systemImage: "2.circle")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            Spacer()
            VStack(spacing: 12) {
                Button { scanning = true } label: {
                    Label("Scan QR on your Mac", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button { typing = true } label: {
                    Label("Enter code instead", systemImage: "keyboard").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $scanning) { ScanPairingView() }
        .sheet(isPresented: $typing) { ManualPairingView() }
    }
}

struct ManualPairingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var address = ""
    @State private var runner = PairingRunner()

    private var pairing: PhonePairing? {
        guard let target = PhoneFormat.hostAndPort(address) else { return nil }
        return PhonePairing(manualCode: code, host: target.host, port: target.port)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("QKXJ-TZW5-QCN3-DYDE-…", text: $code, axis: .vertical)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .lineLimit(1...3)
                        .accessibilityLabel("Pairing code")
                } header: {
                    Text("Code")
                } footer: {
                    Text("The 32 letters and digits the Mac shows under the QR code. Dashes and spaces do not matter.")
                }
                Section {
                    TextField("macbook.local:52114", text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Mac address and port")
                } header: {
                    Text("Address")
                } footer: {
                    Text("The host name and port the Mac shows beside the code.")
                }
                if case .failed(let message) = runner.state {
                    Section { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .navigationTitle("Enter code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if runner.state == .working {
                        ProgressView()
                    } else {
                        Button("Pair") {
                            guard let pairing else { return }
                            Task { if await runner.run(pairing, model: model, keepAddress: true) { dismiss() } }
                        }
                        .disabled(pairing == nil)
                    }
                }
            }
        }
    }
}

struct ScanPairingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var runner = PairingRunner()
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                QRScannerView { text in
                    guard runner.state != .working else { return }
                    guard let url = URL(string: text), let pairing = PhonePairing(url: url) else {
                        problem = "That QR code is not a Meeting Recorder pairing code."
                        return
                    }
                    problem = nil
                    Task { if await runner.run(pairing, model: model) { dismiss() } }
                } unavailable: { reason in
                    problem = reason
                }
                .ignoresSafeArea()
                Group {
                    if runner.state == .working {
                        Label("Pairing…", systemImage: "link")
                    } else if case .failed(let message) = runner.state {
                        Label(message, systemImage: "exclamationmark.triangle")
                    } else if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle")
                    } else {
                        Label("Point the camera at the QR code on your Mac", systemImage: "qrcode.viewfinder")
                    }
                }
                .font(.subheadline)
                .padding(14)
                .glassBackground(RoundedRectangle(cornerRadius: 18))
                .padding()
            }
            .navigationTitle("Scan QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

/// Pairing that arrived as a `meetingrecorder://` link, for example from the camera app.
struct PairingConfirmView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let pairing: PhonePairing
    @State private var runner = PairingRunner()

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: "link.circle.fill").font(.system(size: 64)).foregroundStyle(.tint)
                Text("Pair with \(pairing.host)?").font(.title2.bold()).multilineTextAlignment(.center)
                Text("This phone will be able to read your meetings, activity and pull requests from that Mac.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if case .failed(let message) = runner.state {
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.subheadline)
                }
                Button {
                    Task { if await runner.run(pairing, model: model) { dismiss() } }
                } label: {
                    if runner.state == .working { ProgressView().frame(maxWidth: .infinity) } else { Text("Pair").frame(maxWidth: .infinity) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(runner.state == .working)
            }
            .padding(24)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}

/// The Mac no longer accepts this phone's key.
struct RepairView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack {
            ProblemView(title: "Pair again", message: "The Mac no longer recognises this iPhone. It was probably removed in the Mac's iPhone settings. Pair again to keep reading your meetings.",
                        systemImage: "key.slash", actionTitle: "Pair again") { model.forget() }
            Button("Not now") { model.dismissRepair() }.padding(.bottom, 24)
        }
    }
}

struct QRScannerView: UIViewControllerRepresentable {
    var onCode: (String) -> Void
    var unavailable: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        ScannerController(onCode: onCode, unavailable: unavailable)
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private let onCode: (String) -> Void
    private let unavailable: (String) -> Void
    private var preview: AVCaptureVideoPreviewLayer?
    private var lastCode: String?
    private var lastTime = Date.distantPast

    init(onCode: @escaping (String) -> Void, unavailable: @escaping (String) -> Void) {
        self.onCode = onCode
        self.unavailable = unavailable
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async { granted ? self?.configure() : self?.unavailable("Camera access is off. Allow it in Settings, or enter the code instead.") }
            }
        default: unavailable("Camera access is off. Allow it in Settings, or enter the code instead.")
        }
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            return unavailable("No camera is available here. Use Enter code instead.")
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return unavailable("The camera cannot scan codes. Use Enter code instead.") }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        preview = layer
        DispatchQueue.global(qos: .userInitiated).async { [session] in session.startRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        DispatchQueue.global().async { [session] in session.stopRunning() }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let code = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
        guard code != lastCode || Date().timeIntervalSince(lastTime) > 3 else { return }
        lastCode = code
        lastTime = Date()
        onCode(code)
    }
}
