import SwiftUI

/// Sheet trước khi quét từ TRANG DỰ ÁN: chỉ còn chọn độ nét.
///
/// Từng tên là `ScanModePickerView` (chọn RoomPlan hay Mesh). Từ 2026-07-20 RoomPlan bị gỡ hẳn
/// nên `enum ScanMode` biến mất cùng nó và cái tên cũ thành nói dối. Đổi tên ở đây được vì đợt
/// này đằng nào cũng phải sửa cả hai call site.
///
/// TRANG CHỦ KHÔNG dùng màn này — nó đi qua `ScanAddressView` (hỏi căn nhà rồi mới tới độ nét).
/// Ở trang dự án thì căn nhà đã biết rồi, nên chỉ còn độ nét để hỏi.
///
/// Vẫn giữ sheet (thay vì vào thẳng màn quét) vì lựa chọn Vừa/Nét là thứ đáng hỏi: nó đổi
/// thời gian lưu gần gấp đôi, và chọn nhầm thì phải quét lại cả buổi.
struct ScanQualityPickerView: View {
    @Environment(\.dismiss) private var dismiss
    /// Chỉ báo "khách đã bấm Bắt đầu" — KHÔNG mang tham số nào nữa. Người gọi present màn quét
    /// từ onDismiss của sheet này, nên closure này chỉ được set cờ, không được present gì.
    let onStart: () -> Void

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
            onStart()
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
