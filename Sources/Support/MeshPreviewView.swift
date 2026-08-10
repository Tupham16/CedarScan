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
    /// texture ở `TexturedModelView`. Lập luận vì sao là `.back` nằm nguyên ở `greyMaterial` bên
    /// dưới; nó áp cho cả hai vì hai bên đọc CÙNG một hình học (mesh của app → OBJ giao → máy
    /// trạm bake ra usdz), tức cùng một chiều winding.
    /// ⚠ **CHIỀU NÀY CHƯA ĐƯỢC XÁC NHẬN TRÊN MÁY THẬT.** Nếu nhìn từ ngoài mà KHÔNG xuyên được
    /// vào trong phòng (mô hình vẫn là khối đặc) thì chiều bị ngược: đổi ĐÚNG MỘT TỪ ở đây,
    /// `.back` → `.front`, và hai trình xem cùng đúng theo. Đó chính là lý do hằng số này tồn tại
    /// thay vì mỗi file viết một chữ.
    static let sharedCullMode: SCNCullMode = .back

    var body: some View {
        ZStack {
            Color(uiColor: Self.backdropColor)

            if let scene, let cameraNode {
                MeshSceneView(scene: scene, cameraNode: cameraNode)
                VStack {
                    Spacer()
                    Text(L.t(
                        "Drag to rotate · pinch to zoom",
                        "Kéo để xoay · chụm hai ngón để phóng to"
                    ))
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
                    Text(L.t(
                        "Couldn't open the 3D model for this scan.",
                        "Không mở được mô hình 3D của bản quét này."
                    ))
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
    /// · If the device shows NO change at all, step (2) is wrong and the fix is one word
    ///   (`.back` → `.front`) — but RECORD IT, because it would also mean the delivery OBJ's
    ///   winding is not what the baker assumes.
    /// · ✗ copy this to the three `isDoubleSided = true` in `Scan/MeshOverlayView.swift`. Those
    ///   are the LIVE scan overlay: two `fillMode = .lines` wireframes (culling would drop the
    ///   back-facing lines of every wireframe) and the depth mask that punches holes in the red
    ///   unscanned-area tint (culling it leaves red bleeding over scanned areas). §Lưới + phủ đỏ.
    /// · 🔴 KNOWN COST, ACCEPTED — and BIGGER than "a big house", so do not go hunting for a
    ///   new bug when it shows up. `ColorMeshBuilder.buildPreview` picks `voxel = 0.03` while
    ///   `totalVerts <= 120_000`, and `max(0.03, 0.05 · sqrt(totalVerts / 120_000))` above it.
    ///   Source verts → pass-1 voxel: 300k ⇒ ~8cm, 600k ⇒ ~11cm, 1M ⇒ ~14cm, and
    ///   `wholeHomePreset.maxVertices` = 2M — the ceiling a whole house is sized to fit under —
    ///   ⇒ ~20cm. Retries only ever COARSEN, by `max(1.35, sqrt(over))` PER RETRY: ONE retry —
    ///   which `exportPreviewMesh`'s doc calls the ordinary case — is ≥1.35× ⇒ ~27cm from 2M;
    ///   only the full four passes reach ≥1.35³ ≈ 2.5× ⇒ ~50cm. Those are FLOORS, ✗ caps —
    ///   `sqrt(over)` is unbounded and nothing clamps the voxel; the only ceiling in that loop
    ///   is `previewMaxPasses`.
    ///   A partition is 7–12cm thick, so on a whole-house scan the voxel is at or past it
    ///   ALREADY ON PASS 1, and the wall's two faces weld into ONE zero-thickness sheet
    ///   carrying triangles of BOTH windings (`clusterPreview` says the same thing at its
    ///   zero-normal fallback). Culling drops one winding ⇒ those partitions read as TORN,
    ///   ✗ as pinholes. `mesh-preview.bin` is a look-at file, ✗ a measurement source.
    ///   ⚠ Size the expectation from the ONE RECORDED MEASUREMENT, ✗ from a room count:
    ///   `MeshOverlayView`'s mask-ledger comment records a real 2-storey house at **~0.5–1.5M
    ///   anchor vertices** ⇒ pass-1 voxel ~10–18cm, straddling the partition band ⇒ EXPECT torn
    ///   partitions on a normal whole-house scan, ✗ treat it as a surprise. That figure is the
    ///   overlay's ledger, not `buildPreview`'s own `totalVerts`, so confirm it on the first
    ///   whole-house run; a one-room scan sits near the 3cm floor, looks clean, proves nothing.
    ///   Escape hatches, in cost order — ALL THREE ARE OWNER CONVERSATIONS, ✗ pick one alone:
    ///   (a) accept it; (b) `isDoubleSided = true` again and tell him the dollhouse costs torn
    ///   partitions; (c) raise `previewVertexBudget` — 🔴 he personally chose "Nhẹ — 120k đỉnh",
    ///   ✗ raise it without asking. ✗ the "re-orient each triangle to match its own normals"
    ///   idea: for a welded partition the two sides' normals point OPPOSITE ways, so it is a
    ///   no-op for exactly this failure, and it would read post-weld normals that may be the
    ///   invented `SIMD3(0,1,0)`. And any decimator change helps NEW scans only —
    ///   `mesh-preview.bin` cannot be rebuilt on-device.
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

    private static func makeScene(
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

/// Full-screen wrapper used by `ScanDetailView` (placement 2). Presented with
/// `.fullScreenCover(item:)`, so the only way out is this button — which is the point: a
/// `.sheet` would treat "drag down to look at the ceiling" as "dismiss me".
///
/// ✗ turn this into a `NavigationStack` with a `.toolbar` close button. The toolbar bar-item
/// host is exactly where the 06/08 crash lived (`UIKitBarItemHost` reading an
/// `@EnvironmentObject` before the environment bridge is connected). A plain overlaid button
/// has no bar-item host at all, and this screen needs nothing from the environment.
struct GreyMeshViewerScreen: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topLeading) {
            MeshPreviewView(url: url)
                .ignoresSafeArea()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    // Fixed dark chip, ✗ `.ultraThinMaterial`: the backdrop is always dark here
                    // regardless of the phone's light/dark setting, so a material would render
                    // near-white in light mode and swallow the white glyph.
                    .background(Color.black.opacity(0.45), in: Circle())
            }
            .padding(.leading, 16)
            .padding(.top, 12)
            .accessibilityLabel(L.t("Close", "Đóng"))
        }
    }
}

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
