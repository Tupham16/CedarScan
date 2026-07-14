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
    private var lastMeshUpdate: TimeInterval = 0
    private static let meshUpdateInterval: TimeInterval = 0.3

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
        antialiasingMode = .multisampling2X
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
        cameraNode.simdTransform = frame.camera.transform   // camera→world, cùng quy ước SceneKit
        let projection = frame.camera.projectionMatrix(
            for: .portrait, viewportSize: size, zNear: 0.01, zFar: 50
        )
        cameraNode.camera?.projectionTransform = SCNMatrix4(projection)
    }

    // MARK: - Dựng lưới từ ARMeshAnchor (throttle 0.3s)

    private func updateMeshes(_ frame: ARFrame) {
        var present = Set<UUID>()
        for anchor in frame.anchors {
            guard let mesh = anchor as? ARMeshAnchor else { continue }
            let id = mesh.identifier
            present.insert(id)

            let node: SCNNode
            if let existing = anchorNodes[id] {
                node = existing
            } else {
                node = SCNNode()
                scene?.rootNode.addChildNode(node)
                anchorNodes[id] = node
            }
            // Pose cập nhật mỗi lần (rẻ). Hình học chỉ dựng lại khi ĐỔI — tránh churn main thread.
            node.simdTransform = mesh.transform
            let sig = MeshSig(v: mesh.geometry.vertices.count, f: mesh.geometry.faces.count)
            if anchorSigs[id] != sig {
                anchorSigs[id] = sig
                if let geometry = Self.makeWireframe(from: mesh.geometry) {
                    node.geometry = geometry
                }
            }
        }
        // Bỏ node của anchor không còn
        for (id, node) in anchorNodes where !present.contains(id) {
            node.removeFromParentNode()
            anchorNodes.removeValue(forKey: id)
            anchorSigs.removeValue(forKey: id)
        }
    }

    private static func makeWireframe(from mesh: ARMeshGeometry) -> SCNGeometry? {
        let vertexSource = mesh.vertices
        let faceElement = mesh.faces
        let vCount = vertexSource.count
        guard vCount > 0, faceElement.count > 0, faceElement.indexCountPerPrimitive == 3 else {
            return nil
        }

        // Sao chép đỉnh: ARKit dùng float3 xếp sát (stride 12) — đọc 3 Float riêng để KHÔNG
        // over-read như khi ép sang SIMD3<Float> (16 byte).
        var verts = [SCNVector3]()
        verts.reserveCapacity(vCount)
        let base = vertexSource.buffer.contents()
        for i in 0..<vCount {
            let p = base.advanced(by: vertexSource.offset + vertexSource.stride * i)
            let x = p.assumingMemoryBound(to: Float.self).pointee
            let y = p.advanced(by: 4).assumingMemoryBound(to: Float.self).pointee
            let z = p.advanced(by: 8).assumingMemoryBound(to: Float.self).pointee
            verts.append(SCNVector3(x, y, z))
        }

        // Sao chép chỉ số mặt sang Data riêng (không giữ MTLBuffer của ARKit — nó bị tái dụng).
        let indexData = Data(bytes: faceElement.buffer.contents(), count: faceElement.buffer.length)
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: faceElement.count,
            bytesPerIndex: faceElement.bytesPerIndex
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
