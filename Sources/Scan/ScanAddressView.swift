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
/// ĐỊA CHỈ BẮT BUỘC (chủ app chốt 2026-07-19, đảo lại quyết định "có nút Bỏ qua" trước đó):
/// không điền thì không quét được. Lý do: bản quét không gắn căn nhà là đơn tới tay đội vẽ
/// không có địa chỉ — đúng thứ màn này sinh ra để chống, mà cho bỏ qua thì ai cũng bỏ qua.
/// Chấp nhận CHỮ TỰ DO (không ép đúng định dạng địa chỉ) để người dùng luôn đi tiếp được khi
/// GPS yếu trong nhà, mất mạng, hoặc từ chối cấp quyền vị trí.
struct ScanAddressView: View {
    @EnvironmentObject private var store: ScanStore
    @Environment(\.dismiss) private var dismiss
    /// projectId để gắn bản quét sắp tới. Từ 2026-07-19 địa chỉ là BẮT BUỘC nên thực tế luôn
    /// non-nil; giữ Optional vì `createProject` vẫn có thể trả nil (tên toàn ký tự lạ bị lọc
    /// sạch) — lúc đó thà cho quét còn hơn nuốt mất buổi quét vì một cái tên kỳ quặc.
    let onStart: (UUID?) -> Void

    @AppStorage("meshQuality") private var meshQuality: MeshQuality = MeshQuality.storageDefault
    @State private var address = ""
    @State private var pickedProjectId: UUID?
    /// Đã bung xem hết danh sách căn đã quét chưa. Mặc định chỉ hiện vài dòng đầu.
    @State private var showAllProjects = false

    /// Số căn hiện tối đa khi chưa bung. Danh sách đầy đủ vẫn tới được bằng nút "Xem tất cả",
    /// và gõ vào ô địa chỉ vẫn lọc trên TOÀN BỘ danh sách chứ không phải trên phần đang hiện —
    /// nên giới hạn này không giấu mất căn nào.
    private static let collapsedRowLimit = 5

    /// Căn đã quét, lọc theo chữ đang gõ. Ô nhập và danh sách là MỘT khối: gõ để lọc, chạm một
    /// dòng để dùng lại căn đó, không chạm mà bấm Bắt đầu thì tạo căn mới theo chữ vừa gõ.
    private var filteredProjects: [ScanProject] {
        let key = Self.matchKey(address)
        guard !key.isEmpty else { return store.projects }
        return store.projects.filter { Self.matchKey($0.name).contains(key) }
    }

    /// Căn đã có TRÙNG HẲN tên với chữ đang gõ (không phải chỉ chứa).
    ///
    /// Chỉ dùng để nhắc một dòng, KHÔNG tự gộp. Gộp im lặng nguy hiểm hơn chính lỗi nó sửa:
    /// tách nhầm làm đơn THIẾU một tầng (đội vẽ thấy ngay), gộp nhầm làm đơn THỪA tầng của nhà
    /// khác — đội vẽ dựng ra một căn nhà không tồn tại và không ai phát hiện được. Ô này ghi
    /// "Địa chỉ hoặc tên" nên tên người là dữ liệu hợp lệ, mà hai khách cùng gọi "Nhà chị Lan"
    /// là chuyện thường ngày. Nên: chỉ NHẮC, để người dùng chạm.
    private var exactMatch: ScanProject? {
        let key = Self.matchKey(address)
        guard !key.isEmpty, pickedProjectId == nil else { return nil }
        return store.projects.first { Self.matchKey($0.name) == key }
    }

    var body: some View {
        NavigationStack {
            // Tách từng Section thành computed property riêng — CI từng timeout type-check
            // với biểu thức SwiftUI lớn, và Form nhiều section là đúng dạng dễ dính.
            Form {
                homeSection
                qualitySection
            }
            .navigationTitle(L.t("Before scanning", "Trước khi quét"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L.t("Cancel", "Hủy")) { dismiss() }
                }
            }
            // Nút GHIM ĐÁY, không nằm trong Form nữa.
            //
            // Trước đây nó là section CUỐI của Form, tức nằm SAU danh sách căn đã quét — mà danh
            // sách đó không giới hạn số dòng. Khách có nhiều căn là nút bị đẩy khỏi màn hình và
            // phải cuộn xuống đáy mới bấm được (chủ app báo 2026-07-20). Nút chính của một màn
            // bắt buộc thì không được phụ thuộc vào việc người dùng có bao nhiêu dữ liệu cũ.
            // Cùng khuôn với HomeView/ProjectView — cả hai đã ghim nút quét bằng safeAreaInset.
            .safeAreaInset(edge: .bottom) {
                startBar
            }
        }
    }

    /// Ô nhập và danh sách căn đã quét là MỘT khối: gõ để lọc, chạm một dòng để dùng lại căn
    /// đó. Trước đây là hai mục riêng — cùng một việc mà bày hai chỗ.
    private var homeSection: some View {
        Section {
            TextField(
                L.t("Address or name (e.g. 1600 College Ave)", "Địa chỉ hoặc tên (vd 1600 College Ave)"),
                text: $address
            )
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
            // Gõ = đang mô tả căn mới → bỏ dòng đang chọn. Hai đường loại trừ nhau, để cả hai
            // cùng "bật" là người dùng không đoán được cái nào thắng.
            //
            // XOÁ VÔ ĐIỀU KIỆN, không guard `!newValue.isEmpty`: guard đó là tàn dư từ hồi nút
            // chọn dòng còn đặt `address = ""` (phải chặn để lựa chọn vừa tạo không tự huỷ).
            // Bỏ dòng đó rồi mà giữ guard thì sinh ra trạng thái KHÔNG THOÁT ĐƯỢC: ô rỗng nhưng
            // `pickedProjectId` vẫn còn — màn hình nói "chưa gắn căn nào" (ô trống + footer +
            // nhãn nút) trong khi `start()` vẫn gắn. Giờ an toàn vì nhánh chạm dòng không ghi
            // vào `address` nữa nên không sinh vòng lặp.
            .onChange(of: address) { _, _ in
                pickedProjectId = nil
            }
            pickedRow
            existingRows
        } header: {
            Text(L.t("Which home is this?", "Căn nhà này ở đâu?"))
        } footer: {
            // Footer render SAU mọi dòng của section, nên KHÔNG dùng nó để chỉ đường ("chạm dòng
            // bên dưới" sẽ trỏ ngược lên trên). Giữ đúng một câu chung, không đổi theo tình huống
            // — việc cảnh báo trùng tên đã chuyển lên chữ trên NÚT, chỗ người dùng thật sự đọc.
            Text(L.t(
                "Required — the drafting team needs to know which home the drawing is for.",
                "Bắt buộc — đội vẽ cần biết bản vẽ này của căn nào."
            ))
        }
    }

    /// Trạng thái "đang dùng lại căn nào", LUÔN hiện ngay dưới ô nhập khi có lựa chọn.
    ///
    /// Không thể trông vào dấu tích trong danh sách: danh sách có thể dài, có thể bị lọc rỗng,
    /// và dấu tích dễ nằm ngoài màn hình. Cũng không thể dùng footer — footer render SAU mọi
    /// dòng. Dòng này nằm cùng section nên đúng thứ tự, và bản thân nó là LỐI THOÁT duy nhất:
    /// chạm lại một dòng đã chọn không bỏ chọn được, ô nhập rỗng thì cũng không xoá thêm được gì.
    @ViewBuilder
    private var pickedRow: some View {
        if let picked = store.projects.first(where: { $0.id == pickedProjectId }) {
            HStack {
                Label(
                    L.t("Adding to: \(picked.name)", "Thêm vào: \(picked.name)"),
                    systemImage: "checkmark.circle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.tint)
                Spacer(minLength: 8)
                Button(L.t("Clear", "Bỏ chọn")) { pickedProjectId = nil }
                    .font(.footnote)
                    .buttonStyle(.borderless)
            }
        }
    }

    /// Phần danh sách thật sự render. Cắt bớt để màn hình không bị một danh sách dài nuốt mất
    /// phần chọn độ nét bên dưới.
    private var visibleProjects: [ScanProject] {
        let all = filteredProjects
        guard !showAllProjects, all.count > Self.collapsedRowLimit else { return all }
        return Array(all.prefix(Self.collapsedRowLimit))
    }

    @ViewBuilder
    private var existingRows: some View {
        if !filteredProjects.isEmpty {
            // Không có nhãn này thì loạt dòng bên dưới ô nhập trông như thông tin CHỈ ĐỂ XEM,
            // và không ai đoán được gõ chữ sẽ lọc chúng.
            Text(L.t("Already scanned — tap to reuse", "Đã quét — chạm để dùng lại"))
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(visibleProjects) { project in
                Button {
                    // KHÔNG xoá `address`: xoá thì danh sách bung về đầy đủ ngay lúc vừa chạm,
                    // dòng vừa chọn nhảy đi và dấu tích trôi khỏi màn hình → người dùng tưởng
                    // chạm hụt, gõ lại, `onChange` xoá luôn lựa chọn → tạo căn trùng tên. Giữ
                    // nguyên chữ đã gõ thì dòng đứng im dưới ngón tay. (Không sinh vòng lặp:
                    // `onChange` chỉ chạy khi `address` đổi, mà nhánh này không đổi nó.)
                    pickedProjectId = project.id
                } label: {
                    projectRow(project)
                }
            }
            expandRow
        }
    }

    /// Lối vào phần danh sách bị cắt. Chỉ bung THÊM, không bao giờ thu lại: thu lại giữa chừng là
    /// dòng dưới ngón tay nhảy đi — đúng lỗi mà chú thích ở nhánh chạm-chọn phía trên cảnh báo.
    @ViewBuilder
    private var expandRow: some View {
        // So thẳng trong `if`, KHÔNG khai `let` cục bộ: chú thích ở `projectRow` bên dưới ghi rõ
        // khai báo cục bộ trong thân ViewBuilder là chỗ CI này từng chết vì type-check timeout.
        if filteredProjects.count > visibleProjects.count {
            Button {
                showAllProjects = true
            } label: {
                Label(
                    L.t("Show all \(filteredProjects.count) homes", "Xem tất cả \(filteredProjects.count) căn"),
                    systemImage: "chevron.down"
                )
                .font(.footnote)
            }
        }
    }

    /// Tách thành hàm nhận tham số thay vì viết trong ViewBuilder: cần tính `count` trước khi
    /// dựng view, mà khai báo cục bộ trong thân ViewBuilder là chỗ CI này từng chết vì
    /// "type-check timeout".
    ///
    /// MỘT DÒNG, không phải hai: mỗi dòng hai tầng thì năm căn đã chiếm gần nửa màn hình.
    private func projectRow(_ project: ScanProject) -> some View {
        let count = store.scans(in: project).count
        return HStack(spacing: 8) {
            Text(project.name)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(L.t("\(count) scan(s)", "\(count) bản quét"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .layoutPriority(1)
            if pickedProjectId == project.id {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
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

    /// Thanh nút ghim đáy màn — LUÔN nhìn thấy, không phụ thuộc danh sách dài bao nhiêu.
    ///
    /// Lý do nút xám nằm NGAY TRONG thanh, không trông vào footer của section: từ khi ghim đáy,
    /// nút hiện ngay lúc mở màn, còn footer "Bắt buộc — đội vẽ cần biết…" render SAU mọi dòng gợi
    /// ý nên với khách đã có vài căn thì nó nằm dưới đáy màn. Nút xám mà không nói vì sao là lỗi
    /// UX tệ nhất — cùng khuôn nút-xám-kèm-lý-do của `ProjectView.unsupportedNote`.
    private var startBar: some View {
        VStack(spacing: 6) {
            if !hasHome {
                Text(L.t(
                    "Enter the address first — the drafting team needs it.",
                    "Điền địa chỉ trước — đội vẽ cần biết bản vẽ này của căn nào."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            Button {
                start()
            } label: {
                Text(startLabel)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!hasHome)
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .padding(.top, 8)
        .background(.ultraThinMaterial)
    }

    /// Đã xác định được căn nhà chưa — chạm một dòng trong danh sách HOẶC gõ chữ đều tính.
    /// Chạm dòng mà không gõ gì là đường đi hợp lệ (ô nhập vẫn rỗng), nên KHÔNG được chỉ xét
    /// mỗi `address`.
    private var hasHome: Bool {
        pickedProjectId != nil || !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Nút NÓI THẲNG hậu quả khi sắp tạo căn thứ hai trùng tên. Người dùng đọc chữ trên nút họ
    /// đang bấm, không đọc footer — nên đây là chỗ duy nhất cảnh báo chắc chắn tới được. Rẻ hơn
    /// mọi phương án khác: không thêm state, không thêm chạm, không thêm dòng nào trên màn hình.
    ///
    /// Cố ý KHÔNG chặn: tạo căn riêng cùng tên là việc hợp lệ (hai khách cùng gọi "Nhà chị Lan").
    /// Chỉ cần người dùng biết mình đang làm gì.
    private var startLabel: String {
        if exactMatch != nil {
            return L.t("Create a separate home with this name", "Tạo căn RIÊNG cùng tên")
        }
        return L.t("Start scanning", "Bắt đầu quét")
    }
    // KHÔNG có nút "Bỏ qua": địa chỉ giờ BẮT BUỘC, nút Bắt đầu bị khoá tới khi có căn nhà.
    // (Nút "Bỏ qua" từng tồn tại hồi địa chỉ còn tuỳ chọn — nó vừa thừa vừa dễ lẫn với "Hủy" ở
    // góc trên: hai lựa chọn cạnh nhau mà nghĩa ngược hẳn, Hủy = không quét, Bỏ qua = vẫn quét.)

    /// dismiss() TRƯỚC onStart() — cùng khuôn với ScanQualityPickerView: người gọi present màn quét
    /// từ onDismiss của sheet này, nên onStart chỉ được set cờ, không được present gì.
    ///
    /// Chọn dòng trong danh sách → dùng căn đó. Không chọn → tạo căn mới theo chữ đã gõ. Ô rỗng
    /// → nil, bản quét không gắn căn nào (vẫn gắn sau được bằng "Chuyển vào dự án" ở màn chính).
    /// KHÔNG tự gộp khi trùng tên — chỉ nhắc một dòng ở footer rồi để người dùng chạm: gộp nhầm
    /// hai căn khác nhau vào một đơn tệ hơn tách nhầm, vì đội vẽ không có cách nào phát hiện.
    private func start() {
        let id: UUID?
        if let picked = pickedProjectId {
            id = picked
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
