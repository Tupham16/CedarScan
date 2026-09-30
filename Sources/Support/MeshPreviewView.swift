import SwiftUI
import SceneKit
import UIKit
import simd

/// Plain GREY 3D viewer for a saved scan — rotate + pinch-zoom, no texture, no AR.
/// This is the "xem mesh đen trắng" the owner asked for on 2026-08-10, the same thing
/// 3D Scanner App shows after a scan. Two placements, both feeding this one view:
///  1. `ScanPreviewView` — the screen right after Stop & Save, next to the video;
///  2. `ScanDetailView.meshTab` — the saved-scan page, openable any time.
///
/// It reads ONLY `mesh-preview.bin` (see `MeshPreviewFile` for why a purpose-built file has to
/// exist at all: the app has no zip reader, and the real `model.obj` lives inside
/// `model-colored.zip`). Scans saved BEFORE build 1.4 have no such file — both call sites
/// check `fileExists` and simply do not offer the button. That is deliberate: there is no way
/// to rebuild the preview for an old scan on-device, so a visible-but-broken entry point would
/// be worse than no entry point.
///
/// Cost: ~2–6MB read once, ~10–15MB of SceneKit buffers, geometry built with zero conversion
/// (the file's float blocks are packed exactly as `SCNGeometrySource` wants them).
struct MeshPreviewView: View {
    let url: URL

    /// Built once in `.task` and never swapped — see `MeshSceneView.updateUIView`.
    @State private var scene: SCNScene?
    @State private var cameraNode: SCNNode?
    @State private var failed = false

    /// Dark backdrop on purpose, in BOTH app themes: the mesh itself is light grey, so a
    /// system background would put light grey on near-white in light mode and the shape would
    /// disappear. Every 3D viewer (3DSA included) does the same.
    static let backdropColor = UIColor(white: 0.11, alpha: 1)

    /// 🔴 **CHIỀU CULL DÙNG CHUNG CỦA CẢ HAI TRÌNH XEM 3D** — lưới xám ở file này và mô hình có
    /// texture ở `ModelViewer.swift`. Lập luận vì sao là `.back` nằm nguyên ở `greyMaterial` bên
    /// dưới; nó áp cho cả hai vì hai bên đọc CÙNG một hình học (mesh của app → OBJ giao → máy
    /// trạm bake ra usdz), tức cùng một chiều winding.
    /// ✅ **`.back` ĐÃ ĐƯỢC XÁC NHẬN TRÊN MÁY THẬT 10/08 (bản 2.0) — chủ app: "ĐÃ CULLING RỒI".**
    /// Ông trả lời sau khi vừa gạt công tắc Texture qua lại nên đây là quan sát trên CẢ HAI chế
    /// độ (ông không tách riêng từng chế độ, nhưng cả hai đọc chính hằng số này).
    /// 🔴 **Vì vậy CHUỖI SUY LUẬN WINDING ở `greyMaterial` bên dưới cũng ĐÚNG** — pháp tuyến
    /// ARKit hướng VÀO phòng, winding CCW-quanh-pháp-tuyến (bằng chứng gián tiếp từ
    /// `texbake/bake.py`) ⇒ vỏ ngoài của một bản quét nội thất toàn là mặt SAU. Đó không còn là
    /// giả thuyết. ✗ lật `.back` → `.front` "cho chắc".
    static let sharedCullMode: SCNCullMode = .back

    var body: some View {
        ZStack {
            Color(uiColor: Self.backdropColor)

            if let scene, let cameraNode {
                MeshSceneView(scene: scene, cameraNode: cameraNode)
                VStack {
                    Spacer()
                    Text(String(localized: "Drag to rotate · pinch to zoom"))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.bottom, 8)
                    // The caption must never eat a drag meant for the model.
                    .allowsHitTesting(false)
                }
            } else if failed {
                VStack(spacing: 10) {
                    Image(systemName: "cube.transparent")
                        .font(.largeTitle)
                        .foregroundStyle(.white.opacity(0.5))
                    Text(String(localized: "Couldn't open the 3D model for this scan."))
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                }
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        // Plain `.task` with an idempotent guard, NOT `.task(id:)`: SwiftUI cancels this at
        // onDisappear and runs it again on re-appear (bẫy §Vòng đời SwiftUI note on `.task`),
        // and rebuilding the scene would throw away whatever angle the customer had rotated to.
        .task {
            guard scene == nil, !failed else { return }
            // `MeshPreviewFile.read` is a non-isolated async func, so per SE-0338 the file read
            // + index validation run on the cooperative pool, not on main. Only the cheap part
            // (wrapping Data in SCNGeometrySource — no copy) happens back here.
            guard let decoded = await MeshPreviewFile.read(url) else {
                failed = true
                return
            }
            let built = Self.makeScene(decoded)
            scene = built.scene
            cameraNode = built.camera
        }
    }

    // MARK: - Scene construction

    /// Shared, immutable — SceneKit is happy to reuse one material across scenes.
    /// `.blinn` + a light grey diffuse is the "clay render" look.
    ///
    /// 🔴 **BACK-FACE CULLING IS ON BY REQUEST** (chủ app, 2026-08-10). Looking at the house
    /// from outside now shows the INSIDE of the rooms — a dollhouse — instead of an opaque
    /// block.
    /// 🔴 WHY IT OPENS THE ROOF — and mind the two steps, they are easy to collapse into one
    /// wrong sentence: the GPU decides front/back from **WINDING**, ✗ from the normal source
    /// (the `.normal` `SCNGeometrySource` below is read only by the shader). So the argument
    /// is (1) ARKit's normals point INTO the rooms — that is what `ColorMeshBuilder.sampleColor`
    /// rides on, it only takes a keyframe when `dot(normal, toCamera) > minFacing` and the
    /// camera walks INSIDE; plus (2) the winding is CCW-about-normal — evidence OUTSIDE this
    /// repo: `C:/Block/texbake/bake.py` derives face normals from winding alone
    /// (`np.cross(v1-v0, v2-v0)`) and hard-gates on `cosang > 0.2`, and the delivery OBJ ships
    /// no `vn` at all, so if the winding were CW the baker would output a 100% grey model —
    /// it outputs 0.0–0.4% grey on real houses, for weeks. (1)+(2) ⇒ the outer skin of an
    /// interior scan is entirely BACK faces.
    /// `cullMode = .back` is already SceneKit's default; it is written out so that a later
    /// edit cannot flip it silently.
    /// · ✅ **CONFIRMED ON A REAL DEVICE 10/08 (build 2.0) — the owner replied "ĐÃ CULLING RỒI".**
    ///   So step (2) holds and the delivery OBJ's winding IS what the baker assumes. The
    ///   `.back` → `.front` escape hatch below is kept as the record, ✗ as a pending question.
    /// · ✗ copy this to the three `isDoubleSided = true` in `Scan/MeshOverlayView.swift`. Those
    ///   are the LIVE scan overlay: two `fillMode = .lines` wireframes (culling would drop the
    ///   back-facing lines of every wireframe) and the depth mask that punches holes in the red
    ///   unscanned-area tint (culling it leaves red bleeding over scanned areas). §Lưới + phủ đỏ.
    /// · 🔴 KNOWN COST, ACCEPTED — MEASURED 30/09 on five owner houses (1.55M / 1.10M / 0.46M /
    ///   1.72M / 1.80M vertices; harness `tools/preview-harness/`: Blender, this camera, culling
    ///   on; metric = see-through area inside the full mesh's silhouette, in points ABOVE what the
    ///   full culled mesh itself shows, top view / mean of four 30° views):
    ///   · up to 2.74, voxel clustering (`ColorMeshBuilder.clusterPreview`): the spacing guess
    ///     was 2× too big, so houses landed at 37–40k vertices, voxel 10–19cm — past a 7–12cm
    ///     partition, whose two faces then welded into ONE sheet carrying triangles of BOTH
    ///     windings (~15% of faces on the big houses, 2–3% flipped). Culling dropped one
    ///     winding ⇒ torn walls, blocky holes: +4.5/+3.0 · +4.1/+3.4 · +2.4/+1.9 · +5.5/+3.9 ·
    ///     +4.4/+3.6 points.
    ///   · from 2.75, quadric edge collapse (`PreviewSimplifier`) at 108–119k vertices: an edge
    ///     collapse never merges the two faces of a wall, flips are refused:
    ///     +0.6/+0.4 · +0.4/+0.3 · +0.1/+0.0 · +0.8/+0.5 · +0.9/+0.5 points.
    ///   What is left is REAL: the full mesh itself shows 4–8% see-through from the top (never
    ///   measured by the LiDAR: under / behind furniture, wall bases, stairwell — same holes in
    ///   model.obj) ⇒ a hole report on a 2.75+ scan is first a scanning question, ✗ this viewer.
    ///   Shading: the file's normals are smooth, so a big flat wall triangle whose corners sit
    ///   on creases shades as a soft diagonal light/dark band — cosmetic, ✗ a hole. Still fewer
    ///   bad normals than before (area where a corner normal faces away from its triangle: ~14%
    ///   → ~3% on the big houses). If the owner dislikes the bands, faceted shading is a viewer
    ///   change (an owner conversation), ✗ a reason to go back to clustering.
    ///   Clustering still runs as the FALLBACK (spacing guess fixed to 3cm ⇒ ~100k vertices);
    ///   a fallback preview shows the old torn walls again, so "torn walls on a new scan" = the
    ///   simplifier failed on that scan, look there first.
    ///   Old scans keep their old preview: `mesh-preview.bin` cannot be rebuilt on-device.
    ///   ✗ the "re-orient each triangle to match its own normals" idea for welded walls: the two
    ///   sides' normals point OPPOSITE ways, so it is a no-op for exactly that failure.
    ///   ✗ raise `previewVertexBudget` — 🔴 he personally chose "Nhẹ — 120k đỉnh".
    private static let greyMaterial: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel = .blinn
        m.diffuse.contents = UIColor(white: 0.78, alpha: 1)
        m.specular.contents = UIColor(white: 0.18, alpha: 1)
        m.shininess = 0.15
        m.isDoubleSided = false
        m.cullMode = MeshPreviewView.sharedCullMode
        return m
    }()

    /// ⚠ INTERNAL, ✗ private: `ModelViewerScreen` (trình xem gộp xám+texture ở
    /// `ModelViewer.swift`) gọi CHÍNH hàm này cho nhánh xám của nó. Chép một bản thứ hai là đẻ
    /// ra hai bố cục lệch nhau ngay lần đầu ai đó chỉnh góc mở — đúng thứ repo này đã trả giá.
    static func makeScene(
        _ decoded: MeshPreviewFile.Decoded
    ) -> (scene: SCNScene, camera: SCNNode) {
        // Zero-copy: both sources point INTO the file bytes at their own offset/stride.
        let positions = SCNGeometrySource(
            data: decoded.raw,
            semantic: .vertex,
            vectorCount: decoded.vertexCount,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: decoded.positionOffset,
            dataStride: 12
        )
        let normals = SCNGeometrySource(
            data: decoded.raw,
            semantic: .normal,
            vectorCount: decoded.vertexCount,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: decoded.normalOffset,
            dataStride: 12
        )
        let element = SCNGeometryElement(
            data: decoded.indexData,
            primitiveType: .triangles,
            primitiveCount: decoded.triangleCount,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )
        let geometry = SCNGeometry(sources: [positions, normals], elements: [element])
        geometry.materials = [greyMaterial]

        let scene = SCNScene()

        // The mesh sits in ARKit WORLD coordinates (origin = wherever the scan started), so it
        // can be tens of metres off-centre. Shift the node so the model's centre is at the
        // origin: `orbitTurntable` then spins around the model instead of around a point off
        // in the corner of the house, whether SceneKit uses our explicit target or its own
        // automatic one.
        let center = (decoded.boundsMin + decoded.boundsMax) * 0.5
        let radius = max(simd_length(decoded.boundsMax - decoded.boundsMin) * 0.5, 0.5)
        let meshNode = SCNNode(geometry: geometry)
        meshNode.position = SCNVector3(-center.x, -center.y, -center.z)
        scene.rootNode.addChildNode(meshNode)

        // Framing: put the camera far enough that a sphere of `radius` (half the bbox
        // DIAGONAL, so it contains the whole model whatever its shape) fits, with margin.
        // Over-framing is free — the customer can pinch in — while under-framing clips the
        // house on first sight.
        //
        // 🔴 `projectionDirection = .horizontal` IS LOAD-BEARING, ✗ delete it. `fieldOfView`
        // binds to the VERTICAL axis by default, and this app is portrait-only
        // (`UISupportedInterfaceOrientations` in project.yml), so the horizontal FOV is the
        // TIGHTER one — 55° vertical on a 393×852 screen is only ~27° horizontal, which crops
        // ~10% off each end of a normal house even with the 1.5× margin below. Binding the 55°
        // to the horizontal axis makes the margin apply to the axis that actually clips.
        // (Found by adversarial review before the first build; the maths is
        // half-width = distance × tan(halfFov) ≈ 1.5·radius > radius.)
        let fovDegrees: Float = 55
        let halfFov = fovDegrees * .pi / 360
        let distance = radius / tan(halfFov) * 1.5
        // Opening angle: 30° ABOVE the horizon, looking down into the rooms. With back-face
        // culling on, the roof is gone, so the dollhouse only reads from above; the previous
        // `height = radius * 0.45` put the camera at only ~8.9° (atan2(0.45, 2.8815)), i.e.
        // almost eye level, where you see a wall of grey and no floor plan.
        // 🔴 The camera stays on a sphere of radius exactly `distance` (sin² + cos² = 1), so
        // the framing guarantee computed above still holds at any elevation — ✗ "simplify"
        // this into `SCNVector3(0, someHeight, distance)`, that moves the camera FURTHER out
        // than `distance` and re-opens the under/over-framing question.
        let elevation: Float = 30 * .pi / 180

        let camera = SCNCamera()
        camera.fieldOfView = CGFloat(fovDegrees)
        camera.projectionDirection = .horizontal
        camera.zNear = Double(max(0.05, radius * 0.01))
        camera.zFar = Double(distance + radius * 6 + 10)
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, distance * sin(elevation), distance * cos(elevation))
        // Default SceneKit cameras look down −Z; pitching by −elevation about X aims the
        // camera back at the origin, which `makeScene` has already made the model's centre.
        cameraNode.eulerAngles = SCNVector3(-elevation, 0, 0)

        // Key light is a CHILD OF THE CAMERA but rotated away from the view axis. A pure
        // headlight lights every visible face equally and flattens a grey mesh into a
        // silhouette; the offset keeps walls, floors and ceilings at different brightness so
        // rooms read as rooms.
        let keyLight = SCNLight()
        keyLight.type = .directional
        keyLight.color = UIColor(white: 1, alpha: 1)
        keyLight.intensity = 900
        let keyNode = SCNNode()
        keyNode.light = keyLight
        keyNode.eulerAngles = SCNVector3(-0.55, 0.6, 0)
        cameraNode.addChildNode(keyNode)

        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.color = UIColor(white: 1, alpha: 1)
        ambientLight.intensity = 380
        let ambientNode = SCNNode()
        ambientNode.light = ambientLight
        scene.rootNode.addChildNode(ambientNode)

        // 🔴 The camera node MUST live in the scene graph, not just be handed to
        // `SCNView.pointOfView`: SceneKit only renders lights that are inside the graph, and
        // the key light above is its child. (Same family of trap as the red tint quad in
        // `MeshOverlayRenderer` — a node outside `rootNode` silently does nothing.)
        scene.rootNode.addChildNode(cameraNode)

        return (scene, cameraNode)
    }
}

// `GreyMeshViewerScreen` ĐÃ XOÁ ở bản 2.0. Nó là bản bọc toàn màn hình CHỈ-XÁM cho
// `ScanDetailView`, mà màn đó nay dùng **một trình xem gộp** (`ModelViewerScreen` trong
// `ModelViewer.swift`): một nút "Xem mô hình 3D" + công tắc Texture ở góc. Trình xem gộp với
// `texturedRemote: nil` LÀ trình xem chỉ-xám, nên dựng lại kiểu cũ là quay về hai màn song sinh.
// `MeshPreviewView` ở trên thì GIỮ — `ScanPreviewView` (màn ngay sau khi quét) nhúng nó thẳng vào
// một picker Video/Mô hình 3D, không qua bản bọc nào.

/// Thin `SCNView` host. All interaction is SceneKit's own camera controller — no custom
/// gesture code to fight with SwiftUI.
private struct MeshSceneView: UIViewRepresentable {
    let scene: SCNScene
    let cameraNode: SCNNode

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = scene
        view.pointOfView = cameraNode
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        // Model is centred at the origin (see `makeScene`), so this is the model's middle.
        view.defaultCameraController.target = SCNVector3Zero
        view.defaultCameraController.inertiaEnabled = true
        // Explicit lights (see `makeScene`); the default headlight would wash them out.
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling2X
        view.backgroundColor = MeshPreviewView.backdropColor
        view.preferredFramesPerSecond = 60
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        // Deliberately empty. `scene`/`cameraNode` are built once and never replaced, and
        // re-assigning `uiView.scene` on every SwiftUI update would snap the camera back to
        // the default angle while the customer is mid-rotation.
    }
}
