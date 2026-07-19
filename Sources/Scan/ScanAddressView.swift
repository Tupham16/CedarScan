import Foundation
import SwiftUI

/// Màn chèn giữa nút Quét và màn quét: gắn bản quét sắp tới vào một CĂN NHÀ (dự án), rồi chọn
/// độ nét. Thay cho sheet chỉ-chọn-độ-nét của P2 — gộp vào một màn để không thêm một chạm.
///
/// VÌ SAO ĐỊA CHỈ PHẢI ĐI QUA `ScanProject` CHỨ KHÔNG PHẢI `ScanRecord`:
/// thẻ Kanban gửi đội vẽ lấy tên căn nhà từ DỰ ÁN — `ScanDetailView` gửi
/// `projectName: store.project(with: current.projectId)?.name`, không phải tên bản quét.
/// Bản quét mở từ HomeView trước đây luôn lưu `projectId = nil`, nên đơn tới tay đội vẽ
/// KHÔNG kèm địa chỉ nào. Nhét địa chỉ vào tên bản quét sẽ không chạy tới thẻ.
///
/// Địa chỉ CÓ THỂ BỎ QUA (chủ app chốt): quét trong nhà thì GPS yếu, có lúc quét thử, có lúc
/// chưa biết địa chỉ. Chặn cứng ở đây là chặn đúng lúc người ta đang cầm máy muốn quét.
struct ScanAddressView: View {
    @EnvironmentObject private var store: ScanStore
    @Environment(\.dismiss) private var dismiss
    /// projectId để gắn bản quét sắp tới; nil = không thuộc căn nhà nào (bỏ qua).
    let onStart: (UUID?) -> Void

    @AppStorage("meshQuality") private var meshQuality: MeshQuality = MeshQuality.storageDefault
    @State private var address = ""
    @State private var pickedProjectId: UUID?
    /// "Chữ tôi gõ trùng tên căn đã có, nhưng đây là căn KHÁC" — lối thoát khỏi việc gộp.
    @State private var forceNewProject = false

    /// Căn đã có trùng tên với chữ đang gõ, tính LIVE để HIỆN RA trước khi bấm quét.
    ///
    /// Gộp IM LẶNG nguy hiểm hơn chính lỗi nó sửa: tách nhầm làm đơn THIẾU một tầng (đội vẽ
    /// thấy ngay), còn gộp nhầm làm đơn THỪA tầng của nhà khác — đội vẽ dựng ra một căn nhà
    /// không tồn tại, và không ai có cách nào biết. Ô nhập ghi "Địa chỉ hoặc tên" nên tên người
    /// là dữ liệu hợp lệ, mà tên người Việt trùng nhau là chuyện thường ngày: hai khách cùng
    /// gọi "Nhà chị Lan" BẮT BUỘC phải tách được.
    private var typedMatch: ScanProject? {
        let key = Self.matchKey(address)
        guard !key.isEmpty else { return nil }
        return store.projects.first { Self.matchKey($0.name) == key }
    }

    var body: some View {
        NavigationStack {
            // Tách từng Section thành computed property riêng — CI từng timeout type-check
            // với biểu thức SwiftUI lớn, và Form nhiều section là đúng dạng dễ dính.
            Form {
                addressSection
                existingSection
                qualitySection
                actionSection
            }
            .navigationTitle(L.t("Before scanning", "Trước khi quét"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L.t("Cancel", "Hủy")) { dismiss() }
                }
            }
        }
    }

    private var addressSection: some View {
        Section {
            TextField(
                L.t("Address or name (e.g. 1600 College Ave)", "Địa chỉ hoặc tên (vd 1600 College Ave)"),
                text: $address
            )
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
            // Gõ địa chỉ mới thì bỏ chọn căn đã có — hai đường loại trừ nhau, để cả hai cùng
            // "bật" là người dùng không đoán được cái nào thắng.
            .onChange(of: address) { _, newValue in
                if !newValue.isEmpty { pickedProjectId = nil }
                // Gõ lại từ đầu thì bỏ luôn lựa chọn "đây là căn khác" của lần gõ trước.
                forceNewProject = false
            }
            matchRow
        } header: {
            Text(L.t("Which home is this?", "Căn nhà này ở đâu?"))
        } footer: {
            Text(L.t(
                "Shown to the drafting team on the order. You can skip this and add it later.",
                "Hiện trên đơn cho đội vẽ. Có thể bỏ qua và điền sau."
            ))
        }
    }

    /// Báo cho người dùng biết chữ họ vừa gõ sẽ GỘP vào căn đã có, kèm lối thoát. Không có dòng
    /// này thì hai kết cục (tạo căn mới / gộp vào căn cũ) nhìn giống hệt nhau trên màn hình.
    @ViewBuilder
    private var matchRow: some View {
        if let match = typedMatch {
            matchRowBody(match)
        }
    }

    /// Tách thành hàm nhận tham số thay vì viết thẳng trong ViewBuilder: cần tính `count` và
    /// dựng chuỗi trước khi trả view, mà khai báo cục bộ trong thân ViewBuilder là chỗ CI này
    /// từng chết vì "type-check timeout". Icon dùng "folder"/"folder.badge.plus" — hai cái đã
    /// có sẵn trong repo, nên chắc chắn tồn tại (tên SF Symbol sai KHÔNG lỗi compile, CI vẫn
    /// xanh và chỉ lộ ô trống lúc sideload).
    private func matchRowBody(_ match: ScanProject) -> some View {
        let count = store.scans(in: match).count
        let text: String = forceNewProject
            ? L.t("Will create a separate home with the same name", "Sẽ tạo một căn RIÊNG cùng tên")
            : L.t("Will add to: \(match.name) · \(count) scan(s)",
                  "Sẽ thêm vào căn đã có: \(match.name) · \(count) bản quét")
        return VStack(alignment: .leading, spacing: 8) {
            Label(text, systemImage: forceNewProject ? "folder.badge.plus" : "folder")
                .font(.footnote)
                .foregroundStyle(forceNewProject ? Color.orange : Color.secondary)
            Toggle(isOn: $forceNewProject) {
                Text(L.t("This is a different home", "Đây là căn nhà khác"))
                    .font(.footnote)
            }
        }
    }

    @ViewBuilder
    private var existingSection: some View {
        if !store.projects.isEmpty {
            Section(L.t("Or pick a home you already have", "Hoặc chọn căn đã có")) {
                ForEach(store.projects) { project in
                    Button {
                        pickedProjectId = project.id
                        address = ""
                    } label: {
                        HStack {
                            Text(project.name)
                                .foregroundStyle(.primary)
                            Spacer(minLength: 8)
                            if pickedProjectId == project.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
            }
        }
    }

    private var qualitySection: some View {
        Section(L.t("Mesh detail", "Độ nét mesh")) {
            Picker(L.t("Mesh detail", "Độ nét mesh"), selection: $meshQuality) {
                ForEach(MeshQuality.allCases) { q in
                    Text(q.label).tag(q)
                }
            }
            .pickerStyle(.segmented)
            Text(meshQuality.caption)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(MeshQuality.sharedNote)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var actionSection: some View {
        Section {
            Button {
                start()
            } label: {
                Text(L.t("Start scanning", "Bắt đầu quét"))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            Button {
                dismiss()
                onStart(nil)
            } label: {
                Text(L.t("Skip — scan without a home", "Bỏ qua — quét không gắn căn nhà"))
                    .frame(maxWidth: .infinity)
            }
            .listRowBackground(Color.clear)
        }
    }

    /// dismiss() TRƯỚC onStart() — cùng khuôn với ScanModePickerView: người gọi present màn quét
    /// từ onDismiss của sheet này, nên onStart chỉ được set cờ, không được present gì.
    /// Thứ tự ưu tiên: căn CHỌN TAY trong danh sách → căn trùng tên (trừ khi người dùng đã bảo
    /// "đây là căn khác") → tạo mới → nil (ô rỗng, hệt như bấm Bỏ qua).
    ///
    /// Vì sao phải dedupe: gõ lại cùng địa chỉ cho tầng 2 là hành vi MẶC ĐỊNH (ô nhập nằm TRÊN
    /// danh sách "chọn căn đã có"), thiếu bước này là hai tầng của một nhà rơi vào hai dự án và
    /// đơn gửi đội vẽ từ bên nào cũng thiếu một tầng. Luồng "Quét phần còn lại ngay" thoát được
    /// nhờ giữ `pendingProjectId`, nhưng người chủ động quét hai tầng riêng không chạm alert đó.
    ///
    /// Cố ý CHỈ dedupe ở đây, KHÔNG sửa `ScanStore.createProject`: alert "Dự án mới" là hành
    /// động cố ý tạo thư mục, ai muốn hai thư mục trùng tên thì đó là quyền của họ.
    private func start() {
        let id: UUID?
        if let picked = pickedProjectId {
            id = picked
        } else if let match = typedMatch, !forceNewProject {
            id = match.id
        } else {
            let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
            id = trimmed.isEmpty ? nil : store.createProject(name: trimmed)?.id
        }
        dismiss()
        onStart(id)
    }

    /// Khoá so khớp tên căn nhà: bỏ hoa/thường, bỏ dấu, bỏ khoảng trắng thừa hai đầu.
    ///
    /// ĐỔI `đ`/`Đ` BẰNG TAY TRƯỚC: `.diacriticInsensitive` KHÔNG fold được chúng — U+0111 là một
    /// chữ cái CƠ SỞ riêng trong Unicode, không có canonical decomposition thành d + dấu, nên
    /// bước bỏ dấu của Foundation không chạm tới (khác ă/â/ê/ô/ơ/ư đều fold được). Bỏ sót chỗ
    /// này là hỏng đúng chữ hay gặp nhất trong địa chỉ Việt Nam: "Đường Lê Lợi" sẽ KHÔNG khớp
    /// "Duong Le Loi", tức lỗi tách-nhầm vẫn sống nguyên ở đúng nhóm địa chỉ phổ biến nhất.
    private static func matchKey(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "đ", with: "d")
            .replacingOccurrences(of: "Đ", with: "D")
            .folding(options: [.diacriticInsensitive, .caseInsensitive],
                     locale: Locale(identifier: "vi_VN"))
            .lowercased()
    }
}
