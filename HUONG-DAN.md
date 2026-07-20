# CedarScan — Hướng dẫn sử dụng

App quét không gian 3D bằng cảm biến LiDAR trên iPhone. Bạn đi một vòng quanh nhà, app dựng
**mô hình 3D màu** của cả căn cùng một **video walkthrough**, rồi gửi cho đội ngũ Cedar247 —
họ vẽ lại thành **bản vẽ mặt bằng 2D chuyên nghiệp** và giao lại cho bạn ngay trong app.

> **App KHÔNG tự vẽ mặt bằng.** Mặt bằng là do người vẽ, từ mô hình 3D và video bạn gửi lên.
> Trên máy bạn chỉ có mô hình 3D và video — đó là nguyên liệu, không phải thành phẩm.

## Yêu cầu

- **Máy có cảm biến LiDAR** — iPhone bản **Pro, 12 Pro trở lên**, hoặc **iPad Pro có LiDAR**.
  App không kiểm tên máy, nó hỏi thẳng hệ thống xem có LiDAR không. Máy không có vẫn cài được
  nhưng nút quét bị khoá xám (chữ trong app viết là "cần iPhone bản Pro").
- **iOS 17** trở lên. App chỉ chạy dọc (portrait).
- Máy tính **Windows** để cài app lần đầu (không cần máy Mac).
- App chỉ xin quyền **camera**. Không xin micro, không xin vị trí, không xin thư viện ảnh.

---

## Phần 1 — Quét

### Bước 1: Nhập địa chỉ (bắt buộc)

Bấm **"Quét không gian mới"** ở đáy màn hình. Lần đầu tiên app sẽ hiện màn *Cách quét đẹp* — đọc
xong bấm **"Hiểu rồi — bắt đầu quét"**.

Tiếp theo app hỏi **"Căn nhà này ở đâu?"**. Đây là **bắt buộc, không bỏ qua được** — đội vẽ cần
biết bản vẽ này của căn nào. Gõ địa chỉ tự do, không ép định dạng.

- Nếu căn đó **đã quét trước đây**, nó nằm sẵn trong danh sách bên dưới — **chạm để dùng lại**,
  đừng gõ tay. Chạm vào là bản quét mới được gom vào đúng căn cũ.
- Gõ tên mới → tạo căn mới.

> **Nhà nhiều tầng: quét LIỀN MỘT MẠCH, đừng dừng giữa các tầng.** Vừa quét vừa đi lên cầu thang
> thật chậm, **giữ bậc thang trong khung hình** — đó là thứ giữ các tầng chồng đúng nhau trong 3D.
>
> Nhà quá lớn không đi hết một hơi thì chia ở **ranh giới tự nhiên** (qua một cái cửa, sang cánh
> nhà khác) — **đừng cắt giữa phòng**. Và khi chia thì phải theo quy tắc ở mục
> *"Khi bạn quét bản thứ hai cho cùng một căn"* bên dưới.
>
> Nhiều bản quét cùng một căn thì gắn chung một địa chỉ, lúc đặt hàng tick cả mấy bản vào
> **MỘT đơn** — rẻ hơn đặt lẻ.

### Bước 2: Chọn độ nét

Hai mức: **Vừa** và **Nét** (mặc định là Nét).

Hai mức cho **hình học và dung lượng file y hệt nhau** — chỉ khác app chụp khung màu dày hay thưa.
Mức Nét cho **màu dày gấp đôi** nhưng **lưu lâu hơn đáng kể** (nhà lớn có thể mất vài phút). Cần
lưu nhanh thì chọn Vừa.

### Bước 3: Quét

Bấm **"Bắt đầu quét"** rồi đi một vòng. Trong lúc quét:

- **Lưới xanh** = đã vào mô hình. **Lưới đỏ** = chưa ghi được, cần quét lại chỗ đó.
  (Tắt/bật lưới bằng nút góc trên phải.)
- App **nhắc bạn theo thời gian thực** bằng viền màn hình nhấp nháy + rung: *Đi chậm lại*,
  *Xoay chậm lại*, *Bật thêm đèn*, *Lùi ra xa một chút*, *Máy nóng — nghỉ chút cho nguội*,
  *Đứng yên một chút*. Có thể bật thêm nhắc **bằng giọng nói** ở tab Tài khoản.
- Xong thì bấm **"Dừng & Lưu"**, đặt tên bản quét, **rồi bấm Lưu** — chưa bấm Lưu là **máy vẫn
  đang quét tiếp**. Xong bước đó mới đặt máy xuống.
- Nếu app hiện *"Chưa quét được mô hình 3D"* nghĩa là bạn mới thu được rất ít dữ liệu: chọn
  **"Quét tiếp"** rồi đi thêm vài giây, hướng camera vào tường và sàn.

> ⚠️ **Lúc lưu đừng tắt app và đừng chạm vào máy.** Nhà lớn mất vài phút để dựng mô hình. Màn hình
> tự sáng cho tới khi xong.

Sau khi lưu, app hiện **màn xem lại**: video vừa quay + địa chỉ. Từ đây bạn chọn
**"Quét thêm khu vực còn thiếu"**, **"Đặt hàng sau"**, hoặc **"Đặt hàng ngay"**.

### 🔴 Khi bạn quét bản thứ hai cho cùng một căn

Quy tắc này áp dụng cho **mọi** trường hợp bạn tạo bản quét thứ hai của cùng một căn nhà — bấm
*"Quét thêm khu vực còn thiếu"*, quét tiếp sau khi app báo *"Mô hình đã đầy"*, hay chia nhà lớn
thành nhiều phần.

**Máy KHÔNG tự ghép được.** Mỗi lần bấm Dừng & Lưu là bản quét sau bắt đầu một **hệ toạ độ hoàn
toàn mới** — hai bản nằm ở hai hệ không liên quan nhau, đội ngũ phải ghép **bằng tay**.

> **Vì vậy: bắt đầu bản mới bằng cách đi lại qua một phòng bạn ĐÃ quét.** Phần chồng lấn đó chính
> là mốc để ghép. Nếu bạn đi thẳng tới khu còn thiếu và bắt đầu quét ở đó, hai bản không có điểm
> chung nào — đội vẽ không có gì để khớp.

### Mẹo quét đẹp

**Trước khi quét**
- Bật hết đèn, mở các cửa trong nhà, dọn lối đi.
- **Tháo ốp lưng**, tránh nắng trực tiếp — đỡ bị máy bóp hiệu năng.

**Trong lúc quét**
- Cầm máy **ngang ngực, hơi chúc xuống**.
- Đi **CHẬM** men theo tường. Chậm = chính xác.
- Hướng camera vào **mọi bức tường, góc phòng, cửa và cửa sổ**.
- Giữ cách bề mặt **khoảng 40cm trở lên**. Dí sát dưới ~30cm là LiDAR bắt đầu thủng lỗ mesh —
  app báo *"Lùi ra xa một chút"* thì lùi thật.

**Thời lượng**
- **Khoảng 10 phút mỗi bản quét là đẹp nhất.** Nhà lớn cần lâu hơn thì cứ quét đủ — chỉ cần biết
  trước: quét càng dài máy càng nóng và app lấy màu càng thưa dần.
- Còn khu khác phải quét thì **để máy nghỉ vài phút cho nguội** rồi hãy quét tiếp.

**Nếu app báo "Mô hình đã đầy"**
Mô hình 3D có trần dung lượng. Chạm trần thì bấm **Dừng & Lưu** phần đang có (phần đó vẫn an toàn),
rồi quét khu còn lại thành **một bản quét MỚI** — đặt tên `Part 1`, `Part 2`…

Nhớ áp dụng quy tắc ở mục **"Khi bạn quét bản thứ hai cho cùng một căn"** — phải có phần chồng lấn,
không thì đội vẽ không ghép được. Lúc đặt hàng tick cả hai bản vào cùng một đơn.

---

## Phần 2 — Đặt hàng

### Tài khoản

Phải có tài khoản mới đặt được. Đăng ký ngay trong app (tên, email, mật khẩu từ 8 ký tự), sau đó
**xác minh email bằng mã 6 số** app gửi tới hộp thư của bạn. Gửi lại mã được, cách nhau 60 giây.

Ở màn bản quét, nếu chưa đăng nhập/chưa xác minh thì có nút bấm thẳng vào đó — đăng nhập xong quay
lại đúng chỗ cũ.

### Form đặt hàng

Mở bằng nút **"Đặt làm mặt bằng"**. Form gồm:

| Mục | Nội dung |
|---|---|
| **Các tầng trong đơn này** | Tick các bản quét cùng căn nhà. **MỘT đơn tính giá cho CẢ căn** — nhớ tick đủ |
| **Gói dịch vụ** | Chọn một gói. Danh sách và giá lấy từ máy chủ |
| **Dịch vụ thêm** | Ví dụ **Virtual Tour** (xem dưới) |
| **Tùy chọn** | Đơn vị đo (mét/feet), ngôn ngữ bản vẽ, kiểu đặt tên tầng — **được lưu cho lần sau**. Riêng **ghi chú thêm thì KHÔNG lưu**, mỗi đơn phải gõ lại |
| **Mã giảm giá** | Không bắt buộc, áp dụng ở trang thanh toán |

Khách mới có thể được **miễn phí một số đơn đầu** — nếu còn lượt, app hiện băng "Đơn này MIỄN PHÍ"
kèm số lượt còn lại.

> ⚠️ **Nên đặt hàng khi đang ở Wi-Fi** — mỗi bản quét 40–200MB. Thời điểm tải lên khác nhau tuỳ
> bạn mở form từ đâu:
> - **Từ một bản quét** (nút "Đặt làm mặt bằng" ở màn bản quét): app tải bản đó lên **ngay lúc
>   bấm**, tải xong mới mở form. Bản đã tải từ lần trước thì form mở luôn, không tải lại.
> - **Từ trang căn nhà** (nút "Đặt làm mặt bằng (N bản quét)"): form mở ngay, **toàn bộ** các bản
>   quét mới được tải lên lúc bấm **"Đặt hàng"** — đây mới là lúc tốn mạng nhất.

Bấm **"Đặt hàng"** để chốt. Sau khi đặt sẽ có link thanh toán (Stripe/PayPal); đội ngũ bắt đầu làm
sau khi nhận thanh toán.

### Virtual Tour (dịch vụ thêm)

> Dịch vụ này Cedar247 bật/tắt theo từng thời điểm. Nếu bạn không thấy nó trong mục **Dịch vụ thêm**
> lúc đặt hàng thì hiện chưa nhận — cứ hỏi Cedar247.

Chọn add-on này thì sau khi đặt, bạn thêm **ảnh cho từng phòng** — app hiện sẵn số ảnh tối đa mỗi
phòng ngay trên ô thêm ảnh, dạng `0/3` (thường là 3, con số do Cedar247 đặt). Đơn cũng có thể có
trần tổng số ảnh; vượt thì app báo lỗi ngay tại màn thêm ảnh. Đội ngũ ghim ảnh vào đúng vị trí trên
mặt bằng, và khi giao hàng bạn nhận **link tour tương tác để chia sẻ**.

Thêm ảnh ngay sau khi đặt, hoặc bất cứ lúc nào ở tab **Đơn hàng**. Đặt tên phòng **bằng tiếng Anh**
để người xem trang tour đọc được. Tour đã giao rồi thì ảnh bị khoá, muốn đổi phải liên hệ hỗ trợ.

---

## Phần 3 — Nhận hàng

Theo dõi ở tab **Đơn hàng**: trạng thái *Đã nhận → Đang xử lý → Đã giao*. Kéo xuống để làm mới.

Ngoài ba mốc chính còn hai trạng thái khác: **Tạm giữ** (đơn tạm dừng — liên hệ Cedar247 để biết
lý do) và **Hoàn tiền**.

Khi đơn **Đã giao**, bấm **"Tải file thành phẩm"** để tải bản vẽ về.

**Bạn nhận được định dạng nào**

| | |
|---|---|
| **Mặc định, mọi đơn** | **PDF + JPG** |
| Yêu cầu thêm được | **SVG, PNG** — ghi vào ô *"Ghi chú thêm"* lúc đặt, hoặc nhắn cho Cedar247 |
| **DWG (file CAD)** | **Dịch vụ thêm, tính tiền riêng** — tick add-on **"CAD file (DWG)"** lúc đặt hàng |

**Chưa ưng?** Bấm **"Yêu cầu sửa"** (chỉ hiện sau khi đã giao), mô tả cần sửa gì. **Sửa lỗi thuộc
về Cedar247 là miễn phí.**

> ⚠️ Trong lúc chờ sửa, **file thành phẩm cũ tạm thời không tải được nữa** — đơn quay về trạng thái
> đang xử lý. Nên **tải file về máy trước khi gửi yêu cầu sửa.**

---

## ⚠️ Quan trọng: app tự xoá bản quét sau 14 ngày

**Sau khi đơn của bạn được giao, CedarScan tự xoá bản quét gốc khỏi iPhone sau 14 ngày** để giải
phóng dung lượng (mỗi bản quét 40–200MB). Việc này **diễn ra tự động, không hỏi lại**.

**File thành phẩm KHÔNG bị ảnh hưởng** — bản vẽ nằm trên máy chủ Cedar247, tải lại bất cứ lúc nào
ở tab Đơn hàng.

Thứ bị xoá là **nguyên liệu gốc trên máy bạn**: mô hình 3D và video walkthrough.

> **Muốn giữ mô hình 3D hoặc video gốc?** Dùng nút **Chia sẻ** ở màn bản quét để lưu ra nơi khác
> (iCloud, máy tính…) **trước khi hết 14 ngày**. Chia sẻ được: mô hình 3D màu (file .zip chứa OBJ +
> GLB) và video.

App có nhiều lớp bảo vệ để không xoá nhầm: bản quét còn dính **đơn chưa xong** thì không bị xoá;
đang quét hoặc đang lưu thì hoãn; mất mạng hoặc dữ liệu không đầy đủ thì **không xoá gì cả**.

---

## Cách cài app lên iPhone từ Windows (AltStore — miễn phí)

> Làm 1 lần duy nhất các bước 1–5. Từ đó về sau chỉ cần bước 6.

1. **Cài iTunes và iCloud từ trang Apple** (apple.com) — ⚠️ **không dùng bản trong Microsoft Store**;
   nếu đã lỡ cài bản Store thì gỡ ra trước (Settings → Apps). Đây là lỗi phổ biến nhất khiến
   AltServer không nhận iPhone.
2. **Cài AltServer**: tải từ [altstore.io](https://altstore.io) (bản Windows / AltStore Classic),
   chạy `Setup.exe`, sau đó tìm "AltServer" trong menu Start và **chạy với quyền Administrator**.
   Biểu tượng hình thoi xuất hiện ở khay hệ thống (góc dưới phải, cạnh đồng hồ). Nếu Windows hỏi
   tường lửa → cho phép mạng riêng (Private).
3. **Cắm iPhone vào máy tính bằng cáp USB**, mở khóa iPhone, bấm **Tin cậy (Trust)** và nhập mật mã.
   Mở iTunes → bấm biểu tượng điện thoại → tích **"Sync with this iPhone over Wi-Fi"** → Apply
   (để sau này không cần cáp).
4. **Cài AltStore lên iPhone**: bấm biểu tượng AltServer ở khay → **Install AltStore** → chọn iPhone
   → nhập Apple ID + mật khẩu (thông tin chỉ gửi đến Apple). Chờ báo "Installation Succeeded".
5. **Trên iPhone**:
   - Cài đặt → Cài đặt chung → **VPN & Quản lý thiết bị** → bấm vào dòng có email Apple ID →
     **Tin cậy**.
   - Cài đặt → Quyền riêng tư & Bảo mật → **Chế độ nhà phát triển (Developer Mode)** → bật
     (iPhone khởi động lại 1 lần).
6. **Cài CedarScan**: **giữ phím Shift và bấm** biểu tượng AltServer ở khay → **Sideload .ipa** →
   chọn file `CedarScan.ipa` → chọn iPhone. Xong! Khi có bản mới, lặp lại đúng bước này — app cài
   đè, **dữ liệu quét giữ nguyên**.

### Giới hạn của cách cài miễn phí (nên biết)

- App hết hạn sau **7 ngày** — nhưng nếu để AltServer chạy trên máy tính và iPhone cùng mạng Wi-Fi,
  AltStore **tự gia hạn** trong nền. Hoặc mở app AltStore trên iPhone → My Apps → Refresh All.
- Tối đa **3 app** cài kiểu này cùng lúc (AltStore chiếm 1 suất).
- Nếu quên gia hạn quá 7 ngày, app không mở được nữa (dữ liệu vẫn còn) — chỉ cần cài lại từ máy tính.

## Con đường lên App Store sau này

1. Đăng ký **Apple Developer Program** — 99 USD/năm (cần thẻ tín dụng, duyệt vài ngày).
2. Khi đó app ký chính thức: **không còn hạn 7 ngày**, phát cho người khác thử qua **TestFlight**
   (tối đa 10.000 người), rồi nộp duyệt lên **App Store**.
3. Sẽ cần bổ sung: chính sách quyền riêng tư, ảnh chụp màn hình, mô tả app.
