import SwiftUI

/// Hướng dẫn quét đẹp — hiện lần đầu trước khi quét + mở lại được từ nút (?).
///
/// VIẾT LẠI 2026-07-19 cho chế độ Quét 3D nguyên căn. Bản cũ dạy sai: nó bảo bấm "Xong phòng
/// này" / "Quét phòng tiếp theo" (nút của RoomPlan, chế độ mesh KHÔNG có) và bảo "mỗi tầng quét
/// một bản riêng" (ngược hẳn — mesh mode quét liền mạch qua cầu thang).
///
/// TẠM THỜI (pha 1): chế độ RoomPlan vẫn còn trong app nhưng sẽ bị xóa ở pha sau, nên hướng
/// dẫn này cố ý chỉ dạy luồng mesh. Ai còn chọn RoomPlan trong lúc chuyển tiếp sẽ thấy vài
/// lời khuyên không áp dụng cho họ — chấp nhận, vì luồng đó sắp biến mất.
///
/// Mốc "khoảng 10 phút" ở mục đầu KHÔNG phải con số cho đẹp, nó chống hai thứ đo được:
///  1. NHIỆT — máy dòng 12→15 Pro throttle sau ~15–30 phút tải nặng; iOS lặng lẽ hạ camera
///     xuống 30fps và làm chậm meshing → hình học bị thủng ở khu quét sau.
///  2. ĐỘ PHỦ MÀU — ColorMeshBuilder tự GIÃN ĐÔI nhịp chụp khung màu mỗi lần bộ đệm đầy.
///     Quét 25 phút thì nửa sau gần như không lấy được màu mới (nhịp đã tụt về 12–25 giây/khung).
struct ScanGuideView: View {
    @Environment(\.dismiss) private var dismiss
    /// Có thì hiện nút "Bắt đầu quét" (luồng lần đầu); nil = chỉ xem.
    var onStart: (() -> Void)? = nil

    static let seenKey = "hasSeenScanGuide"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    beforeSection
                    whileSection
                    floorsSection
                    savingSection
                    startButton
                }
                .padding(20)
            }
            .navigationTitle(L.t("How to scan well", "Cách quét đẹp"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L.t("Close", "Đóng")) {
                        UserDefaults.standard.set(true, forKey: Self.seenKey)
                        dismiss()
                    }
                }
            }
        }
    }

    // Tách từng mục thành computed property riêng — CI từng timeout type-check với
    // biểu thức SwiftUI lớn, gộp cả 4 mục vào một VStack là mời gọi lỗi đó quay lại.

    private var beforeSection: some View {
        tipSection(
            icon: "checklist",
            title: L.t("Before you scan", "Trước khi quét"),
            tips: [
                L.t("Turn on all the lights and open interior doors.",
                    "Bật hết đèn, mở các cửa trong nhà."),
                L.t("Clear walking paths — you will walk through every room.",
                    "Dọn lối đi — bạn sẽ đi qua mọi phòng."),
                L.t("Around 10 minutes per scan is the sweet spot. Bigger homes take longer and that is fine — just know the phone gets hotter and colour is captured less often as a scan drags on.",
                    "Khoảng 10 phút mỗi bản quét là đẹp nhất. Nhà lớn cần lâu hơn thì cứ quét đủ — chỉ cần biết trước: quét càng dài máy càng nóng và app lấy màu càng thưa dần."),
                L.t("Take the case off and stay out of direct sun — it keeps the phone from throttling.",
                    "Tháo ốp lưng, tránh nắng trực tiếp — đỡ bị máy bóp hiệu năng."),
            ]
        )
    }

    private var whileSection: some View {
        tipSection(
            icon: "figure.walk",
            title: L.t("While scanning", "Trong lúc quét"),
            tips: [
                L.t("Hold the phone at chest height, tilted slightly down.",
                    "Cầm máy ngang ngực, hơi chúc xuống."),
                L.t("Walk SLOWLY along the walls. Slow is accurate.",
                    "Đi CHẬM men theo tường. Chậm = chính xác."),
                L.t("Point the camera at every wall, corner, door and window.",
                    "Hướng camera vào mọi bức tường, góc phòng, cửa và cửa sổ."),
                L.t("Keep about 40cm or more from surfaces — closer than roughly 30cm and the LiDAR starts punching holes in the mesh. When the app says \"Step back a little\", step back.",
                    "Giữ cách bề mặt khoảng 40cm trở lên — dí sát dưới ~30cm là LiDAR bắt đầu tạo lỗ thủng. App hiện \"Lùi ra xa một chút\" thì lùi lại."),
                L.t("Sweep the ceiling once in each room so the room closes up as a solid volume.",
                    "Lia lên trần một lượt ở mỗi phòng để hình khối phòng khép kín."),
                L.t("Avoid pointing at mirrors and large glass for too long.",
                    "Tránh chĩa lâu vào gương và kính lớn."),
            ]
        )
    }

    private var floorsSection: some View {
        // icon "building.2": SF Symbol đã dùng sẵn trong bản cũ của file này nên chắc chắn tồn
        // tại trên target iOS 17. Tên SF Symbol sai KHÔNG gây lỗi compile — CI vẫn xanh và chỉ
        // lộ ra ô trống lúc sideload, nên chỗ này cố ý chọn cái đã được chứng minh.
        tipSection(
            icon: "building.2",
            title: L.t("Several floors — scan straight through", "Nhiều tầng — quét liền một mạch"),
            tips: [
                L.t("Do NOT stop between floors. Walk up the stairs while still scanning — that is what keeps the floors stacked correctly in 3D.",
                    "ĐỪNG dừng giữa các tầng. Vừa quét vừa đi lên cầu thang — đó là thứ giữ các tầng chồng đúng nhau trong 3D."),
                L.t("Take the stairs extra slowly, keeping the steps in view.",
                    "Lên cầu thang thật chậm, giữ bậc thang trong khung hình."),
                L.t("Every time you stop and save, the next scan starts a brand new coordinate system — two separate scans will NOT line up on their own.",
                    "Mỗi lần dừng và lưu là bản quét sau bắt đầu một hệ toạ độ hoàn toàn mới — hai bản riêng sẽ KHÔNG tự khớp nhau."),
                L.t("If the home is too big for one pass, split at a natural break (through a door, a separate wing) rather than mid-room.",
                    "Nhà lớn quá không quét hết một mạch thì chia ở ranh giới tự nhiên (qua cửa, sang một cánh nhà khác), đừng cắt giữa phòng."),
                L.t("When you do split, start the next scan by walking back through a room you already scanned — that overlap is what lets our team line the parts up by hand.",
                    "Khi buộc phải chia, hãy bắt đầu bản sau bằng cách đi lại qua một phòng đã quét — phần chồng lấn đó là thứ giúp đội xử lý ghép các phần lại bằng tay."),
            ]
        )
    }

    private var savingSection: some View {
        tipSection(
            icon: "square.and.arrow.down",
            title: L.t("When you finish", "Khi quét xong"),
            tips: [
                L.t("Tap Stop & Save, NAME the scan and tap Save — the scan is still recording until you do. Only then put the phone down.",
                    "Bấm Dừng & Lưu, ĐẶT TÊN bản quét rồi bấm Lưu — chưa bấm là máy vẫn đang quét tiếp. Xong bước đó mới đặt máy xuống."),
                L.t("After that the screen stays on by itself until saving finishes — leave the phone alone.",
                    "Sau đó màn hình tự sáng cho tới khi lưu xong — cứ để yên máy, đừng chạm vào."),
                L.t("Building the model takes a couple of minutes on a large home — do not close the app.",
                    "Dựng mô hình mất vài phút với nhà lớn — đừng tắt app."),
                L.t("Saving works the processor hard, so if another area is still to scan, let the phone rest a few minutes first.",
                    "Lúc lưu máy chạy hết công suất để dựng mô hình, nên nếu còn khu khác phải quét thì để máy nghỉ vài phút cho nguội đã."),
            ]
        )
    }

    @ViewBuilder
    private var startButton: some View {
        if let onStart {
            Button {
                UserDefaults.standard.set(true, forKey: Self.seenKey)
                dismiss()
                onStart()
            } label: {
                Text(L.t("Got it — start scanning", "Hiểu rồi — bắt đầu quét"))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
    }

    private func tipSection(icon: String, title: String, tips: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.headline)
            ForEach(tips, id: \.self) { tip in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.green)
                        .padding(.top, 2)
                    Text(tip)
                        .font(.subheadline)
                }
            }
        }
    }
}
