import SwiftUI
import RoomPlan

struct ScanFlowView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller = ScanSessionController()
    @State private var isSaving = false

    /// Được gọi khi bấm lưu: các phòng đã quét + video + lưới màu (nếu có) + TÊN bản quét (tầng).
    let onFinish: ([CapturedRoom], URL?, URL?, String?) async -> Void

    @State private var showNaming = false
    @State private var scanName = ""

    private static let floorSuggestions = [
        "Floor 1", "Floor 2", "Floor 3", "Basement", "Attic", "Whole home",
    ]

    var body: some View {
        ZStack {
            RoomCaptureViewRepresentable(controller: controller)
                .ignoresSafeArea()

            VStack {
                topBar
                Spacer()
                bottomControls
            }

            if showNaming {
                namingOverlay
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
                    showNaming = true
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

    /// Hỏi tên bản quét (tầng nào?) — giúp đội xử lý biết file thuộc tầng nào để ghép đúng.
    private var namingOverlay: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 14) {
                Text(L.t("Name this scan", "Đặt tên bản quét"))
                    .font(.headline)
                Text(L.t(
                    "Which floor is this? This helps us assemble your home correctly.",
                    "Đây là tầng nào? Tên giúp đội xử lý ghép các tầng chính xác."
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

                // Gợi ý bấm nhanh
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
                    showNaming = false
                    saveAndClose()
                } label: {
                    Text(L.t("Save scan", "Lưu bản quét"))
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)

                Button(L.t("Back", "Quay lại")) {
                    showNaming = false
                }
                .font(.subheadline)
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

    private func saveAndClose() {
        isSaving = true
        let rooms = controller.rooms
        let name = scanName.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let videoURL = await controller.finishRecording()
            let meshURL = await controller.finishColoredMesh()
            await onFinish(rooms, videoURL, meshURL, name.isEmpty ? nil : name)
            isSaving = false
            dismiss()
        }
    }
}
