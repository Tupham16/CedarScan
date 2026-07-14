import SwiftUI

/// Kiểu quét — chọn ở sheet trước khi bắt đầu.
enum ScanMode: String {
    case floorplan   // RoomPlan: từng phòng/từng tầng → floorplan + USDZ (luồng cũ)
    case mesh        // Mesh 3D: one-shot nhiều tầng → mesh màu + video, không floorplan
}

/// Sheet chọn kiểu quét — hiện MỖI LẦN bấm quét (chọn nhầm kiểu là mất 10+ phút đi bộ,
/// một chạm thêm là bảo hiểm rẻ). Lựa chọn lần trước được nhớ để PRESELECT, không auto-skip.
struct ScanModePickerView: View {
    @Environment(\.dismiss) private var dismiss
    let onStart: (ScanMode) -> Void

    @AppStorage("lastScanMode") private var lastScanModeRaw: String = ScanMode.floorplan.rawValue
    @AppStorage("meshQuality") private var meshQuality: MeshQuality = .light
    @State private var selected: ScanMode = .floorplan

    var body: some View {
        NavigationStack {
            // ScrollView: ở detent .medium nội dung (2 card + tier picker + nút) có thể
            // vượt chiều cao khả dụng trên máy 6.1" — không được ép nén/cắt chữ.
            ScrollView {
                VStack(spacing: 12) {
                    ModeCard(
                        icon: "square.split.bottomrightquarter",
                        title: L.t("Floor plan scan (per floor)", "Quét mặt bằng (từng tầng)"),
                        subtitle: L.t(
                            "Best for ordering a floor plan — scan room by room, one floor per scan.",
                            "Chuẩn để đặt làm bản vẽ mặt bằng — quét từng phòng, mỗi tầng một bản."
                        ),
                        isSelected: selected == .floorplan
                    ) { selected = .floorplan }

                    ModeCard(
                        icon: "cube.transparent",
                        title: L.t("3D scan (whole home)", "Quét 3D nguyên căn"),
                        subtitle: L.t(
                            "One continuous scan across floors, Stop & Save anytime. Produces a colored 3D model + video — NO floor plan drawing.",
                            "Quét liền một mạch nhiều tầng, Dừng & Lưu bất kỳ lúc nào. Ra mô hình 3D màu + video — KHÔNG có bản vẽ mặt bằng."
                        ),
                        isSelected: selected == .mesh
                    ) { selected = .mesh }

                    if selected == .mesh {
                        QualityTierPicker(quality: $meshQuality)
                    }

                    startButton
                        .padding(.top, 4)
                }
                .padding()
            }
            .navigationTitle(L.t("Choose scan type", "Chọn kiểu quét"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L.t("Cancel", "Hủy")) { dismiss() }
                }
            }
        }
        .onAppear {
            if let last = ScanMode(rawValue: lastScanModeRaw) {
                selected = last
            }
        }
    }

    private var startButton: some View {
        Button {
            lastScanModeRaw = selected.rawValue
            dismiss()
            onStart(selected)
        } label: {
            Text(L.t("Start scanning", "Bắt đầu quét"))
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
    }
}

/// Thẻ một kiểu quét — tách view riêng + kiểu tường minh (né type-check timeout CI).
private struct ModeCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        let border: Color = isSelected ? Color.accentColor : Color(.separator)
        let mark: String = isSelected ? "largecircle.fill.circle" : "circle"
        return Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .frame(width: 34)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: mark)
                    .foregroundStyle(.tint)
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(border, lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}

/// Chọn mức nét mesh (Nhẹ/Vừa/Nét) + caption đổi theo lựa chọn — cho đợt test so 3 mức.
private struct QualityTierPicker: View {
    @Binding var quality: MeshQuality

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L.t("Mesh detail", "Độ nét mesh"))
                .font(.subheadline.weight(.semibold))
            Picker(L.t("Mesh detail", "Độ nét mesh"), selection: $quality) {
                ForEach(MeshQuality.allCases) { q in
                    Text(q.label).tag(q)
                }
            }
            .pickerStyle(.segmented)
            Text(quality.caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}
