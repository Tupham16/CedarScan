import SwiftUI
import AVKit

/// Màn hiện NGAY sau khi bản quét đã lưu xong, trước khi đóng phiên quét: căn nhà + video vừa
/// quay + ba lối đi (quét thêm / đặt hàng sau / đặt hàng ngay).
///
/// VÌ SAO ĐỨNG Ở ĐÂY chứ không để khách tự tìm vào trang bản quét: đây là khoảnh khắc DUY NHẤT
/// khách còn đứng trong căn nhà vừa quét. Xem lại video ngay lúc này mà phát hiện thiếu phòng
/// thì quét bù mất vài phút; phát hiện ở nhà thì phải quay lại một chuyến.
///
/// KHÔNG có nút thoát nào khác ngoài ba nút này (cover quét — `.overFullScreen` từ 2.11, đời
/// trước là fullScreenCover — đều không vuốt đóng được) — cố ý:
/// ba lối đi đã phủ hết mọi ý định, và cả ba đều an toàn vì BẢN QUÉT ĐÃ LƯU XONG trước khi màn
/// này xuất hiện. Không đường nào ở đây làm mất dữ liệu.
struct ScanPreviewView: View {
    /// Tên căn nhà (dự án). nil khi không tra ra dự án: bản quét không gắn căn nào (`projectId`
    /// nil vì `createProject` bị tên toàn khoảng trắng trả nil), hoặc dự án đã bị xoá. Màn địa
    /// chỉ bắt buộc điền nên đây là ca hiếm — nhưng tiêu đề vẫn phải có chữ, xem `header`.
    let addressName: String?
    let scanName: String
    /// Đã kiểm `fileExists` TRƯỚC khi truyền vào. nil = không có video (recorder fail lặng lẽ,
    /// hoặc `moveItem` lúc lưu hỏng — `ScanStore.saveMeshScan` dùng `try?` và không kiểm lại).
    let videoURL: URL?
    /// Lưới XÁM nhẹ (mesh-preview.bin) trong thư mục bản quét, ĐÃ kiểm `fileExists`.
    /// nil = không có gì để xem → ô chọn Video/Mô hình 3D không hiện, màn này y hệt bản cũ.
    let meshPreviewURL: URL?
    /// "Quét thêm khu vực còn thiếu" — mở một phiên quét MỚI cho CÙNG căn nhà.
    ///
    /// KHÔNG phải "quét tiếp": `stopAndExport` đã giải phóng bộ tích lũy mesh, đóng recorder và
    /// pause ARSession, nên phiên sau là một `ARSession` mới với GỐC TOẠ ĐỘ MỚI — hai mesh nằm ở
    /// hai hệ toạ độ không liên quan nhau và đội vẽ ghép tay lúc dựng, y như nhà nhiều tầng.
    /// (Muốn máy tự ghép thì phải đi đường `ARWorldMap` + relocalize — dự án riêng.)
    /// Dự án này ĐÃ có đơn ⇒ nút chính là **"Gửi bổ sung bản quét"**, ✗ "Đặt hàng ngay"
    /// (chủ app chốt 11/08: *"1 dự án chỉ có 1 đơn"*). Màn này cố ý KHÔNG tự tra `ScanStore` —
    /// nó nhận toàn giá trị thường (xem các `let` ở trên), nên điều kiện được tính ở
    /// `MeshScanFlowView` bằng `ScanStore.orderNumber(ofProject:)`, cùng nguồn với hai màn kia.
    var isSupplement = false
    let onScanMore: () -> Void
    let onOrderLater: () -> Void
    let onOrderNow: () -> Void

    @State private var player: AVPlayer?
    /// Ô chọn Video / Mô hình 3D. Chỉ tồn tại khi có `meshPreviewURL`.
    @State private var showingMesh = false

    var body: some View {
        ZStack {
            // Nền ĐỤC phủ kín: view này là lớp trên cùng của ZStack trong MeshScanFlowView, bên
            // dưới vẫn còn khung hình camera đóng băng và nút "Dừng & Lưu". Nền trong suốt là
            // khách thấy hai giao diện chồng nhau và bấm nhầm xuống lớp dưới.
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                header
                mediaPicker
                mediaArea
                footer
            }
        }
        // Video và mô hình 3D KHÔNG bao giờ sống cùng lúc: đổi tab là tháo hẳn view kia khỏi
        // cây, nên chỉ có MỘT bộ giải mã / MỘT scene SceneKit tại một thời điểm.
        // AVPlayer sống theo @State chứ không theo view, nên bỏ view đi mà không pause là nó
        // chạy tiếp dưới nền (cùng bẫy với `onDisappear` bên dưới, và với #12).
        .onChange(of: showingMesh) { _, mesh in
            if mesh {
                player?.pause()
            } else {
                player?.play()
            }
        }
        .task {
            // Không quay được video mà vẫn có mô hình → mở thẳng tab 3D, đừng bắt khách nhìn
            // ô "không có video" rồi tự đoán là còn tab khác.
            if videoURL == nil, meshPreviewURL != nil {
                showingMesh = true
            }
            guard let videoURL else { return }
            let player = AVPlayer(url: videoURL)
            self.player = player
            // Tự phát: khách vừa bấm Lưu và đang chờ — bắt bấm thêm một nút Play nữa là thừa.
            // KHÔNG lo tiếng động bất ngờ: ScanVideoRecorder chỉ dựng AVAssetWriterInput video,
            // file không có track âm thanh nào.
            player.play()
        }
        .onDisappear {
            // Không pause là AVPlayer chạy tiếp sau khi cover đóng (video 10-30 phút) — giữ
            // decoder H.264 sống và ngốn pin trong lúc khách đã sang màn khác.
            player?.pause()
            player = nil
        }
    }

    // MARK: - Đầu màn: căn nhà này là căn nào

    private var header: some View {
        VStack(spacing: 4) {
            Label(String(localized: "Scan saved"), systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)
            // Địa chỉ là thứ khách cần đối chiếu nhất ("mình vừa quét đúng căn chưa?") nên nó là
            // dòng TO. Thiếu địa chỉ thì tên bản quét lên thay — không bao giờ để tiêu đề rỗng.
            Text(addressName ?? scanName)
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if addressName != nil {
                Text(scanName)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    // MARK: - Chọn Video / Mô hình 3D

    /// Chủ app duyệt 10/08: "trong 3dscannerapp khi khách quét xong thì ngoài xem video thì nó
    /// cũng cho xem cả mesh (đen trắng)". MỘT ô chọn hai mục — không thêm nút, không thêm màn:
    /// khu vực media vốn đã chiếm hết chỗ giữa, đây chỉ là đổi thứ đang vẽ trong đó.
    /// Bản quét cũ / bản không dựng được lưới xem-trước thì ô này KHÔNG hiện chút nào.
    @ViewBuilder
    private var mediaPicker: some View {
        if meshPreviewURL != nil {
            Picker("", selection: $showingMesh) {
                Text(String(localized: "Video")).tag(false)
                Text(String(localized: "3D model")).tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var mediaArea: some View {
        if showingMesh, let meshPreviewURL {
            MeshPreviewView(url: meshPreviewURL)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            videoArea
        }
    }

    // MARK: - Video vừa quay

    @ViewBuilder
    private var videoArea: some View {
        if let player {
            VideoPlayer(player: player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if videoURL != nil {
            // Có file nhưng player chưa dựng xong (một nhịp của .task).
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // KHÔNG có video KHÔNG có nghĩa là mất bản quét: mesh 3D — thứ đội vẽ thật sự dùng —
            // nằm ở file khác và đã lưu xong. Nói rõ điều đó, đừng để khách tưởng hỏng cả buổi.
            VStack(spacing: 10) {
                Image(systemName: "video.slash")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(String(localized: "No walkthrough video was recorded — your 3D scan was still saved."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Ba lối đi

    private var footer: some View {
        VStack(spacing: 10) {
            // Chỉ còn một việc: soi lại thứ vừa quét. Chuyện "đặt sau vẫn được" đã nằm ngay
            // trên nhãn nút nên nhắc lại ở đây là thừa. Câu chữ theo đúng tab đang mở — bảo
            // "xem lại video" trong lúc khách đang xoay mô hình là chỉ sai chỗ.
            Text(showingMesh
                ? String(localized: "Spin the model to check for any room you missed.")
                : String(localized: "Check the video for any room you missed."))
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

            // DÒNG RIÊNG, không phải nút thứ ba trong hàng: đây là hành động KHÁC LOẠI với hai
            // nút dưới — quay lại làm việc, chứ không phải rời màn. Nhét cả ba vào một hàng thì
            // trên máy nhỏ chữ bị bóp, mà khu video vốn đã hẹp.
            //
            // LUÔN hiện, không chỉ khi mô hình chạm trần: nhà cỡ thường không bao giờ chạm trần
            // 2M nhưng khách vẫn quên nguyên một phòng — và phát hiện được lúc còn đứng trong nhà
            // chính là lý do màn preview này tồn tại.
            Button(action: onScanMore) {
                Label(
                    String(localized: "Scan another area of this home"),
                    systemImage: "viewfinder"
                )
                .font(.subheadline.weight(.semibold))
                // Không có hai dòng này thì vùng chạm chỉ cao bằng chữ (~20pt) — dưới chuẩn 44pt
                // của Apple, mà nó lại nằm cách nút "Đặt hàng ngay" đúng 10pt.
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }

            HStack(spacing: 12) {
                Button(action: onOrderLater) {
                    // "Đặt hàng sau", KHÔNG phải "Để sau" và cũng không phải "Xong" (chủ app chốt
                    // 2026-07-20 sau khi dùng thử cả hai):
                    //  • "Để sau" trống nghĩa — từ khi có lối "Quét thêm" ngay trên, nó đọc được
                    //    thành "để sau hãy QUÉT".
                    //  • "Xong" nghe như đóng hẳn việc, khách tưởng hết cơ hội đặt.
                    // "Đặt hàng sau" thành cặp song song với "Đặt hàng ngay": cùng nói về ĐẶT
                    // HÀNG, chỉ khác thời điểm, nên không nhánh nào đọc nhầm sang chuyện quét.
                    Text(String(localized: "Order later"))
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.bordered)

                Button(action: onOrderNow) {
                    // Bổ sung thì KHÔNG mở form giá (không thu tiền) — nhãn phải nói đúng việc
                    // sắp xảy ra, không thì khách bấm "Đặt hàng ngay" rồi thấy một màn không có
                    // giá và tưởng app hỏng.
                    Text(isSupplement
                         ? String(localized: "Send extra scan")
                         : String(localized: "Order now"))
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }
}
