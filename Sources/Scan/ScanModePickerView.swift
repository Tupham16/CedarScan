import SwiftUI

/// Kiểu quét — chọn ở sheet trước khi bắt đầu.
///
/// P2 (2026-07-19): luồng RoomPlan đã TẮT LỐI VÀO, `.floorplan` không còn được sinh ra ở đâu
/// nữa. Giữ case lại vì `pendingScanMode` ở HomeView/ProjectView vẫn switch trên nó — xóa case
/// bây giờ là phải sửa cả hai call site, mà chỗ đó chứa cơ chế present-trong-onDismiss viết rất
/// cẩn thận (không được đụng vô cớ). Cả enum này sẽ biến mất ở P6 khi xóa RoomPlan thật.
enum ScanMode: String {
    case floorplan   // RoomPlan: từng phòng/từng tầng → floorplan + USDZ (KHÔNG còn lối vào)
    case mesh        // Mesh 3D: one-shot nhiều tầng → mesh màu + video, không floorplan
}

/// Sheet trước khi quét. TÊN CÒN LÀ "ModePicker" NHƯNG GIỜ CHỈ CHỌN ĐỘ NÉT — từ P2 app chỉ còn
/// một kiểu quét (3D nguyên căn) nên không còn gì để chọn kiểu nữa. Cố ý KHÔNG đổi tên struct ở
/// pha này: đổi tên là chạm vào HomeView + ProjectView, mà mục tiêu của P2 là chỉ sửa ĐÚNG MỘT
/// FILE để hoàn tác được bằng cách khôi phục file đó. Đổi tên/gộp vào màn địa chỉ ở P3–P6.
///
/// Vẫn giữ sheet (thay vì vào thẳng màn quét) vì lựa chọn Vừa/Nét là thứ đáng hỏi: nó đổi
/// thời gian lưu gần gấp đôi, và chọn nhầm thì phải quét lại cả buổi.
struct ScanModePickerView: View {
    @Environment(\.dismiss) private var dismiss
    let onStart: (ScanMode) -> Void

    @AppStorage("meshQuality") private var meshQuality: MeshQuality = MeshQuality.storageDefault

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    QualityTierPicker(quality: $meshQuality)
                    startButton
                        .padding(.top, 4)
                }
                .padding()
            }
            .navigationTitle(L.t("Scan detail level", "Độ nét bản quét"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L.t("Cancel", "Hủy")) { dismiss() }
                }
            }
        }
    }

    private var startButton: some View {
        Button {
            dismiss()
            // Luôn .mesh: đây là kiểu quét duy nhất còn lại.
            onStart(.mesh)
        } label: {
            Text(L.t("Start scanning", "Bắt đầu quét"))
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
    }
}

/// Chọn mức nét mesh (Vừa/Nét) + caption đổi theo lựa chọn.
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
            // .secondary chứ không .tertiary: đây là câu quan trọng nhất của card (gỡ hiểu lầm
            // "mức thấp = file nhẹ"), tertiary ở cỡ caption tương phản quá thấp để ai đọc.
            Text(MeshQuality.sharedNote)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}
