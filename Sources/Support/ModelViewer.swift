import SceneKit
import SwiftUI
import UIKit
import simd

/// **MỘT trình xem 3D DUY NHẤT** cho cả lưới xám lẫn mô hình có texture, đổi qua lại bằng một
/// công tắc "Texture" ở góc. Chủ app chốt 10/08: *"gom cái texture và xám thành 1 … chỉ có nút xem
/// mô hình. nếu bản quét nào có cả texture thì có cái nút gạt Texture ở góc, gạt off thì thành
/// mesh xám, gạt on thì có texture"*.
///
/// 🔴 **VIỆC GỘP NÀY CŨNG LÀ BẢN VÁ ĐÚNG CỦA MỘT LỖI ĐANG MỞ, ✗ chỉ là dọn giao diện.**
/// `ScanDetailView` từng chồng **HAI** `.fullScreenCover` (xám + texture) trên cùng một view, mà
/// một view controller chỉ trình bày ĐƯỢC MỘT thứ tại một thời điểm. Hai đường đó với tới nhau
/// ĐƯỢC — dòng xám nằm ngay trên dòng texture chính là để khách xem lưới trong lúc chờ tải
/// 29–75MB — nên nếu tải xong đúng lúc cover xám đang mở thì lượt trình bày thứ hai bị bỏ, trong
/// khi `readyURL` vẫn khác nil VÀ vẫn cùng `id` (`URL.id` = absoluteString) ⇒ **nút texture chết
/// tới khi khách thoát ra vào lại màn.** Sổ tay đã ghi sẵn cách vá đúng là "gộp về MỘT nguồn
/// trình bày". Nay chỉ còn `ScanDetailView.viewerTarget` là nguồn duy nhất. ✗ thêm cover thứ hai
/// vào màn đó nữa.
///
/// **Bốn ca, cả bốn đều phải đúng:**
///  · có xám + có texture → mở ra XÁM (tức thì, không mạng), công tắc bật lên được;
///  · có xám, chưa có texture (chưa đặt hàng / máy trạm chưa bake) → không có công tắc;
///  · không có xám (bản quét lưu TRƯỚC bản 1.4 — `mesh-preview.bin` không dựng lại được), có
///    texture → mở thẳng texture, không có công tắc;
///  · không có gì → `ScanDetailView` không hiện nút, màn này không bao giờ mở.
///
/// ✗ đổi thành `NavigationStack` + nút Đóng trên `.toolbar`: bar-item host chính là chỗ vụ văng
/// 06/08 sống (`UIKitBarItemHost` đọc `@EnvironmentObject` trước khi cầu environment nối). Nút
/// phủ thường không có bar-item host nào, và màn này không cần gì từ environment.
struct ModelViewerScreen: View {
    /// `mesh-preview.bin` trong thư mục bản quét. nil = bản quét đời trước 1.4.
    let greyURL: URL?
    /// Link mô hình texture trên R2 (máy trạm bake). nil = chưa bake / chưa đặt hàng.
    let texturedRemote: URL?
    /// Id bản quét phía SERVER — `TexturedModelCache` khoá tên file cache theo nó.
    let cloudScanId: String?
    /// 🔴 `@ObservedObject`, ✗ `@StateObject`: chủ sở hữu là `ScanDetailView` và nó phải SỐNG
    /// LÂU HƠN màn này. Lượt tải 29–75MB không bị huỷ khi khách đóng màn (cố ý — xem
    /// `TexturedModelCache.cancel`), nên dựng một bản sao mới ở đây là mất dấu lượt đang chạy.
    @ObservedObject var textured: TexturedModelCache

    @Environment(\.dismiss) private var dismiss

    /// Công tắc. Giá trị đầu do `.task` đặt: có xám thì bắt đầu ở XÁM (mở tức thì, không tốn
    /// mạng), không có xám thì buộc phải là texture.
    @State private var wantTexture = false
    @State private var started = false

    @State private var grey: LoadedModel?
    @State private var greyFailed = false
    @State private var texture: LoadedModel?
    @State private var textureFailed = false

    private var hasTexture: Bool { texturedRemote != nil && cloudScanId != nil }
    /// Công tắc chỉ có nghĩa khi có ĐỦ CẢ HAI thứ để gạt qua gạt lại.
    private var canToggle: Bool { greyURL != nil && hasTexture }

    private var active: LoadedModel? { wantTexture ? texture : grey }
    private var activeFailed: Bool { wantTexture ? textureFailed : greyFailed }

    /// Lỗi TẢI (khác lỗi MỞ ở `activeFailed`). Rút ra thành computed property vì `if case` lồng
    /// trong chuỗi `else if` của một ViewBuilder là chỗ trình biên dịch SwiftUI hay khó chịu, mà
    /// CI là nơi duy nhất bắt được — không đáng đánh đổi lấy hai dòng.
    private var downloadError: String? {
        guard wantTexture, case .failed(let message) = textured.phase else { return nil }
        return message
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color(uiColor: MeshPreviewView.backdropColor)
                .ignoresSafeArea()

            if let active {
                ModelSceneView(model: active)
                    .ignoresSafeArea()
                VStack {
                    Spacer()
                    Text(String(localized: "Drag to rotate · pinch to zoom"))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.bottom, 8)
                    // Caption không bao giờ được nuốt cú kéo dành cho mô hình.
                    .allowsHitTesting(false)
                }
            } else if activeFailed {
                statusBlock(
                    icon: "cube.transparent",
                    text: wantTexture
                        ? String(localized: "Couldn't open the textured model.")
                        : String(localized: "Couldn't open the 3D model for this scan.")
                )
            } else if let message = downloadError {
                statusBlock(
                    icon: "exclamationmark.triangle",
                    text: String(localized: "Couldn't download the model (\(message))")
                )
            } else {
                loadingBlock
            }

            topBar
        }
        .task {
            // `.task` trơn + cờ idempotent, ✗ `.task(id:)`: SwiftUI huỷ nó lúc onDisappear và
            // chạy lại khi appear, mà dựng lại cảnh là vứt đi góc xoay khách vừa chỉnh.
            guard !started else { return }
            started = true
            if let greyURL {
                await loadGrey(greyURL)
            } else {
                wantTexture = true
                await beginTexture()
            }
        }
        // File texture về (có thể đang tải lúc khách bật công tắc) → dựng cảnh.
        .onChange(of: textured.readyURL) { _, url in
            guard let url, texture == nil, !textureFailed else { return }
            Task { await loadTexture(url) }
        }
    }

    // MARK: - Thanh trên: nút Đóng + công tắc Texture

    private var topBar: some View {
        HStack(alignment: .top) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    // Chip đen cố định, ✗ `.ultraThinMaterial`: nền ở đây LUÔN tối bất kể máy
                    // đang light hay dark, nên vật liệu sẽ ra gần trắng ở light mode và nuốt
                    // mất dấu X trắng.
                    .background(Color.black.opacity(0.45), in: Circle())
            }
            .accessibilityLabel(String(localized: "Close"))

            Spacer()

            if canToggle {
                textureToggle
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    /// Công tắc Texture. `Toggle` thật (✗ hai nút hay một segmented) vì chủ app tả đúng cái đó:
    /// *"gạt tắt off thì thành mesh xám, gạt on thì có texture"*.
    private var textureToggle: some View {
        Toggle(isOn: textureBinding) {
            Text("Texture")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
        }
        .toggleStyle(.switch)
        .fixedSize()
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.45), in: Capsule())
        // Đang tải thì khoá công tắc lại: gạt qua gạt lại giữa chừng chỉ đẻ ra câu hỏi "nó có
        // đang tải nữa không". Muốn dừng thì bấm Hủy ở khối đang tải giữa màn.
        .disabled(textured.phase == .downloading && texture == nil)
    }

    /// 🔴 Binding TAY chứ ✗ `$wantTexture`: bật công tắc là một HÀNH ĐỘNG (có thể kéo theo một
    /// lượt tải 29–75MB), không phải chỉ đổi một biến. Đặt việc đó trong setter giữ cho chỉ có
    /// MỘT đường bật texture.
    private var textureBinding: Binding<Bool> {
        Binding(
            get: { wantTexture },
            set: { on in
                wantTexture = on
                guard on else { return }
                Task { await beginTexture() }
            }
        )
    }

    private var loadingBlock: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(.white)
            Text(loadingText)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            if textured.phase == .downloading {
                Button(String(localized: "Cancel")) {
                    textured.cancel()
                    // Về lại lưới xám nếu có — đừng bỏ khách ở màn trống. Không có xám thì
                    // đóng luôn, vì lúc đó màn này không còn gì để hiện.
                    if greyURL != nil {
                        wantTexture = false
                    } else {
                        dismiss()
                    }
                }
                .font(.footnote)
                .tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingText: String {
        if textured.phase == .downloading {
            // Nói rõ ĐANG TẢI (chứ không phải đang mở): 29–75MB qua 4G là chuyện của vài phút,
            // và khách phải biết nó đang tốn dữ liệu di động.
            return String(localized: "Downloading the textured model…")
        }
        return String(localized: "Opening the model…")
    }

    private func statusBlock(icon: String, text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.largeTitle)
                .foregroundStyle(.white.opacity(0.5))
            Text(text)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Nạp

    private func loadGrey(_ url: URL) async {
        guard grey == nil, !greyFailed else { return }
        // `MeshPreviewFile.read` là hàm async KHÔNG gắn actor nên theo SE-0338 việc đọc file +
        // kiểm chỉ số chạy trên cooperative pool. Phần dựng `SCNGeometrySource` là zero-copy,
        // rẻ, chạy lại trên main ở đây — y hệt `MeshPreviewView`.
        guard let decoded = await MeshPreviewFile.read(url) else {
            greyFailed = true
            return
        }
        let built = MeshPreviewView.makeScene(decoded)
        // `makeScene` dời mô hình về gốc toạ độ nên tâm quay đúng bằng zero.
        grey = LoadedModel(scene: built.scene, camera: built.camera, center: SCNVector3Zero)
    }

    /// Bật texture: đã có cảnh thì thôi; có file rồi thì dựng cảnh; chưa có thì bảo cache tải.
    private func beginTexture() async {
        guard texture == nil, !textureFailed else { return }
        if let ready = textured.readyURL {
            await loadTexture(ready)
            return
        }
        guard let cloudScanId, let texturedRemote else {
            // Không có gì để tải mà vẫn tới được đây = ca KHÔNG XẢY RA qua giao diện (`modelRow`
            // giấu nút khi cả hai vế đều rỗng). Vẫn phải đóng lại: bỏ trống là để khách ngồi
            // trước một vòng xoay quay mãi mãi, không nút Hủy, không lời giải thích.
            textureFailed = true
            return
        }
        // Gọi lại lúc đang tải = không làm gì (`open` tự gác), và nó bám vào lượt đang chạy nếu
        // khách vừa đóng/mở lại màn — xem `TexturedModelCache.inFlight`.
        textured.open(scanId: cloudScanId, remote: texturedRemote)
    }

    private func loadTexture(_ url: URL) async {
        guard texture == nil, !textureFailed else { return }
        if let built = await TexturedSceneLoader.load(url) {
            texture = built
        } else {
            textureFailed = true
        }
    }
}

/// Một cảnh đã dựng xong, kèm camera và TÂM của nó trong toạ độ thế giới.
/// Tâm là thứ `SCNCameraController` cần để xoay quanh MÔ HÌNH chứ không quanh gốc toạ độ — và
/// hai mô hình ở đây KHÔNG cùng tâm (lưới xám đã được dời về gốc, mô hình texture thì giữ nguyên
/// toạ độ của bộ đọc USD), nên tâm phải đi kèm từng cảnh.
struct LoadedModel {
    let scene: SCNScene
    let camera: SCNNode
    let center: SCNVector3
}

/// Đọc file `.usdz` + dựng cảnh cho mô hình CÓ TEXTURE.
///
/// 🔴 **VÌ SAO KHÔNG DÙNG QUICKLOOK — LỖI CHỦ APP BÁO 10/08 SAU KHI TEST BẢN 1.8, ✗ ĐƯA VỀ LẠI.**
/// Nguyên văn: *"mô hình có texture khi mở xem thì nó bị phóng to và nền của nó là camera đang
/// mở"*, và khi được hỏi thẳng ông xác nhận **nền CHẠY THEO máy khi cầm điện thoại xoay** (tức
/// camera thật), phải *"phóng nhỏ lại 6% mới vừa màn hình"*. Ba mắt xích đều kiểm được:
///  1. `QLPreviewController` mở `.usdz` bằng **AR Quick Look**, thứ có hai chế độ *Object* (nền
///     trơn) và *AR* (camera + đặt mô hình CỠ THẬT);
///  2. usdz máy trạm xuất ở **đơn vị mét, tỉ lệ thật** (`C:/Block/texbake/export_usdz.py`,
///     `convert_scene_units="METERS"`) nên nhà 10–15m ⇒ ở chế độ AR khách đứng LỌT BÊN TRONG nó
///     ⇒ "bị phóng to", và "6%" chính là thước tỉ lệ của AR Quick Look;
///  3. `USDZPreview` **NHÚNG** `QLPreviewController` làm VC con ⇒ thanh công cụ của Apple không
///     vẽ ra — **cả nút Done LẪN nút gạt Object/AR** ⇒ không có đường thoát khỏi chế độ AR.
/// 🔴 Đó là **HỆ QUẢ THỨ HAI CỦA CÙNG MỘT GỐC**: hệ quả thứ nhất là "màn xem texture không có nút
/// đóng", đã vá bằng một nút X phủ lên ở bản 1.6 — tức 1.6 vá TRIỆU CHỨNG chứ không vá gốc.
/// **Bài học: nhúng một VC mà Apple thiết kế để TRÌNH BÀY thì mất toàn bộ chrome của nó, và
/// chrome đó có thể chứa thứ CHUYỂN CHẾ ĐỘ chứ không chỉ nút đóng.**
/// 🔴 Apple **KHÔNG có API công khai nào tắt chế độ AR** (`ARQuickLookPreviewItem` chỉ chỉnh
/// `allowsContentScaling`/`canonicalWebPageURL`) ⇒ ✗ đề xuất lại "bọc vào UINavigationController
/// cho hiện nút gạt": cái đó chỉ cho khách ĐƯỜNG THOÁT khỏi AR, không ngăn nó mở ra ở chế độ AR.
///
/// 🔴 **PHẢI là một kiểu RIÊNG, ✗ static func của một View.** SwiftUI `View` là `@MainActor` nên
/// static func của nó cũng thừa hưởng `@MainActor` và cú đọc 29–75MB sẽ chạy THẲNG trên main =
/// đơ vài giây. Hàm `async` không gắn actor thì theo SE-0338 chạy trên cooperative pool. Cùng
/// khuôn với `MeshPreviewFile.read`.
enum TexturedSceneLoader {
    static func load(_ url: URL) async -> LoadedModel? {
        // `SCNScene(url:)` đọc thẳng `.usdz` (nó là archive USD; SceneKit hỗ trợ từ iOS 12).
        guard let scene = try? SCNScene(url: url, options: nil) else { return nil }

        // Vật liệu: ảnh texture là ẢNH CHỤP THẬT, tức ÁNH SÁNG ĐÃ NẰM SẴN TRONG ẢNH. Chiếu sáng
        // nó lần thứ HAI (PBR như file usdz khai báo) là đẻ ra vệt bóng loáng và tường tối dần ở
        // góc nghiêng — không giống cái máy trạm render ra. `.constant` là chế độ "vẽ thẳng ảnh
        // diffuse ra, không đổ bóng, không specular" — cùng công thức mọi trình xem ảnh 360° của
        // SceneKit dùng (quả cầu + ảnh + `.constant`, không đèn nào, vẫn sáng đủ).
        // ✅ **ĐÃ CHẠY THẬT TRÊN MÁY 10/08 (bản 2.0) — chủ app: "OK RỒI, MÔ HÌNH HIỆN RA".** Rủi
        // ro "màn đen" KHÔNG xảy ra. Đèn ambient bên dưới là DÂY BẢO HIỂM cho cách đọc tài liệu
        // của Apple ("`.constant` chỉ tính ánh sáng ambient"); nay chưa ai tách được là hình hiện
        // NHỜ đèn hay `.constant` vốn không cần đèn — nên **✗ gỡ đèn đi "cho gọn"**, đó là thí
        // nghiệm không ai đang cần và hỏng thì hỏng ra màn đen.
        // 🔴 LEVER NẾU MỘT NGÀY NÀO ĐÓ RA MÀN ĐEN: bỏ `.constant` (để nguyên vật liệu như file
        // khai) và bật `autoenablesDefaultLighting = true` ở `ModelSceneView`. Hình sẽ hiện chắc
        // chắn, đổi lại là bóng loáng. ✗ vặn cả hai núm cùng lúc, mất khả năng đọc kết quả.
        scene.rootNode.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry else { return }
            for material in geometry.materials {
                material.lightingModel = .constant
                material.isDoubleSided = false
                // 🔴 CHIỀU CULL DÙNG CHUNG VỚI LƯỚI XÁM — xem `MeshPreviewView.sharedCullMode`.
                // Hai mô hình đọc CÙNG một hình học (mesh của app → OBJ giao → bake), nên lập
                // luận winding ở đó áp nguyên vào đây; và để chung một hằng số nghĩa là nếu
                // chiều sai thì SỬA MỘT CHỖ, hai chế độ của công tắc không bao giờ lệch nhau.
                material.cullMode = MeshPreviewView.sharedCullMode
            }
        }

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.color = UIColor(white: 1, alpha: 1)
        ambient.intensity = 1000
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        guard let bounds = worldBounds(scene.rootNode) else { return nil }
        let center = (bounds.lo + bounds.hi) * 0.5
        let radius = max(simd_length(bounds.hi - bounds.lo) * 0.5, 0.5)

        // Khung hình: đặt camera đủ xa để một hình cầu bán kính `radius` (nửa ĐƯỜNG CHÉO hộp bao,
        // nên chứa trọn mô hình dù hình thù thế nào) lọt vào, kèm biên 1.5×. Thừa khung thì khách
        // chụm tay phóng vào, còn thiếu khung là cắt mất nhà ngay cái nhìn đầu tiên — mà "cắt mất
        // ngay cái nhìn đầu tiên" chính là nửa sau của lỗi chủ app báo.
        //
        // 🔴 `projectionDirection = .horizontal` LÀ THỨ CHỊU LỰC, ✗ xoá. `fieldOfView` mặc định
        // gắn vào trục DỌC, mà app này chỉ chạy dọc màn hình nên trục NGANG mới là trục chật:
        // 55° dọc trên màn 393×852 chỉ còn ~27° ngang → cụt ~10% mỗi đầu căn nhà. Lý do đầy đủ +
        // phép tính ở `MeshPreviewView.makeScene`.
        let fovDegrees: Float = 55
        let halfFov = fovDegrees * .pi / 360
        let distance = radius / tan(halfFov) * 1.5
        // 30°: CÙNG GÓC MỞ với lưới xám, để gạt công tắc qua lại là thấy đúng một căn nhà ở đúng
        // một góc, ✗ hai bố cục khác nhau.
        let elevation: Float = 30 * .pi / 180

        let camera = SCNCamera()
        camera.fieldOfView = CGFloat(fovDegrees)
        camera.projectionDirection = .horizontal
        camera.zNear = Double(max(0.05, radius * 0.01))
        camera.zFar = Double(distance + radius * 6 + 10)

        let cameraNode = SCNNode()
        cameraNode.camera = camera
        // 🔴 DỜI CAMERA, ✗ DỜI MÔ HÌNH — khác `MeshPreviewView` một cách CỐ Ý. Ở đó hình học do
        // chính app dựng nên dời node thoải mái; ở đây cây node là do bộ đọc USD dựng, và gốc của
        // nó có thể mang sẵn phép biến đổi trục-lên/đơn vị. Bê con của nó sang một node khác là
        // vứt phép biến đổi đó đi → nhà nằm nghiêng. Đặt camera quanh `center` thì không đụng gì
        // tới cây node cả. (Đó cũng là lý do `LoadedModel` phải mang theo `center`.)
        cameraNode.position = SCNVector3(
            center.x,
            center.y + distance * sin(elevation),
            center.z + distance * cos(elevation)
        )
        // Camera SceneKit mặc định nhìn theo −Z; chúi xuống `elevation` quanh trục X là nó nhắm
        // đúng vào `center`.
        cameraNode.eulerAngles = SCNVector3(-elevation, 0, 0)
        scene.rootNode.addChildNode(cameraNode)

        return LoadedModel(
            scene: scene,
            camera: cameraNode,
            center: SCNVector3(center.x, center.y, center.z)
        )
    }

    /// Hộp bao của TOÀN BỘ mô hình trong toạ độ THẾ GIỚI.
    ///
    /// 🔴 ✗ dùng `rootNode.boundingBox` cho việc này. Cây node do USD dựng ra có hình học nằm ở
    /// các node CON, mỗi node mang phép biến đổi riêng; đọc hộp bao của một node là đọc trong hệ
    /// toạ độ CỦA CHÍNH NÓ. Phải duyệt từng node có hình học, đưa **cả 8 góc** hộp bao của nó ra
    /// hệ thế giới rồi mới gộp — 8 góc chứ không phải 2, vì một phép xoay biến min/max cũ thành
    /// hai điểm không còn là min/max nữa.
    private static func worldBounds(_ root: SCNNode) -> (lo: SIMD3<Float>, hi: SIMD3<Float>)? {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var found = false
        root.enumerateHierarchy { node, _ in
            guard node.geometry != nil else { return }
            let box = node.boundingBox
            for corner in 0..<8 {
                let point = SCNVector3(
                    (corner & 1) == 0 ? box.min.x : box.max.x,
                    (corner & 2) == 0 ? box.min.y : box.max.y,
                    (corner & 4) == 0 ? box.min.z : box.max.z
                )
                let world = node.convertPosition(point, to: nil)
                let v = SIMD3<Float>(world.x, world.y, world.z)
                lo = simd_min(lo, v)
                hi = simd_max(hi, v)
                found = true
            }
        }
        return found ? (lo, hi) : nil
    }
}

/// Vỏ `SCNView` dùng chung cho CẢ HAI chế độ. Mọi tương tác là bộ điều khiển camera có sẵn của
/// SceneKit — không viết cử chỉ riêng để phải tranh chấp với SwiftUI.
///
/// 🔴 Khác `MeshSceneView` (bản chỉ-xám) đúng một điểm và đó là lý do nó tồn tại: `updateUIView`
/// ở đây **CÓ** đổi cảnh, vì gạt công tắc Texture là một lần đổi cảnh THẬT. Nhưng chỉ đổi khi cảnh
/// KHÁC ĐI (`!==`) — gán lại `scene` ở mọi lượt cập nhật của SwiftUI là bắn camera về góc mặc
/// định đúng lúc khách đang xoay dở.
private struct ModelSceneView: UIViewRepresentable {
    let model: LoadedModel

    final class Coordinator {
        var shown: SCNScene?
        var center = SCNVector3Zero
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true
        // Đèn khai tường minh trong từng cảnh (lưới xám: đèn chính + ambient; texture: ambient +
        // vật liệu `.constant`). Đèn mặc định của SCNView là đèn đội đầu, bật lên là làm bẹt lưới
        // xám và chiếu sáng lần hai lên ảnh đã có sáng sẵn.
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling2X
        view.backgroundColor = MeshPreviewView.backdropColor
        view.preferredFramesPerSecond = 60
        apply(to: view, context.coordinator)
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        apply(to: uiView, context.coordinator)
    }

    private func apply(to view: SCNView, _ coordinator: Coordinator) {
        guard coordinator.shown !== model.scene else { return }

        // MANG GÓC NHÌN SANG CẢNH MỚI. Gạt công tắc mà mô hình nhảy về góc mặc định thì khách
        // mất chỗ đang xem — mà cả lý do tồn tại của công tắc là "vẫn cái nhà đó, bật/tắt lớp
        // ảnh". Hai cảnh KHÔNG cùng tâm nên phải chuyển vị trí camera theo hiệu so với tâm, ✗
        // chép thẳng transform.
        if coordinator.shown != nil, let old = view.pointOfView {
            model.camera.position = SCNVector3(
                model.center.x + (old.position.x - coordinator.center.x),
                model.center.y + (old.position.y - coordinator.center.y),
                model.center.z + (old.position.z - coordinator.center.z)
            )
            model.camera.orientation = old.orientation
            // 🔴 PHẢI MANG CẢ `fieldOfView`, và đây là kết luận ĐỌC RA TỪ MÁY THẬT chứ ✗ đoán.
            // Chủ app test bản 2.0 (10/08): *"nếu chưa zoom in out thì gạt qua lại giữ nguyên
            // góc, nhưng zoom in out thì nó quay về kích thước ban đầu"*. Góc XOAY giữ được mà
            // độ PHÓNG thì không ⇒ `SCNCameraController` phóng to bằng cách đổi `fieldOfView`
            // của đối tượng `SCNCamera`, ✗ bằng cách dời node lại gần (dời node thì đoạn chuyển
            // vị trí ngay trên đã giữ hộ rồi). Mà mỗi cảnh mang một `SCNCamera` RIÊNG, nên đổi
            // cảnh là về lại 55° gốc.
            // ✗ chép luôn `zNear`/`zFar`: hai giá trị đó tính theo bán kính của TỪNG mô hình.
            if let oldCamera = old.camera, let newCamera = model.camera.camera {
                newCamera.fieldOfView = oldCamera.fieldOfView
            }
        }

        view.scene = model.scene
        view.pointOfView = model.camera
        view.defaultCameraController.target = model.center
        coordinator.shown = model.scene
        coordinator.center = model.center
    }
}
