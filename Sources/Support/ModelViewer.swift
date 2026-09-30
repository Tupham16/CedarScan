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
/// **Views + floors (2.76, owner 30/09, `PLAN-XEM-3D-TANG-MAU.md`, mockup 73 minus Floor plan):**
/// bottom glass capsules `All · Floor 1 · Floor 2…` (≥ 2 floors, found ON THE PHONE by
/// `MeshLayout` from the grey preview) and `Dollhouse | Top view` (`ViewerMode.offered`).
/// Opens Dollhouse + All = the old default camera. Top view = perspective straight down, own
/// pan / pinch / twist, no tilt, straightened along the main walls. Floors clip every material
/// with a shader modifier (`FloorClip`). The Texture switch keeps view + floor.
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

    /// Floors + wall direction from the GREY preview (`MeshLayout`). Also drives the textured
    /// model (same ARKit frame), so the floor buttons do not change when Texture flips.
    /// nil = no grey (pre-1.4 scan) or analysis failed ⇒ no floor buttons.
    @State private var layout: MeshLayout?
    /// Floor shown; nil = All. Kept across the Texture switch and the view switch.
    @State private var floor: Int?
    /// Last tap on the view switch. A tap on the mode already shown re-frames it (serial).
    @State private var framing = FramingRequest(mode: .dollhouse, serial: 0)

    private var floorCount: Int { layout?.floors.count ?? 0 }

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
                ModelSceneView(
                    model: active,
                    layout: layout ?? active.boundsLayout,
                    floor: floor,
                    framing: framing
                )
                .ignoresSafeArea()
                bottomControls
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
                    // Fog dark glass (as on the scan screen): always dark, so the white X
                    // stays visible in light mode too.
                    .fogGlass(Circle())
            }
            .accessibilityLabel(String(localized: "Close"))

            Spacer()

            if canToggle {
                textureToggle
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        // The backdrop is dark in both modes: the switch uses its dark-mode track (mockup).
        .environment(\.colorScheme, .dark)
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
        .fogGlass(Capsule())
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

    // MARK: - Bottom: floors + view switch (mockup 73, 2 modes after the owner's 30/09 call)

    /// Glass capsules over the model, above the caption. Floors only with ≥ 2 floors, the view
    /// switch only with ≥ 2 offered modes (`ViewerMode.offered`). The `Spacer` and the gaps
    /// pass touches through to the model; the caption never eats a drag.
    private var bottomControls: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            if floorCount >= 2 {
                floorPicker
            }
            if ViewerMode.offered.count >= 2 {
                modePicker
            }
            WrappedText(
                framing.mode.caption,
                style: .caption2,
                alignment: .center,
                color: UIColor.white.withAlphaComponent(0.55)
            )
            .allowsHitTesting(false)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        // Text in the capsules grows with Dynamic Type, but not past the model it sits on.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .environment(\.colorScheme, .dark)
    }

    private var modePicker: some View {
        HStack(spacing: 2) {
            ForEach(ViewerMode.offered, id: \.self) { mode in
                ViewerSegment(title: mode.title, selected: framing.mode == mode, action: {
                    framing = FramingRequest(mode: mode, serial: framing.serial + 1)
                }) {
                    ViewerModeIcon(mode: mode)
                }
            }
        }
        .padding(3)
        .fogGlass(Capsule())
    }

    /// Many floors (a spurious level, a tall house) scroll instead of squeezing.
    private var floorPicker: some View {
        ViewThatFits(in: .horizontal) {
            floorRow
            ScrollView(.horizontal, showsIndicators: false) {
                floorRow
            }
        }
    }

    private var floorRow: some View {
        HStack(spacing: 2) {
            // Own key, ✗ the Orders filter's "All": fr/es need the gender of "floor"
            // (Tous / Todas vs Toutes / Todos). English shows "All" (`source` in translations.json).
            ViewerSegment(title: String(localized: "All floors"), selected: floor == nil, action: {
                floor = nil
            }) {
                EmptyView()
            }
            ForEach(0..<floorCount, id: \.self) { index in
                ViewerSegment(title: String(localized: "Floor \(index + 1)"), selected: floor == index, action: {
                    floor = index
                }) {
                    EmptyView()
                }
            }
        }
        .padding(3)
        .fogGlass(Capsule())
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
        // Off main too (non-isolated async, SE-0338). nil = no floor buttons, not straightened.
        let found = await MeshLayout.analyse(decoded)
        let built = MeshPreviewView.makeScene(decoded)
        // Copies: `greyMaterial` is shared with the after-scan viewer, which has no clipping.
        let clip = FloorClip.prepare(built.scene.rootNode, copying: true)
        // Same centre as `makeScene`, which shifts the mesh node by −centre.
        let centre = (decoded.boundsMin + decoded.boundsMax) * 0.5
        layout = found
        // `makeScene` dời mô hình về gốc toạ độ nên tâm quay đúng bằng zero.
        grey = LoadedModel(
            scene: built.scene,
            camera: built.camera,
            center: SCNVector3Zero,
            worldOffset: -centre,
            clipMaterials: clip,
            boundsLayout: MeshLayout(boundsMin: decoded.boundsMin, boundsMax: decoded.boundsMax)
        )
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
    /// Scene coordinates = ARKit world + this. Grey: −bbox centre (`makeScene` shifts the mesh
    /// node). Textured: zero — the workstation OBJ keeps the ARKit frame (#LS-MTR8E4ZI5: same
    /// min Y −5.709 and Z range as the raw OBJ) and `export_usdz.py` exports −Z forward, Y up,
    /// metres. Floors and Top view are kept in ARKit world, so both models agree.
    let worldOffset: SIMD3<Float>
    /// Every material carrying the floor clip (`FloorClip`).
    let clipMaterials: [SCNMaterial]
    /// Footprint of this model alone: used when there is no grey `MeshLayout`.
    let boundsLayout: MeshLayout
    /// Opening camera: tapping Dollhouse goes back to it.
    let openTransform: simd_float4x4
    let openFieldOfView: CGFloat
    let openZFar: Double

    init(scene: SCNScene, camera: SCNNode, center: SCNVector3, worldOffset: SIMD3<Float>,
         clipMaterials: [SCNMaterial], boundsLayout: MeshLayout) {
        self.scene = scene
        self.camera = camera
        self.center = center
        self.worldOffset = worldOffset
        self.clipMaterials = clipMaterials
        self.boundsLayout = boundsLayout
        openTransform = camera.simdTransform
        openFieldOfView = camera.camera?.fieldOfView ?? 55
        openZFar = camera.camera?.zFar ?? 1000
    }

    /// Clip band in ARKit world Y → scene Y.
    func setClip(_ band: (lo: Float, hi: Float)) {
        for material in clipMaterials {
            FloorClip.set(material, lo: band.lo + worldOffset.y, hi: band.hi + worldOffset.y)
        }
    }
}

/// The view switch. 🔴 The owner keeps or drops modes: membership + order = `offered`, ONE line.
/// 30/09: mockup 73 had 3 modes; the owner dropped the flat Floor plan (orthographic) before
/// any build ("bỏ chế độ floorplan đi") ⇒ Dollhouse + Top view (perspective, with depth).
enum ViewerMode: Hashable {
    case dollhouse
    case topView

    static let offered: [ViewerMode] = [.dollhouse, .topView]

    var title: String {
        switch self {
        case .dollhouse: return String(localized: "Dollhouse")
        case .topView: return String(localized: "Top view")
        }
    }

    var caption: String {
        switch self {
        case .dollhouse: return String(localized: "Drag to rotate · pinch to zoom")
        case .topView: return String(localized: "Drag to move · pinch to zoom · twist to turn")
        }
    }
}

/// A tap on the view switch. `serial` grows on every tap, so tapping the mode already shown
/// re-frames it (Dollhouse = opening view, Top view = straightened fit).
struct FramingRequest: Equatable {
    let mode: ViewerMode
    let serial: Int
}

/// Floor buttons clip the model by world height. SceneKit has no clipping planes, so every
/// viewer material (grey + textured) carries this surface shader modifier; a floor tap only
/// changes two uniforms (no shader rebuild). `_surface.position` is view space; the inverse
/// view transform takes it to scene space. Device-only check: no Swift/Metal compiler here.
/// ✗ put it on `MeshPreviewView.greyMaterial` itself (shared with the after-scan viewer).
enum FloorClip {
    private static let loKey = "cedarClipLo"
    private static let hiKey = "cedarClipHi"
    private static let source = """
    #pragma arguments
    float cedarClipLo;
    float cedarClipHi;
    #pragma body
    float cedarY = (scn_frame.inverseViewTransform * float4(_surface.position, 1.0)).y;
    if (cedarY < cedarClipLo || cedarY > cedarClipHi) {
        discard_fragment();
    }
    """

    /// Installs the clip (band open) on every material under `root`. `copying`: give each
    /// geometry its own material copies first. Replaces any surface modifier (none today).
    static func prepare(_ root: SCNNode, copying: Bool) -> [SCNMaterial] {
        var out: [SCNMaterial] = []
        root.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry else { return }
            geometry.materials = geometry.materials.map { material in
                let own = copying ? ((material.copy() as? SCNMaterial) ?? material) : material
                var modifiers = own.shaderModifiers ?? [:]
                modifiers[.surface] = source
                own.shaderModifiers = modifiers
                // Unset uniforms read 0 ⇒ band [0, 0] ⇒ everything discarded. Open it now.
                set(own, lo: -MeshLayout.openEnd, hi: MeshLayout.openEnd)
                out.append(own)
                return own
            }
        }
        return out
    }

    static func set(_ material: SCNMaterial, lo: Float, hi: Float) {
        material.setValue(NSNumber(value: lo), forKey: loKey)
        material.setValue(NSNumber(value: hi), forKey: hiKey)
    }
}

/// One segment of the glass capsules (mockup 73: 36 pt high, white fill when selected).
private struct ViewerSegment<Icon: View>: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    let icon: Icon

    init(title: String, selected: Bool, action: @escaping () -> Void, @ViewBuilder icon: () -> Icon) {
        self.title = title
        self.selected = selected
        self.action = action
        self.icon = icon()
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                icon
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    // Long languages shrink before they truncate.
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(selected ? Color(red: 17 / 255, green: 24 / 255, blue: 39 / 255) : Color.white.opacity(0.86))
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background {
                if selected {
                    Capsule().fill(Color.white)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// Mockup 73 icons: cube (SF Symbol) · box seen from above (drawn: no SF Symbol matches).
private struct ViewerModeIcon: View {
    let mode: ViewerMode

    var body: some View {
        switch mode {
        case .dollhouse:
            Image(systemName: "cube")
                .font(.system(size: 15, weight: .medium))
                .accessibilityHidden(true)
        case .topView:
            // Mockup SVG on a 24-unit grid: square 7…17, corners joined to 3 / 21.
            Path { path in
                let s: CGFloat = 16.0 / 24.0
                path.addRect(CGRect(x: 7 * s, y: 7 * s, width: 10 * s, height: 10 * s))
                path.move(to: CGPoint(x: 3 * s, y: 3 * s))
                path.addLine(to: CGPoint(x: 7 * s, y: 7 * s))
                path.move(to: CGPoint(x: 21 * s, y: 3 * s))
                path.addLine(to: CGPoint(x: 17 * s, y: 7 * s))
                path.move(to: CGPoint(x: 3 * s, y: 21 * s))
                path.addLine(to: CGPoint(x: 7 * s, y: 17 * s))
                path.move(to: CGPoint(x: 21 * s, y: 21 * s))
                path.addLine(to: CGPoint(x: 17 * s, y: 17 * s))
            }
            .stroke(style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
        }
    }
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

        // Floor clip on the same materials (fresh from this file, no copy needed).
        let clip = FloorClip.prepare(scene.rootNode, copying: false)

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
            center: SCNVector3(center.x, center.y, center.z),
            worldOffset: .zero,
            clipMaterials: clip,
            boundsLayout: MeshLayout(boundsMin: bounds.lo, boundsMax: bounds.hi)
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

/// Vỏ `SCNView` dùng chung cho CẢ HAI chế độ (xám / texture) và cả hai kiểu xem.
/// Dollhouse = bộ điều khiển camera có sẵn của SceneKit (orbit). Top view = cử chỉ RIÊNG
/// (pan / pinch / twist) vì bộ có sẵn luôn cho nghiêng camera; lúc đó `allowsCameraControl`
/// tắt và ba recognizer của `Coordinator` bật, ✗ cả hai cùng lúc.
///
/// 🔴 Khác `MeshSceneView` (bản chỉ-xám) đúng một điểm và đó là lý do nó tồn tại: `updateUIView`
/// ở đây **CÓ** đổi cảnh, vì gạt công tắc Texture là một lần đổi cảnh THẬT. Nhưng chỉ đổi khi cảnh
/// KHÁC ĐI (`!==`) — gán lại `scene` ở mọi lượt cập nhật của SwiftUI là bắn camera về góc mặc
/// định đúng lúc khách đang xoay dở. Same rule for the camera: it moves only on a new scene, a
/// view-switch tap (`FramingRequest.serial`) or a floor change, never on a plain SwiftUI update.
private struct ModelSceneView: UIViewRepresentable {
    let model: LoadedModel
    let layout: MeshLayout
    let floor: Int?
    let framing: FramingRequest

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
        context.coordinator.attach(to: view)
        apply(to: view, context.coordinator)
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        apply(to: uiView, context.coordinator)
    }

    private func apply(to view: SCNView, _ coordinator: Coordinator) {
        coordinator.layout = layout
        let floorChanged = !coordinator.applied || coordinator.floor != floor
        coordinator.floor = floor
        let sceneChanged = coordinator.shown !== model.scene

        if sceneChanged {
            // MANG GÓC NHÌN SANG CẢNH MỚI. Gạt công tắc mà mô hình nhảy về góc mặc định thì khách
            // mất chỗ đang xem — mà cả lý do tồn tại của công tắc là "vẫn cái nhà đó, bật/tắt lớp
            // ảnh". Hai cảnh KHÔNG cùng tâm nên phải chuyển vị trí camera theo hiệu so với tâm, ✗
            // chép thẳng transform. (Dollhouse only: Top view keeps its own state in ARKit world
            // and is re-placed below.)
            if coordinator.shown != nil, coordinator.mode == .dollhouse, let old = view.pointOfView {
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
            coordinator.model = model
        }

        if framing.serial != coordinator.serial {
            // A view-switch tap, or the first apply of this view (serial starts at Int.min).
            coordinator.serial = framing.serial
            coordinator.mode = framing.mode
            coordinator.frame(view)
        } else if coordinator.mode == .topView, sceneChanged || floorChanged {
            // Texture flipped or floor changed in Top view: same spot, same zoom, same turn; a
            // floor change moves the camera with the floor (height kept above the new floor).
            if floorChanged {
                coordinator.top.baseY = layout.topBase(floor)
            }
            coordinator.placeTopCamera(view)
        }

        if sceneChanged || floorChanged {
            model.setClip(layout.band(floor))
            coordinator.kickRedraw(view)
        }
        coordinator.applied = true
        coordinator.syncControls(view)
    }

    /// Top view camera, kept in ARKit WORLD (so it survives the Texture switch): looks straight
    /// down from `height` above the plane `baseY`, `target` = world (x, z) under the screen
    /// centre on that plane, `yaw` = turn about the vertical.
    struct TopCamera {
        var target = SIMD2<Float>(0, 0)
        var baseY: Float = 0
        var height: Float = 10
        var yaw: Float = 0
        var maxHeight: Float = 30
        /// Footprint diagonal, for `zFar`.
        var reach: Float = 10
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var shown: SCNScene?
        var center = SCNVector3Zero
        var model: LoadedModel?
        var layout: MeshLayout?
        var floor: Int?
        var applied = false
        var serial = Int.min
        var mode: ViewerMode = .dollhouse
        var top = TopCamera()
        private weak var view: SCNView?
        private var recognizers: [UIGestureRecognizer] = []
        private var redrawSerial = 0

        /// Same 55° HORIZONTAL field of view as the Dollhouse opening (`projectionDirection`
        /// stays `.horizontal`, set by both scene builders).
        private static let fovDegrees: Float = 55
        private static var halfFov: Float { fovDegrees * .pi / 360 }
        /// Closest the camera gets to the floor it looks at.
        private static let minHeight: Float = 1.5

        func attach(to view: SCNView) {
            self.view = view
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            let twist = UIRotationGestureRecognizer(target: self, action: #selector(handleTwist(_:)))
            recognizers = [pan, pinch, twist]
            for recognizer in recognizers {
                recognizer.delegate = self
                recognizer.isEnabled = false
                view.addGestureRecognizer(recognizer)
            }
        }

        /// Dollhouse: SceneKit's controller only. Top view: ours only (theirs would tilt).
        func syncControls(_ view: SCNView) {
            let dollhouse = mode == .dollhouse
            if view.allowsCameraControl != dollhouse {
                view.allowsCameraControl = dollhouse
            }
            for recognizer in recognizers where recognizer.isEnabled == dollhouse {
                recognizer.isEnabled = !dollhouse
            }
        }

        /// SceneKit may not redraw for a uniform change alone (no node moved): render
        /// continuously for a moment instead of hoping.
        func kickRedraw(_ view: SCNView) {
            redrawSerial += 1
            let mine = redrawSerial
            view.rendersContinuously = true
            Task { @MainActor [weak self, weak view] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, let view, self.redrawSerial == mine else { return }
                view.rendersContinuously = false
            }
        }

        // MARK: Framing

        func frame(_ view: SCNView) {
            guard let model else { return }
            view.defaultCameraController.stopInertia()
            switch mode {
            case .dollhouse:
                // Back to the opening view (today's default camera).
                model.camera.simdTransform = model.openTransform
                model.camera.camera?.fieldOfView = model.openFieldOfView
                model.camera.camera?.zFar = model.openZFar
                view.pointOfView = model.camera
                view.defaultCameraController.target = model.center
            case .topView:
                frameTop(view)
            }
            kickRedraw(view)
        }

        /// Straight down, straightened along the main walls, whole footprint in view with the
        /// wall tops (mockup 73 B: fit × 1.12 + 2.8 m). Of the four straight headings, the one
        /// nearest the current heading, so the house does not spin when the mode changes.
        private func frameTop(_ view: SCNView) {
            guard let layout else { return }
            let front = view.pointOfView?.simdWorldFront ?? SIMD3<Float>(0, 0, -1)
            let flat = SIMD2<Float>(front.x, front.z)
            // Screen-up on the ground = (−sin yaw, −cos yaw) ⇒ yaw = atan2(−x, −z). Already
            // looking down (a Top view re-tap): keep the current turn.
            let heading = simd_length(flat) > 0.2 ? atan2(-front.x, -front.z) : top.yaw
            let theta = layout.wallAngle
            var yaw = Self.wrap(-theta)
            var quarter = 0
            var bestDiff = Float.greatestFiniteMagnitude
            for q in 0..<4 {
                let candidate = Self.wrap(-theta - Float(q) * .pi / 2)
                let diff = abs(Self.wrap(candidate - heading))
                if diff < bestDiff {
                    bestDiff = diff
                    yaw = candidate
                    quarter = q
                }
            }
            // Screen-right = the wall axis r turned by `quarter` × 90°: odd ⇒ width is `across`.
            let alongSpan = layout.along.upperBound - layout.along.lowerBound
            let acrossSpan = layout.across.upperBound - layout.across.lowerBound
            let width = quarter % 2 == 0 ? alongSpan : acrossSpan
            let depth = quarter % 2 == 0 ? acrossSpan : alongSpan
            let r = SIMD2<Float>(cos(theta), sin(theta))
            let f = SIMD2<Float>(-sin(theta), cos(theta))
            let alongMid = (layout.along.lowerBound + layout.along.upperBound) / 2
            let acrossMid = (layout.across.lowerBound + layout.across.upperBound) / 2
            let centre = r * alongMid + f * acrossMid
            let size = view.bounds.size
            // Before the first layout the view is 0×0: a portrait phone's shape.
            let aspect: Float = size.width > 1 && size.height > 1 ? Float(size.width / size.height) : 390.0 / 844.0
            let halfWidth = max(max(width / 2, depth / 2 * aspect) * 1.06, 1)
            let height = halfWidth / tan(Self.halfFov) * 1.12 + 2.8
            top = TopCamera(
                target: centre,
                baseY: layout.topBase(floor),
                height: height,
                yaw: yaw,
                maxHeight: max(height * 3, 10),
                reach: (alongSpan * alongSpan + acrossSpan * acrossSpan).squareRoot()
            )
            placeTopCamera(view)
        }

        func placeTopCamera(_ view: SCNView) {
            guard let model, let camera = model.camera.camera else { return }
            guard top.target.x.isFinite, top.target.y.isFinite, top.baseY.isFinite,
                  top.height.isFinite, top.yaw.isFinite
            else { return }
            let o = model.worldOffset
            model.camera.simdPosition = SIMD3<Float>(
                top.target.x + o.x,
                top.baseY + top.height + o.y,
                top.target.y + o.z
            )
            // Look down (−Z → −Y, screen-up → −Z), then turn about the vertical.
            model.camera.simdOrientation = simd_quatf(angle: top.yaw, axis: SIMD3<Float>(0, 1, 0))
                * simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))
            camera.fieldOfView = CGFloat(Self.fovDegrees)
            camera.zFar = max(model.openZFar, Double(top.maxHeight + top.reach + 20))
            if view.pointOfView !== model.camera {
                view.pointOfView = model.camera
            }
        }

        // MARK: Top view gestures (pan / pinch / twist, together like Maps)

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            recognizers.contains(gestureRecognizer) && recognizers.contains(other)
        }

        /// Metres per screen point on the base plane (horizontal FOV spans the view width).
        private func metresPerPoint(_ view: SCNView) -> Float {
            2 * top.height * tan(Self.halfFov) / Float(max(view.bounds.width, 1))
        }

        /// World (x, z) directions of screen-right and screen-up.
        private var screenRight: SIMD2<Float> { SIMD2<Float>(cos(top.yaw), -sin(top.yaw)) }
        private var screenUp: SIMD2<Float> { SIMD2<Float>(-sin(top.yaw), -cos(top.yaw)) }

        /// World (x, z) on the base plane under a point of the view.
        private func groundPoint(_ point: CGPoint, in view: SCNView) -> SIMD2<Float> {
            let k = metresPerPoint(view)
            let dx = Float(point.x - view.bounds.midX)
            let dy = Float(point.y - view.bounds.midY)
            return top.target + screenRight * (dx * k) - screenUp * (dy * k)
        }

        @objc private func handlePan(_ g: UIPanGestureRecognizer) {
            guard mode == .topView, let view, g.state == .began || g.state == .changed else { return }
            let t = g.translation(in: view)
            g.setTranslation(.zero, in: view)
            let k = metresPerPoint(view)
            // The ground follows the finger: the camera moves the other way.
            top.target += screenRight * (-Float(t.x) * k) + screenUp * (Float(t.y) * k)
            placeTopCamera(view)
        }

        @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
            guard mode == .topView, let view, g.state == .began || g.state == .changed else { return }
            let scale = Float(g.scale)
            g.scale = 1
            guard scale.isFinite, scale > 0.01 else { return }
            // Zoom about the fingers: the ground point between them stays under them.
            let anchor = groundPoint(g.location(in: view), in: view)
            let newHeight = min(max(top.height / scale, Self.minHeight), top.maxHeight)
            top.target = anchor + (top.target - anchor) * (newHeight / top.height)
            top.height = newHeight
            placeTopCamera(view)
        }

        @objc private func handleTwist(_ g: UIRotationGestureRecognizer) {
            guard mode == .topView, let view, g.state == .began || g.state == .changed else { return }
            // UIKit: positive = clockwise on screen. Turning the camera by +a about the fingers'
            // ground point turns the house clockwise by a.
            let a = Float(g.rotation)
            g.rotation = 0
            guard a.isFinite else { return }
            let anchor = groundPoint(g.location(in: view), in: view)
            let d = top.target - anchor
            top.target = anchor + SIMD2<Float>(d.x * cos(a) + d.y * sin(a), -d.x * sin(a) + d.y * cos(a))
            top.yaw = Self.wrap(top.yaw + a)
            placeTopCamera(view)
        }

        /// Angle into (−π, π].
        private static func wrap(_ angle: Float) -> Float {
            var a = angle.truncatingRemainder(dividingBy: 2 * .pi)
            if a > .pi { a -= 2 * .pi }
            if a <= -.pi { a += 2 * .pi }
            return a
        }
    }
}
