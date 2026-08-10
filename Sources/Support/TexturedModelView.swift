import SceneKit
import SwiftUI
import UIKit
import simd

/// Trình xem mô hình CÓ TEXTURE (file `.usdz` do MÁY TRẠM bake) — **tự vẽ bằng SceneKit,
/// KHÔNG dùng QuickLook**.
///
/// 🔴 **VÌ SAO BỎ QUICKLOOK — LỖI CHỦ APP BÁO 10/08 SAU KHI TEST BẢN 1.8, ✗ ĐƯA NÓ VỀ LẠI.**
/// Nguyên văn: *"mô hình có texture khi mở xem thì nó bị phóng to và nền của nó là camera đang
/// mở"*, và khi được hỏi thẳng ông xác nhận **nền CHẠY THEO máy khi cầm điện thoại xoay** (tức
/// camera thật), phải *"phóng nhỏ lại 6% mới vừa màn hình"*.
/// Cơ chế, ba mắt xích đều kiểm được:
///  1. `QLPreviewController` mở file `.usdz` bằng **AR Quick Look**, thứ có hai chế độ
///     *Object* (nền trơn) và *AR* (camera + đặt mô hình CỠ THẬT). Ông đang ở chế độ AR.
///  2. File usdz máy trạm xuất ra ở **đơn vị mét, tỉ lệ thật**
///     (`C:/Block/texbake/export_usdz.py`, `convert_scene_units="METERS"`), nên một căn nhà là
///     10–15m: ở chế độ AR khách đứng LỌT BÊN TRONG nó ⇒ "bị phóng to", và "6%" chính là thước
///     tỉ lệ của AR Quick Look.
///  3. `USDZPreview` NHÚNG `QLPreviewController` làm VC con, nên toàn bộ thanh công cụ của Apple
///     không vẽ ra — **cả nút Done LẪN nút gạt Object/AR**. Vì vậy không có đường nào thoát khỏi
///     chế độ AR. Đây là **HỆ QUẢ THỨ HAI CỦA CÙNG MỘT GỐC**: hệ quả thứ nhất là "màn xem texture
///     không có nút đóng", đã phải vá bằng một nút X phủ lên ở bản 1.6.
/// 🔴 **Apple KHÔNG có API công khai nào tắt chế độ AR của `QLPreviewController`.**
/// `ARQuickLookPreviewItem` chỉ chỉnh được `allowsContentScaling`/`canonicalWebPageURL`, không
/// chọn được chế độ. ⇒ Muốn chắc chắn không bao giờ có camera thì phải THÔI DÙNG QuickLook ở màn
/// này. Đó là việc file này làm.
/// ⚠ `USDZPreview` (QuickLook) VẪN CÒN, cho call site LEGACY `ScanDetailView.legacyTab` — bản
/// quét RoomPlan đời cũ. **Gần như chắc chắn nó cũng dính đúng lỗi này**, nhưng chưa ai có bản
/// quét cũ để thử, và đổi một đường không kiểm được thì tệ hơn để nguyên. Ghi ở §OPEN.
///
/// ✗ đổi thành `NavigationStack` + nút Đóng trên `.toolbar`: bar-item host chính là chỗ vụ văng
/// 06/08 sống (`UIKitBarItemHost` đọc `@EnvironmentObject` trước khi cầu environment nối). Nút
/// phủ thường không có bar-item host nào, và màn này không cần gì từ environment.
/// Cùng khuôn với `GreyMeshViewerScreen` là CỐ Ý — hai trình xem 3D phải đóng giống hệt nhau.
struct TexturedModelViewerScreen: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topLeading) {
            TexturedModelView(url: url)
                .ignoresSafeArea()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    // Chip đen cố định, ✗ `.ultraThinMaterial`: nền ở đây LUÔN tối bất kể máy
                    // đang light hay dark, nên vật liệu sẽ ra gần trắng ở light mode và nuốt mất
                    // dấu X trắng.
                    .background(Color.black.opacity(0.45), in: Circle())
            }
            .padding(.leading, 16)
            .padding(.top, 12)
            .accessibilityLabel(L.t("Close", "Đóng"))
        }
    }
}

/// Máy trạng thái tải + hiển thị. Cùng khuôn với `MeshPreviewView` (nền tối, spinner, nhánh
/// hỏng, caption cử chỉ) để hai trình xem 3D của app cư xử y hệt nhau.
private struct TexturedModelView: View {
    let url: URL

    /// Dựng MỘT LẦN rồi không thay — xem `TexturedSceneView.updateUIView`.
    @State private var loaded: TexturedSceneLoader.Loaded?
    @State private var failed = false

    var body: some View {
        ZStack {
            Color(uiColor: MeshPreviewView.backdropColor)

            if let loaded {
                TexturedSceneView(
                    scene: loaded.scene,
                    cameraNode: loaded.camera,
                    target: loaded.center
                )
                VStack {
                    Spacer()
                    Text(L.t(
                        "Drag to rotate · pinch to zoom",
                        "Kéo để xoay · chụm hai ngón để phóng to"
                    ))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.bottom, 8)
                    // Caption không bao giờ được nuốt cú kéo dành cho mô hình.
                    .allowsHitTesting(false)
                }
            } else if failed {
                VStack(spacing: 10) {
                    Image(systemName: "cube.transparent")
                        .font(.largeTitle)
                        .foregroundStyle(.white.opacity(0.5))
                    Text(L.t(
                        "Couldn't open the textured model.",
                        "Không mở được mô hình có texture."
                    ))
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                }
            } else {
                // File này 29–75MB nên KHÔNG mở tức thì như lưới xám (2–6MB) — phải có chữ, không
                // thì vòng xoay trơ vài giây đọc thành "treo".
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(.white)
                    Text(L.t("Opening the model…", "Đang mở mô hình…"))
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        // `.task` trơn + guard idempotent, ✗ `.task(id:)`: SwiftUI huỷ nó lúc onDisappear và chạy
        // lại khi appear, mà dựng lại cảnh là vứt đi góc xoay khách vừa chỉnh (cùng lý do đã ghi
        // ở `MeshPreviewView`).
        .task {
            guard loaded == nil, !failed else { return }
            if let result = await TexturedSceneLoader.load(url) {
                loaded = result
            } else {
                failed = true
            }
        }
    }
}

/// Đọc file + dựng cảnh. 🔴 **PHẢI là một kiểu RIÊNG, ✗ static func của cái View ở trên.**
/// SwiftUI `View` là `@MainActor`, nên một static func của nó cũng thừa hưởng `@MainActor` và cú
/// đọc 29–75MB sẽ chạy THẲNG trên main = đơ vài giây. Hàm `async` KHÔNG gắn actor thì theo SE-0338
/// chạy trên cooperative pool. Cùng khuôn với `MeshPreviewFile.read`.
private enum TexturedSceneLoader {
    struct Loaded {
        let scene: SCNScene
        let camera: SCNNode
        /// Tâm hộp bao, trong toạ độ THẾ GIỚI — `defaultCameraController.target` cần nó để xoay
        /// quanh mô hình chứ không quanh gốc toạ độ.
        let center: SCNVector3
    }

    static func load(_ url: URL) async -> Loaded? {
        // `SCNScene(url:)` đọc thẳng `.usdz` (nó là archive USD; SceneKit hỗ trợ từ iOS 12).
        guard let scene = try? SCNScene(url: url, options: nil) else { return nil }

        // Vật liệu: ảnh texture là ẢNH CHỤP THẬT, tức ÁNH SÁNG ĐÃ NẰM SẴN TRONG ẢNH. Chiếu sáng
        // nó lần thứ HAI (PBR như file usdz khai báo) là đẻ ra vệt bóng loáng và tường tối dần ở
        // góc nghiêng — không giống cái máy trạm render ra. `.constant` là chế độ "vẽ thẳng ảnh
        // diffuse ra, không đổ bóng, không specular" — cùng công thức mọi trình xem ảnh 360° của
        // SceneKit dùng (quả cầu + ảnh + `.constant`, không đèn nào, vẫn sáng đủ).
        // ⚠ Đèn ambient bên dưới là DÂY BẢO HIỂM, ✗ phải thứ bắt buộc: tài liệu của Apple tả
        // `.constant` là "chỉ tính ánh sáng ambient", nên nếu bản SceneKit này thật sự nhân
        // diffuse với ambient thì thiếu đèn là ra màn ĐEN. Có đèn thì đúng cả hai cách hiểu.
        // 🔴 LEVER NẾU MÁY THẬT VẪN RA MÀN ĐEN: bỏ `.constant` (để nguyên vật liệu như file khai)
        // và bật `autoenablesDefaultLighting = true` ở `TexturedSceneView`. Hình sẽ hiện chắc
        // chắn, đổi lại là bóng loáng. ✗ vặn cả hai núm cùng lúc, mất khả năng đọc kết quả.
        scene.rootNode.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry else { return }
            for material in geometry.materials {
                material.lightingModel = .constant
                material.isDoubleSided = false
                // 🔴 CHIỀU CULL DÙNG CHUNG VỚI LƯỚI XÁM — xem `MeshPreviewView.sharedCullMode`.
                // Hai trình xem đọc CÙNG một hình học (mesh của app → OBJ giao → bake), nên lập
                // luận winding ở đó áp nguyên vào đây; và để chung một hằng số nghĩa là nếu chiều
                // sai thì SỬA MỘT CHỖ, hai màn không bao giờ lệch nhau.
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
        // ngay cái nhìn đầu tiên" chính là lỗi chủ app vừa báo.
        //
        // 🔴 `projectionDirection = .horizontal` LÀ THỨ CHỊU LỰC, ✗ xoá. `fieldOfView` mặc định
        // gắn vào trục DỌC, mà app này chỉ chạy dọc màn hình nên trục NGANG mới là trục chật:
        // 55° dọc trên màn 393×852 chỉ còn ~27° ngang → cụt ~10% mỗi đầu căn nhà. Lý do đầy đủ +
        // phép tính ở `MeshPreviewView.makeScene`.
        let fovDegrees: Float = 55
        let halfFov = fovDegrees * .pi / 360
        let distance = radius / tan(halfFov) * 1.5
        // 25° trên đường chân trời: đủ để đọc ra bố cục các phòng mà chưa thành ảnh nhìn-từ-nóc.
        let elevation: Float = 25 * .pi / 180

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
        // tới cây node cả.
        cameraNode.position = SCNVector3(
            center.x,
            center.y + distance * sin(elevation),
            center.z + distance * cos(elevation)
        )
        // Camera SceneKit mặc định nhìn theo −Z; chúi xuống `elevation` quanh trục X là nó nhắm
        // đúng vào `center`.
        cameraNode.eulerAngles = SCNVector3(-elevation, 0, 0)
        scene.rootNode.addChildNode(cameraNode)

        return Loaded(
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

/// Vỏ `SCNView`. Mọi tương tác là bộ điều khiển camera có sẵn của SceneKit — không viết cử chỉ
/// riêng để phải tranh chấp với SwiftUI. Cùng cấu hình với `MeshSceneView` của lưới xám.
private struct TexturedSceneView: UIViewRepresentable {
    let scene: SCNScene
    let cameraNode: SCNNode
    let target: SCNVector3

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = scene
        view.pointOfView = cameraNode
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.target = target
        view.defaultCameraController.inertiaEnabled = true
        // Đèn khai tường minh ở `TexturedSceneLoader.load` (ambient trắng, vật liệu `.constant`);
        // đèn mặc định của SCNView là đèn đội đầu, bật lên là chiếu sáng lần hai lên ảnh đã có
        // sáng sẵn.
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling2X
        view.backgroundColor = MeshPreviewView.backdropColor
        view.preferredFramesPerSecond = 60
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        // Cố ý để trống. `scene`/`cameraNode` dựng một lần và không bao giờ bị thay; gán lại
        // `uiView.scene` mỗi lần SwiftUI cập nhật là bắn camera về góc mặc định đúng lúc khách
        // đang xoay dở.
    }
}
