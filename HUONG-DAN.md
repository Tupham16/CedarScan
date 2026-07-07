# CedarScan — Hướng dẫn sử dụng

App quét không gian 3D bằng LiDAR trên iPhone, tương tự CubiCasa. Quét phòng bằng camera → tự động tạo **mô hình 3D** và **sơ đồ mặt bằng 2D** có kích thước từng bức tường, diện tích sàn, vị trí cửa/cửa sổ/đồ đạc.

## Yêu cầu

- **iPhone Pro** (12 Pro trở lên) hoặc **iPad Pro** — bắt buộc phải có cảm biến LiDAR
- iOS 17 trở lên
- Máy tính Windows để cài app lần đầu (không cần máy Mac)

## Tính năng

| Tính năng | Mô tả |
|---|---|
| Quét phòng | Giao diện quét AR của Apple: đi chậm quanh phòng, app tự nhận diện tường, cửa, cửa sổ, đồ đạc |
| Quét nhiều phòng | Quét xong 1 phòng bấm "Quét phòng tiếp theo" — các phòng tự ghép thành một căn nhà hoàn chỉnh |
| Mô hình 3D | Xoay, phóng to, và cả chế độ AR (đặt mô hình thu nhỏ lên mặt bàn thật) |
| Mặt bằng 2D | Tường, cửa (kèm cánh mở), cửa sổ, đồ đạc, kích thước từng tường (m), diện tích sàn (m²) |
| Chia sẻ | File 3D (.usdz — mở được trên iPhone/Mac/web) và ảnh mặt bằng (.png) |

## Cách build app (không cần Mac)

Code được build **tự động miễn phí** trên GitHub Actions mỗi khi đưa code lên:

1. Đưa code lên một kho GitHub **công khai (public)** — kho public thì máy chủ macOS của GitHub build **miễn phí không giới hạn** (kho private chỉ được ~200 phút macOS/tháng).
2. Vào tab **Actions** trên trang GitHub của kho → chọn lần chạy mới nhất → kéo xuống mục **Artifacts** → tải **CedarScan-ipa** (file zip, giải nén ra `CedarScan.ipa`).
3. File `.ipa` này **chưa ký** — AltStore sẽ tự ký bằng Apple ID của bạn khi cài (bước dưới).

## Cách cài lên iPhone từ Windows (AltStore — miễn phí)

> Làm 1 lần duy nhất các bước 1–5. Từ đó về sau chỉ cần bước 6.

1. **Cài iTunes và iCloud từ trang Apple** (apple.com) — ⚠️ **không dùng bản trong Microsoft Store**; nếu đã lỡ cài bản Store thì gỡ ra trước (Settings → Apps). Đây là lỗi phổ biến nhất khiến AltServer không nhận iPhone.
2. **Cài AltServer**: tải từ [altstore.io](https://altstore.io) (bản Windows / AltStore Classic), chạy `Setup.exe`, sau đó tìm "AltServer" trong menu Start và **chạy với quyền Administrator**. Biểu tượng hình thoi xuất hiện ở khay hệ thống (góc dưới phải, cạnh đồng hồ). Nếu Windows hỏi tường lửa → cho phép mạng riêng (Private).
3. **Cắm iPhone vào máy tính bằng cáp USB**, mở khóa iPhone, bấm **Tin cậy (Trust)** và nhập mật mã. Mở iTunes → bấm biểu tượng điện thoại → tích **"Sync with this iPhone over Wi-Fi"** → Apply (để sau này không cần cáp).
4. **Cài AltStore lên iPhone**: bấm biểu tượng AltServer ở khay → **Install AltStore** → chọn iPhone → nhập Apple ID + mật khẩu (thông tin chỉ gửi đến Apple). Chờ báo "Installation Succeeded".
5. **Trên iPhone**:
   - Cài đặt → Cài đặt chung → **VPN & Quản lý thiết bị** → bấm vào dòng có email Apple ID → **Tin cậy**.
   - Cài đặt → Quyền riêng tư & Bảo mật → **Chế độ nhà phát triển (Developer Mode)** → bật (iPhone khởi động lại 1 lần).
6. **Cài CedarScan**: **giữ phím Shift và bấm** biểu tượng AltServer ở khay → **Sideload .ipa** → chọn file `CedarScan.ipa` đã tải → chọn iPhone. Xong! Khi có bản mới, lặp lại đúng bước này — app cài đè, dữ liệu quét giữ nguyên.

### Giới hạn của cách cài miễn phí (nên biết)

- App hết hạn sau **7 ngày** — nhưng nếu để AltServer chạy trên máy tính và iPhone cùng mạng Wi-Fi, AltStore **tự gia hạn** trong nền. Hoặc mở app AltStore trên iPhone → My Apps → Refresh All.
- Tối đa **3 app** cài kiểu này cùng lúc (AltStore chiếm 1 suất).
- Nếu quên gia hạn quá 7 ngày, app không mở được nữa (dữ liệu vẫn còn) — chỉ cần cài lại từ máy tính.

## Con đường lên App Store sau này

Khi thử nghiệm ổn và muốn đưa cho khách dùng:

1. Đăng ký **Apple Developer Program** — 99 USD/năm (cần thẻ tín dụng, duyệt vài ngày).
2. Khi đó app ký chính thức: **không còn hạn 7 ngày**, phát cho người khác thử qua **TestFlight** (tối đa 10.000 người), rồi nộp duyệt lên **App Store**.
3. Sẽ cần bổ sung: chính sách quyền riêng tư, ảnh chụp màn hình, mô tả app — báo Claude làm tiếp khi đến bước này.

## Mẹo quét đẹp (giống hướng dẫn của CubiCasa)

- Cầm iPhone hơi chếch xuống, đi **chậm** men theo tường, cách tường 1–2 m.
- Quét đủ các góc phòng; cửa và cửa sổ nên quét thẳng mặt.
- Phòng quá tối hoặc kính/gương nhiều sẽ giảm độ chính xác.
- Mỗi phòng 1–3 phút là đủ; bấm "Xong phòng này" rồi đi sang phòng kế, **không tắt app giữa chừng** khi quét nhiều phòng.
