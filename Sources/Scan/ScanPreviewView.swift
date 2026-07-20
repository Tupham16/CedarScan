import SwiftUI
import AVKit

/// Màn hiện NGAY sau khi bản quét đã lưu xong, trước khi đóng phiên quét: căn nhà + video vừa
/// quay + hai lối đi (đặt hàng ngay / để sau).
///
/// VÌ SAO ĐỨNG Ở ĐÂY chứ không để khách tự tìm vào trang bản quét: đây là khoảnh khắc DUY NHẤT
/// khách còn đứng trong căn nhà vừa quét. Xem lại video ngay lúc này mà phát hiện thiếu phòng
/// thì quét bù mất vài phút; phát hiện ở nhà thì phải quay lại một chuyến.
///
/// KHÔNG có nút thoát nào khác ngoài hai nút này (fullScreenCover không vuốt đóng được) — cố ý:
/// hai lối đi đã phủ hết mọi ý định, và cả hai đều an toàn vì BẢN QUÉT ĐÃ LƯU XONG trước khi màn
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

    // MARK: - Hai lối đi

    private var footer: some View {
        VStack(spacing: 10) {
            Text(L.t(
                "Check the video for any room you missed. You can order the floor plan now or later.",
                "Xem lại video để chắc không sót phòng nào. Bạn có thể đặt bản vẽ ngay hoặc để sau."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button(action: onOrderLater) {
                    Text(L.t("Order later", "Để sau"))
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
