import SwiftUI
import AVKit

/// Màn hiện NGAY sau khi bản quét đã lưu xong, trước khi đóng phiên quét: căn nhà + video vừa
/// quay + ba lối đi (quét thêm / đặt hàng sau / đặt hàng ngay).
///
/// VÌ SAO ĐỨNG Ở ĐÂY chứ không để khách tự tìm vào trang bản quét: đây là khoảnh khắc DUY NHẤT
/// khách còn đứng trong căn nhà vừa quét. Xem lại video ngay lúc này mà phát hiện thiếu phòng
/// thì quét bù mất vài phút; phát hiện ở nhà thì phải quay lại một chuyến.
///
/// KHÔNG có nút thoát nào khác ngoài ba nút này (fullScreenCover không vuốt đóng được) — cố ý:
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
    /// "Quét thêm khu vực còn thiếu" — mở một phiên quét MỚI cho CÙNG căn nhà.
    ///
    /// KHÔNG phải "quét tiếp": `stopAndExport` đã giải phóng bộ tích lũy mesh, đóng recorder và
    /// pause ARSession, nên phiên sau là một `ARSession` mới với GỐC TOẠ ĐỘ MỚI — hai mesh nằm ở
    /// hai hệ toạ độ không liên quan nhau và đội vẽ ghép tay lúc dựng, y như nhà nhiều tầng.
    /// (Muốn máy tự ghép thì phải đi đường `ARWorldMap` + relocalize — dự án riêng.)
    let onScanMore: () -> Void
    let onOrderLater: () -> Void
    let onOrderNow: () -> Void

    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            // Nền ĐỤC phủ kín: view này là lớp trên cùng của ZStack trong MeshScanFlowView, bên
            // dưới vẫn còn khung hình camera đóng băng và nút "Dừng & Lưu". Nền trong suốt là
            // khách thấy hai giao diện chồng nhau và bấm nhầm xuống lớp dưới.
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                header
                videoArea
                footer
            }
        }
        .task {
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
            Label(L.t("Scan saved", "Đã lưu bản quét"), systemImage: "checkmark.circle.fill")
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
                Text(L.t(
                    "No walkthrough video was recorded — your 3D scan was still saved.",
                    "Không quay được video hành trình — mô hình 3D của bạn vẫn đã được lưu."
                ))
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
            // Chỉ còn một việc: soi video. Chuyện "đặt sau vẫn được" đã nằm ngay trên nhãn nút
            // nên nhắc lại ở đây là thừa.
            Text(L.t(
                "Check the video for any room you missed.",
                "Xem lại video để chắc không sót phòng nào."
            ))
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
                    L.t("Scan another area of this home", "Quét thêm khu vực còn thiếu"),
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
                    Text(L.t("Order later", "Đặt hàng sau"))
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.bordered)

                Button(action: onOrderNow) {
                    Text(L.t("Order now", "Đặt hàng ngay"))
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
