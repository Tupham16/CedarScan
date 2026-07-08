import SwiftUI
import RoomPlan

struct ScanFlowView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller = ScanSessionController()
    @State private var isSaving = false

    /// Được gọi khi bấm lưu: các phòng đã quét + video + lưới màu (nếu có) + TÊN bản quét (tầng)
    /// + báo cáo chất lượng (nil khi không đo được). Trả về false nếu LƯU THẤT BẠI
    /// — khi đó không hiện report card (để alert lỗi của call-site hiện ra).
    let onFinish: ([CapturedRoom], URL?, URL?, String?, ScanQualityReport?) async -> Bool

    @State private var showNaming = false
    @State private var scanName = ""
    @State private var finishedReport: ScanQualityReport?

    private static let floorSuggestions = [
        "Floor 1", "Floor 2", "Floor 3", "Basement", "Attic", "Whole home",
    ]

    var body: some View {
        ZStack {
            RoomCaptureViewRepresentable(controller: controller)
                .ignoresSafeArea()

            // Cảnh báo chất lượng real-time (viền màu + rung) — chỉ khi đang quét
            if controller.phase == .scanning {
                QualityAlertOverlay(monitor: controller.qualityMonitor)
            }

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

            if let report = finishedReport {
                ScanReportCardView(report: report) {
                    finishedReport = nil
                    dismiss()
                }
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
        // Bản chụp mesh + cờ cap PHẢI lấy trước finishColoredMesh (nó giải phóng dữ liệu)
        let meshSnapshot = controller.snapshotMeshVertices()
        let meshCapped = controller.meshCapReached
        // Chốt metrics VÔ ĐIỀU KIỆN — finish() còn stop CADisplayLink (không stop là leak)
        let metrics = controller.finishQualityMetrics()
        Task {
            let videoURL = await controller.finishRecording()
            let meshURL = await controller.finishColoredMesh()
            // Quét đã xong hẳn — tắt camera/LiDAR ngay, đừng để chạy sau lưng report card
            controller.arSession.pause()

            // Báo cáo chất lượng: metrics lúc quét + cross-check tường vs mesh thô
            var report: ScanQualityReport?
            if ScanQualityConfig.current.enabled && metrics.activeDurationSec > 1 {
                let wallResults = await WallCrossCheck.run(rooms: rooms, meshPieces: meshSnapshot)
                let area = FloorPlanModel(rooms: rooms).areaSquareMeters
                report = ScanQualityReport.build(
                    metrics: metrics,
                    walls: wallResults,
                    floorAreaM2: area > 0 ? area : nil,
                    meshCapped: meshCapped
                )
            }

            let saved = await onFinish(rooms, videoURL, meshURL, name.isEmpty ? nil : name, report)
            isSaving = false
            if saved, let report {
                finishedReport = report   // hiện report card, bấm Xong mới đóng
            } else {
                dismiss()   // lưu lỗi → đóng ngay để alert lỗi của màn ngoài hiện ra
            }
        }
    }
}
