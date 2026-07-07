import SwiftUI
import AVFoundation

/// Bộ quay video khảo sát (cho máy KHÔNG có LiDAR): camera 720p + micro (khách thuyết minh được).
final class VideoCaptureController: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()

    @Published var isRecording = false
    @Published var seconds = 0
    @Published var setupFailed = false

    private var timer: Timer?
    private var finishContinuation: CheckedContinuation<URL?, Never>?
    private var configured = false

    func configureAndStart() {
        guard !configured else { return }
        configured = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .hd1280x720
            guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let cameraInput = try? AVCaptureDeviceInput(device: camera),
                  self.session.canAddInput(cameraInput) else {
                self.session.commitConfiguration()
                DispatchQueue.main.async { self.setupFailed = true }
                return
            }
            self.session.addInput(cameraInput)
            if let mic = AVCaptureDevice.default(for: .audio),
               let micInput = try? AVCaptureDeviceInput(device: mic),
               self.session.canAddInput(micInput) {
                self.session.addInput(micInput)
            }
            if self.session.canAddOutput(self.output) {
                self.session.addOutput(self.output)
            }
            self.session.commitConfiguration()
            self.session.startRunning()
        }
    }

    func startRecording() {
        guard !isRecording else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("walkthrough-\(UUID().uuidString.prefix(8)).mp4")
        try? FileManager.default.removeItem(at: url)
        output.startRecording(to: url, recordingDelegate: self)
        isRecording = true
        seconds = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.seconds += 1
        }
    }

    func stopRecording() async -> URL? {
        guard isRecording else { return nil }
        timer?.invalidate()
        timer = nil
        return await withCheckedContinuation { continuation in
            finishContinuation = continuation
            output.stopRecording()
        }
    }

    func teardown() {
        timer?.invalidate()
        timer = nil
        if output.isRecording { output.stopRecording() }
        DispatchQueue.global(qos: .userInitiated).async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    // MARK: AVCaptureFileOutputRecordingDelegate

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        DispatchQueue.main.async {
            self.isRecording = false
            self.finishContinuation?.resume(returning: error == nil ? outputFileURL : nil)
            self.finishContinuation = nil
        }
    }
}

/// Khung xem trước camera.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}
}

/// Luồng quay video khảo sát cho máy không LiDAR:
/// giới thiệu (kèm CẢNH BÁO độ chính xác) → quay → đặt tên → lưu.
struct VideoScanFlowView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller = VideoCaptureController()

    /// (videoURL, tên bản quét)
    let onFinish: (URL, String?) async -> Void

    @State private var hasStarted = false
    @State private var recordedURL: URL?
    @State private var scanName = ""
    @State private var isSaving = false

    private static let floorSuggestions = [
        "Floor 1", "Floor 2", "Floor 3", "Basement", "Attic", "Whole home",
    ]

    var body: some View {
        ZStack {
            CameraPreviewView(session: controller.session)
                .ignoresSafeArea()

            VStack {
                topBar
                Spacer()
                bottomControls
            }

            if recordedURL != nil {
                namingOverlay
            }
            if isSaving {
                savingOverlay
            }
        }
        .onAppear { controller.configureAndStart() }
        .onDisappear { controller.teardown() }
        .alert(L.t("Camera unavailable", "Không mở được camera"), isPresented: $controller.setupFailed) {
            Button("OK") { dismiss() }
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                controller.teardown()
                dismiss()
            } label: {
                Text(L.t("Cancel", "Hủy"))
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            Spacer()
            if controller.isRecording {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 9, height: 9)
                    Text(timeString)
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .padding()
    }

    @ViewBuilder
    private var bottomControls: some View {
        if !hasStarted {
            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        L.t("Video walkthrough (no LiDAR)", "Quay video khảo sát (không LiDAR)"),
                        systemImage: "video.fill"
                    )
                    .font(.headline)
                    Text(L.t(
                        "Walk slowly through every room, filming all walls, corners, doors and windows. You can narrate room names as you go.",
                        "Đi chậm qua từng phòng, quay đủ mọi bức tường, góc, cửa và cửa sổ. Có thể vừa quay vừa đọc tên phòng."
                    ))
                    .font(.subheadline)
                    Label {
                        Text(L.t(
                            "Note: measurements from video are LESS accurate than a LiDAR scan (iPhone Pro).",
                            "Lưu ý: số đo từ video sẽ KÉM chính xác hơn so với quét LiDAR (iPhone Pro)."
                        ))
                        .font(.footnote.weight(.semibold))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                .padding(14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))

                Button {
                    hasStarted = true
                    controller.startRecording()
                } label: {
                    Label(L.t("Start recording", "Bắt đầu quay"), systemImage: "record.circle")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .padding()
        } else if controller.isRecording {
            VStack(spacing: 10) {
                Text(L.t(
                    "Walk slowly. Film every wall. Go through doorways slowly.",
                    "Đi chậm. Quay đủ mọi bức tường. Qua cửa thật chậm."
                ))
                .font(.footnote)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))

                Button {
                    Task {
                        recordedURL = await controller.stopRecording()
                    }
                } label: {
                    Label(L.t("Finish recording", "Kết thúc quay"), systemImage: "stop.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .padding()
        }
    }

    private var namingOverlay: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 14) {
                Text(L.t("Name this scan", "Đặt tên bản quét"))
                    .font(.headline)
                Text(L.t(
                    "Which floor or building is this? This helps us assemble your home correctly.",
                    "Đây là tầng/khu nào? Tên giúp đội xử lý ghép nhà chính xác."
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 8) {
                    ForEach(Self.floorSuggestions, id: \.self) { suggestion in
                        Button {
                            scanName = suggestion
                        } label: {
                            Text(suggestion)
                                .font(.subheadline)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity)
                                .background(
                                    scanName == suggestion ? Color.accentColor.opacity(0.2) : Color(.tertiarySystemFill),
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }

                TextField(L.t("Or type a name (e.g. Floor 1)", "Hoặc tự gõ tên (vd Floor 1)"), text: $scanName)
                    .textFieldStyle(.roundedBorder)

                Button {
                    save()
                } label: {
                    Text(L.t("Save scan", "Lưu bản quét"))
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .padding(24)
        }
    }

    private var savingOverlay: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            HStack(spacing: 10) {
                ProgressView()
                Text(L.t("Saving…", "Đang lưu…"))
                    .font(.headline)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var timeString: String {
        String(format: "%d:%02d", controller.seconds / 60, controller.seconds % 60)
    }

    private func save() {
        guard let recordedURL else { return }
        isSaving = true
        let name = scanName.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            controller.teardown()
            await onFinish(recordedURL, name.isEmpty ? nil : name)
            isSaving = false
            dismiss()
        }
    }
}
