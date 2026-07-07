import SwiftUI
import RoomPlan

struct ScanFlowView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller = ScanSessionController()
    @State private var isSaving = false

    /// Được gọi khi người dùng bấm "Hoàn tất & Lưu" với các phòng đã quét + video (nếu có).
    let onFinish: ([CapturedRoom], URL?) async -> Void

    var body: some View {
        ZStack {
            RoomCaptureViewRepresentable(controller: controller)
                .ignoresSafeArea()

            VStack {
                topBar
                Spacer()
                bottomControls
            }

            if isSaving {
                savingOverlay
            }
        }
        .onAppear {
            controller.startSession()
        }
        .alert(L.t("Scan didn't work", "Quét chưa thành công"), isPresented: errorBinding) {
            Button(L.t("Try again", "Thử lại"), role: .cancel) {
                controller.lastError = nil
                controller.scanNextRoom()
            }
        } message: {
            Text(controller.lastError ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { controller.lastError != nil },
            set: { if !$0 { controller.lastError = nil } }
        )
    }

    private var topBar: some View {
        HStack {
            Button {
                controller.cancel()
                dismiss()
            } label: {
                Text(L.t("Cancel", "Hủy"))
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            Spacer()
            if !controller.rooms.isEmpty {
                Text(L.t("\(controller.rooms.count) room(s) scanned", "Đã quét \(controller.rooms.count) phòng"))
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .padding()
    }

    @ViewBuilder
    private var bottomControls: some View {
        switch controller.phase {
        case .scanning:
            VStack(spacing: 10) {
                Text(L.t(
                    "Walk slowly around the room. Point the camera at walls, doors and furniture.",
                    "Đi chậm quanh phòng, hướng camera vào tường, cửa và đồ đạc."
                ))
                .font(.footnote)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                Button {
                    controller.finishCurrentRoom()
                } label: {
                    Text(L.t("Done with this room", "Xong phòng này"))
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()

        case .processing:
            HStack(spacing: 10) {
                ProgressView()
                Text(L.t("Processing scan…", "Đang xử lý bản quét…"))
                    .font(.headline)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding()

        case .roomReady:
            VStack(spacing: 10) {
                Button {
                    controller.scanNextRoom()
                } label: {
                    Text(L.t("Scan next room", "Quét phòng tiếp theo"))
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.bordered)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))

                Button {
                    saveAndClose()
                } label: {
                    Text(L.t("Finish & Save", "Hoàn tất & Lưu"))
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
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

    private func saveAndClose() {
        isSaving = true
        let rooms = controller.rooms
        Task {
            let videoURL = await controller.finishRecording()
            await onFinish(rooms, videoURL)
            isSaving = false
            dismiss()
        }
    }
}
