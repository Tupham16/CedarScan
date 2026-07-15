import SwiftUI
import SceneKit
import ARKit
import simd

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
    private var anchorDists: [UUID: Float] = [:] // khoảng cách anchor→camera (cho việc nhả vùng xa)
    private var inFlight = Set<UUID>()           // anchor đang dựng dở ở nền → chống dồn hàng
    private var totalVerts = 0                    // tổng đỉnh đang hiển thị (để chặn trần)
    /// Trần đỉnh HIỂN THỊ (chặn phình GPU/bộ nhớ — không liên quan dữ liệu xuất).
    /// RoomPlan: 150k (chạy cạnh RoomPlan nặng). Mesh mode: nâng cao hơn để lưới
    /// không "quên" vùng đã quét khi khách quay lại — khách cần thấy chỗ nào đã phủ.
    private let maxVerts: Int
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

    /// Vật liệu cho vùng CHƯA VÀO dữ liệu xuất (builder tạm tắt vì gián đoạn/mất định vị,
    /// hoặc mô hình đầy). ĐỎ = "chỗ này chưa được ghi — quét lại sau khi hồi phục".
    /// Trước đây overlay tô xanh tuốt nên người quét tưởng "xanh = đã có trong file" và
    /// mất trắng các khu quét trong lúc builder tắt mà không hề hay biết.
    private static let unrecordedMaterial: SCNMaterial = {
        let m = SCNMaterial()
        m.fillMode = .lines
        m.diffuse.contents = UIColor.systemRed
        m.emission.contents = UIColor.systemRed
        m.lightingModel = .constant
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        return m
    }()

    /// Nguồn sự thật "anchor nào ĐÃ vào dữ liệu xuất" + SỐ ĐỈNH đã ghi (từ
    /// ColorMeshBuilder.pieces). So số đỉnh chứ không chỉ ID: anchor phình to mà bị trần
    /// chặn có ID trùng nhưng bản trong file NHỎ hơn bản hiển thị → vẫn phải tô đỏ.
    /// nil (luồng RoomPlan không dùng cơ chế này) → mọi lưới xanh như cũ.
    var recordedCounts: (() -> [UUID: Int])?
    /// Thời điểm anchor xuất hiện lần đầu — anchor mới được "ân hạn" 1.5s trước khi bị tô
    /// đỏ (builder tick 2–5Hz cần chút thời gian gom; không có ân hạn thì lưới mới nào
    /// cũng chớp đỏ rồi mới xanh, nhìn như lỗi).
    private var anchorFirstSeen: [UUID: TimeInterval] = [:]
    /// Timestamp frame gần nhất — cho materialFor dùng được cả ngoài updateMeshes
    /// (closure gán geometry ở main.async không còn frame trong scope).
    private var lastFrameTimestamp: TimeInterval = 0

    init(arSession: ARSession, maxVerts: Int = 150_000) {
        self.arSession = arSession
        self.maxVerts = maxVerts
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
        lastFrameTimestamp = frame.timestamp
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
        let c4 = frame.camera.transform.columns.3
        let camPos = SIMD3(c4.x, c4.y, c4.z)
        var present = Set<UUID>()
        for anchor in frame.anchors {
            guard let mesh = anchor as? ARMeshAnchor else { continue }
            let id = mesh.identifier
            present.insert(id)

            let a4 = mesh.transform.columns.3
            let dist = simd_distance(SIMD3(a4.x, a4.y, a4.z), camPos)
            anchorDists[id] = dist
            if anchorFirstSeen[id] == nil {
                anchorFirstSeen[id] = frame.timestamp
            }

            let vSource = mesh.geometry.vertices
            let fElement = mesh.geometry.faces
            let sig = MeshSig(v: vSource.count, f: fElement.count)

            let node: SCNNode
            if let existing = anchorNodes[id] {
                node = existing
            } else {
                // Vùng MỚI khi đã chạm trần: chỉ nhận nếu nhả được các vùng XA HƠN để lấy chỗ
                // — lưới "đi theo" người quét thay vì tắt hẳn (lỗi cũ: quét lâu là mất lưới).
                if totalVerts + sig.v > maxVerts {
                    guard evictFarther(than: dist, toFit: sig.v) else { continue }
                }
                let created = SCNNode()
                scene?.rootNode.addChildNode(created)
                anchorNodes[id] = created
                node = created
            }
            // Pose cập nhật mỗi lần (rẻ). Hình học chỉ dựng lại khi ĐỔI và không đang dựng dở.
            node.simdTransform = mesh.transform

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
                        // Chọn vật liệu NGAY khi gán geometry mới — không đợi retint 0.5s.
                        // (makeWireframe gán xanh mặc định; anchor ĐỎ đang được ARKit cập
                        // nhật liên tục sẽ chớp xanh↔đỏ ~2Hz nếu chỉ dựa vào retint —
                        // đúng lúc người quét cần tín hiệu "chưa ghi" tin cậy nhất.)
                        if let recorded = self.recordedCounts?() {
                            geometry.materials = [self.materialFor(id, recorded: recorded)]
                        }
                        node.geometry = geometry
                    }
                }
            }
        }
        // Bỏ node/dữ liệu của anchor không còn trong phiên
        for id in Array(anchorDists.keys) where !present.contains(id) {
            removeAnchor(id)
        }
        // Anchor cũ phình to có thể đẩy tổng vượt trần → tỉa vùng XA camera nhất
        trimOverCap()
        // Tô lưới theo trạng thái GHI THẬT (xanh = đã vào file, đỏ = chưa)
        retintForRecording()
    }

    /// Vật liệu đúng cho anchor theo dữ liệu xuất thật. "Đã ghi" = bản trong file đạt
    /// ≥85% số đỉnh đang hiển thị (dung sai hấp thụ độ trễ builder 2–5Hz với update nhỏ;
    /// anchor phình to bị trần chặn sẽ tụt dưới ngưỡng → đỏ dù ID có trong file).
    private func materialFor(_ id: UUID, recorded: [UUID: Int]) -> SCNMaterial {
        if lastFrameTimestamp - (anchorFirstSeen[id] ?? lastFrameTimestamp) < 1.5 {
            return Self.wireframeMaterial // ân hạn anchor mới
        }
        let shown = anchorSigs[id]?.v ?? 0
        let saved = recorded[id] ?? 0
        let isRecorded = saved > 0 && (shown == 0 || Float(saved) >= Float(shown) * 0.85)
        return isRecorded ? Self.wireframeMaterial : Self.unrecordedMaterial
    }

    /// Tô lại lưới theo dữ liệu xuất thật: anchor chưa vào bộ tích lũy sau thời gian ân hạn
    /// → ĐỎ. So sánh identity vật liệu nên vòng lặp gần như miễn phí khi không đổi trạng thái.
    private func retintForRecording() {
        guard let recorded = recordedCounts?() else { return }
        for (id, node) in anchorNodes {
            guard let geometry = node.geometry else { continue }
            let material = materialFor(id, recorded: recorded)
            if geometry.firstMaterial !== material {
                geometry.materials = [material]
            }
        }
    }

    /// Nhả các vùng XA camera hơn `dist` (xa nhất trước) cho tới khi đủ chỗ cho `needed` đỉnh.
    /// Trả về false nếu nhả hết vẫn không đủ (vùng mới xa hơn mọi vùng đang giữ → bỏ qua,
    /// nhờ vậy vùng vừa bị nhả không bị nhận lại ngay — không giật qua lại).
    private func evictFarther(than dist: Float, toFit needed: Int) -> Bool {
        let farther = anchorDists
            .filter { anchorNodes[$0.key] != nil && $0.value > dist }
            .sorted { $0.value > $1.value }
        var freed = 0
        var victims: [UUID] = []
        for (id, _) in farther {
            if totalVerts - freed + needed <= maxVerts { break }
            freed += anchorSigs[id]?.v ?? 0
            victims.append(id)
        }
        guard totalVerts - freed + needed <= maxVerts else { return false }
        for id in victims { removeAnchor(id) }
        return true
    }

    private func trimOverCap() {
        while totalVerts > maxVerts {
            guard let far = anchorDists
                .filter({ anchorNodes[$0.key] != nil })
                .max(by: { $0.value < $1.value })
            else { break }
            removeAnchor(far.key)
        }
    }

    private func removeAnchor(_ id: UUID) {
        anchorNodes[id]?.removeFromParentNode()
        totalVerts -= anchorSigs[id]?.v ?? 0
        anchorNodes.removeValue(forKey: id)
        anchorSigs.removeValue(forKey: id)
        anchorDists.removeValue(forKey: id)
        anchorFirstSeen.removeValue(forKey: id)
        // Nhả luôn cờ đang-dựng: nếu anchor được nhận lại ngay, bản dựng mới không bị chặn.
        // (Queue nền serial + main FIFO nên bản dựng mới luôn gán SAU bản cũ — không lo ngược thứ tự.)
        inFlight.remove(id)
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

/// Cầu nối SwiftUI cho lớp phủ lưới. Gắn phía trên RoomCaptureView (ScanFlowView)
/// hoặc ARSCNView camera (MeshScanFlowView) — chỉ cần ARSession dùng chung.
struct MeshOverlayRepresentable: UIViewRepresentable {
    let arSession: ARSession
    var maxVerts: Int = 150_000
    /// Đưa vào từ mesh mode để lưới tô trung thực (xanh = đã ghi, đỏ = chưa); RoomPlan để nil.
    var recordedCounts: (() -> [UUID: Int])? = nil

    func makeUIView(context: Context) -> MeshOverlayView {
        let view = MeshOverlayView(arSession: arSession, maxVerts: maxVerts)
        view.recordedCounts = recordedCounts
        view.start()
        return view
    }

    func updateUIView(_ uiView: MeshOverlayView, context: Context) {
        uiView.recordedCounts = recordedCounts
    }

    static func dismantleUIView(_ uiView: MeshOverlayView, coordinator: ()) {
        uiView.stop()
    }
}
