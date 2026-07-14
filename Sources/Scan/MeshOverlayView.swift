import SwiftUI
import SceneKit
import ARKit

/// Lớp phủ LƯỚI LiDAR (wireframe) lên trên RoomCaptureView, canh theo camera AR theo thời
/// gian thực — để người quét biết bề mặt nào đã được quét (giống CubiCasa/Polycam).
///
/// Chỉ ĐỌC arSession.currentFrame (không đổi cấu hình, không đụng phiên RoomPlan) nên an toàn
/// với luồng quét. Nền trong suốt để thấy hình camera của RoomCaptureView bên dưới.
///
/// Canh camera: đặt transform + ma trận chiếu của camera SceneKit đúng bằng của ARKit mỗi
/// khung hình. App chỉ chạy dọc (portrait) nên dùng .portrait cho ma trận chiếu.
final class MeshOverlayView: SCNView {
    private weak var arSession: ARSession?
    private var displayLink: CADisplayLink?
    private let cameraNode = SCNNode()
    private struct MeshSig: Equatable { let v: Int; let f: Int }
    private var anchorNodes: [UUID: SCNNode] = [:]
    private var anchorSigs: [UUID: MeshSig] = [:]
    private var inFlight = Set<UUID>()           // anchor đang dựng dở ở nền → chống dồn hàng
    private var totalVerts = 0                    // tổng đỉnh đang hiển thị (để chặn trần)
    private static let maxVerts = 150_000         // trần như ColorMeshBuilder — chặn phình bộ nhớ/GPU
    private var lastMeshUpdate: TimeInterval = 0
    private static let meshUpdateInterval: TimeInterval = 0.5
    /// Dựng SCNGeometry ở luồng NỀN để không chiếm main thread (main chỉ memcpy nhanh).
    private let buildQueue = DispatchQueue(label: "com.cedar247.meshoverlay", qos: .utility)

    /// Vật liệu wireframe dùng CHUNG cho mọi node (khỏi cấp phát mới mỗi lần dựng lưới).
    private static let wireframeMaterial: SCNMaterial = {
        let m = SCNMaterial()
        m.fillMode = .lines                 // wireframe = "lưới"
        m.diffuse.contents = UIColor.systemGreen
        m.emission.contents = UIColor.systemGreen
        m.lightingModel = .constant          // không phụ thuộc đèn, luôn rõ
        m.isDoubleSided = true
        m.writesToDepthBuffer = false        // tránh tự che khuất khó nhìn
        return m
    }()

    init(arSession: ARSession) {
        self.arSession = arSession
        super.init(frame: .zero, options: nil)
        scene = SCNScene()
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false   // để chạm đi xuyên xuống RoomCaptureView
        rendersContinuously = true
        antialiasingMode = .none            // giảm tải GPU khi chạy cùng RoomPlan
        cameraNode.camera = SCNCamera()
        scene?.rootNode.addChildNode(cameraNode)
        pointOfView = cameraNode
    }

    required init?(coder: NSCoder) { return nil }

    func start() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 60, preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// PHẢI gọi khi gỡ view (dismantleUIView) — CADisplayLink giữ strong target nên không
    /// invalidate sẽ leak và view không bao giờ dealloc.
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick() {
        guard let frame = arSession?.currentFrame else { return }
        updateCamera(frame)
        if frame.timestamp - lastMeshUpdate >= Self.meshUpdateInterval {
            lastMeshUpdate = frame.timestamp
            updateMeshes(frame)
        }
    }

    // MARK: - Canh camera SceneKit theo ARKit

    private func updateCamera(_ frame: ARFrame) {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        // PHẢI ghép viewMatrix và projectionMatrix CÙNG orientation (.portrait) cho nhất quán.
        // camera.transform "thô" tham chiếu theo chiều NGANG của cảm biến; ghép nó với projection
        // đã xoay portrait sẽ lệch đúng 90°. viewMatrix(for:.portrait) đã bao gồm phép xoay này.
        // node camera = nghịch đảo của view (world→camera) = camera→world.
        cameraNode.simdTransform = frame.camera.viewMatrix(for: .portrait).inverse
        let projection = frame.camera.projectionMatrix(
            for: .portrait, viewportSize: size, zNear: 0.01, zFar: 50
        )
        cameraNode.camera?.projectionTransform = SCNMatrix4(projection)
    }

    // MARK: - Dựng lưới từ ARMeshAnchor (throttle; copy trên main, dựng geometry ở nền)

    private func updateMeshes(_ frame: ARFrame) {
        var present = Set<UUID>()
        for anchor in frame.anchors {
            guard let mesh = anchor as? ARMeshAnchor else { continue }
            let id = mesh.identifier
            present.insert(id)

            // Trần: đã đủ dữ liệu thì không thêm VÙNG MỚI (node cũ vẫn tiếp tục cập nhật).
            if anchorNodes[id] == nil && totalVerts >= Self.maxVerts { continue }

            let node: SCNNode
            if let existing = anchorNodes[id] {
                node = existing
            } else {
                node = SCNNode()
                scene?.rootNode.addChildNode(node)
                anchorNodes[id] = node
            }
            // Pose cập nhật mỗi lần (rẻ). Hình học chỉ dựng lại khi ĐỔI và không đang dựng dở.
            node.simdTransform = mesh.transform

            let vSource = mesh.geometry.vertices
            let fElement = mesh.geometry.faces
            let sig = MeshSig(v: vSource.count, f: fElement.count)
            let vLen = vSource.stride * vSource.count
            guard anchorSigs[id] != sig,
                  !inFlight.contains(id),
                  vSource.count > 0, fElement.count > 0, fElement.indexCountPerPrimitive == 3,
                  vSource.offset + vLen <= vSource.buffer.length
            else { continue }
            totalVerts += sig.v - (anchorSigs[id]?.v ?? 0)
            anchorSigs[id] = sig
            inFlight.insert(id)

            // Copy NHANH trên main (ARKit tái dụng MTLBuffer nên phải copy ngay tại đây)…
            let vBytes = Data(bytes: vSource.buffer.contents().advanced(by: vSource.offset), count: vLen)
            let iBytes = Data(bytes: fElement.buffer.contents(), count: fElement.buffer.length)
            let vCount = vSource.count
            let vStride = vSource.stride
            let fCount = fElement.count
            let bpi = fElement.bytesPerIndex

            // …rồi DỰNG geometry ở nền, gán lại trên main. Nhờ vậy main thread không bị chiếm
            // → ARKit/RoomPlan không rớt frame (trước đây gây "đứng lại" + hủy bản quét + crash).
            buildQueue.async {
                let geometry = Self.makeWireframe(
                    vBytes: vBytes, vCount: vCount, vStride: vStride,
                    iBytes: iBytes, faceCount: fCount, bytesPerIndex: bpi
                )
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.inFlight.remove(id)   // luôn giải phóng dù dựng được hay không
                    if let geometry, let node = self.anchorNodes[id] {
                        node.geometry = geometry
                    }
                }
            }
        }
        // Bỏ node của anchor không còn
        for (id, node) in anchorNodes where !present.contains(id) {
            node.removeFromParentNode()
            totalVerts -= anchorSigs[id]?.v ?? 0
            anchorNodes.removeValue(forKey: id)
            anchorSigs.removeValue(forKey: id)
        }
    }

    /// Dựng wireframe từ dữ liệu ĐÃ copy (chạy ở luồng nền — không đụng buffer của ARKit nữa).
    private static func makeWireframe(
        vBytes: Data, vCount: Int, vStride: Int,
        iBytes: Data, faceCount: Int, bytesPerIndex: Int
    ) -> SCNGeometry? {
        guard vCount > 0, faceCount > 0 else { return nil }

        var verts = [SCNVector3]()
        verts.reserveCapacity(vCount)
        vBytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            for i in 0..<vCount {
                let off = vStride * i
                let x = base.loadUnaligned(fromByteOffset: off, as: Float.self)
                let y = base.loadUnaligned(fromByteOffset: off + 4, as: Float.self)
                let z = base.loadUnaligned(fromByteOffset: off + 8, as: Float.self)
                verts.append(SCNVector3(x, y, z))
            }
        }
        guard !verts.isEmpty else { return nil }

        let element = SCNGeometryElement(
            data: iBytes, primitiveType: .triangles,
            primitiveCount: faceCount, bytesPerIndex: bytesPerIndex
        )
        let source = SCNGeometrySource(vertices: verts)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        geometry.materials = [Self.wireframeMaterial]
        return geometry
    }
}

/// Cầu nối SwiftUI cho lớp phủ lưới. Gắn phía trên RoomCaptureView trong ScanFlowView.
struct MeshOverlayRepresentable: UIViewRepresentable {
    let controller: ScanSessionController

    func makeUIView(context: Context) -> MeshOverlayView {
        let view = MeshOverlayView(arSession: controller.arSession)
        view.start()
        return view
    }

    func updateUIView(_ uiView: MeshOverlayView, context: Context) {}

    static func dismantleUIView(_ uiView: MeshOverlayView, coordinator: ()) {
        uiView.stop()
    }
}
