import SwiftUI
import SceneKit
import ARKit
import simd

/// Lớp phủ LƯỚI LiDAR (wireframe) vẽ TRONG scene của ARSCNView đang hiện hình camera — để
/// người quét biết bề mặt nào đã được quét (giống CubiCasa/Polycam).
/// Ngôn ngữ màu (chủ app chốt 2026-07-28; TRẮNG đổi nghĩa 2026-08-03, item 2
/// PLAN-PHU-DU-DO-DUNG): lưới TRẮNG = đã vào file **VÀ đã có ẢNH TEXTURE lưu** (bản giao
/// chỗ này sẽ có ảnh); có mesh mà CHƯA CÓ ẢNH (lia nhanh, keyframe chưa đậu) → lưới + mặt
/// nạ của anchor đó ẨN đi nên phủ đỏ hiện lại — trông như chưa quét, quay lại lia chậm là
/// trắng (chủ app CHỌN không thêm màu thứ 3); lưới ĐỎ = có mesh nhưng CHƯA được ghi (mất
/// dữ liệu builder — vai này GIỮ NGUYÊN, ✗ chiếm); vùng KHÔNG có mesh phủ ĐỎ MỜ
/// (`tintNode` + mặt nạ depth) = chưa quét tới.
///
/// 🔴 06/08: VẾ "ĐÃ CÓ ẢNH" ĐÃ BỊ RÚT KHỎI HIỂN THỊ — `MeshScanFlowView` KHÔNG nối
/// `photoCoverage` nữa (closure nil → toàn bộ nhánh coverage trong file này ngủ, đường cũ
/// byte-for-byte). Lưới trắng nay = ĐÃ VÀO FILE, thế thôi. Lý do + điều kiện nối lại ghi
/// tại chỗ nối (MeshScanFlowView) và SESSION-HANDOFF §STATE `b7b6d47`. Code coverage bên
/// dưới GIỮ NGUYÊN làm nền cho bản sửa gốc sau này — ✗ dọn "cho sạch".
///
/// 🔴 KHÔNG PHẢI MỘT VIEW. Đây là bộ dựng node, gắn vào scene của ARSCNView (xem `attach(to:)`
/// và chú thích đầu `ARCameraView.swift`).
///
/// Đời trước nó là một `SCNView` trong suốt chồng lên hình camera và tự lái một camera SceneKit
/// riêng. Chủ app báo "lưới rung khi lia máy" (2026-07-29, xác nhận hai lần) và nguyên nhân
/// đúng là chỗ đó: hai view = hai vòng render độc lập, mỗi bên tự đọc `arSession.currentFrame`
/// theo nhịp riêng → lưới và ảnh nền lệch nhau 0–1 khung ARKit, độ lệch ĐẢO QUA ĐẢO LẠI, lia
/// máy 30–60°/s là hàng chục pixel. Gộp vào một vòng render xoá hẳn lớp lỗi này.
/// ⚠ ĐỪNG đổ lỗi cho `updateAnchorPoses`: giả thuyết "pose bị hãm 0,5s" đã được kiểm và BÁC BỎ
/// (xem chú thích tại hàm đó).
///
/// Chỉ ĐỌC arSession.currentFrame (không đổi cấu hình, không đụng phiên RoomPlan) nên an toàn
/// với luồng quét: display link ở đây chỉ dùng để DỰNG/ĐỔI node, còn việc canh camera thì
/// ARSCNView tự lo — đó là toàn bộ điểm của việc gộp view.
final class MeshOverlayRenderer: NSObject {
    /// Node chứa TẤT CẢ node của lớp phủ, gắn vào scene của ARSCNView. Gom một chỗ để bật/tắt
    /// và dọn sạch chỉ bằng một thao tác.
    private let rootNode = SCNNode()
    /// View AR đang chứa lớp phủ — cần cho kích thước khung nhìn và cho `pointOfView`.
    private weak var sceneView: ARSCNView?
    private weak var arSession: ARSession?
    private var displayLink: CADisplayLink?
    /// Quad đỏ mờ "chưa quét", chắn ngang tầm nhìn ở `tintDistance`; mesh đã quét ghi depth
    /// (node mặt nạ) nên khoét thủng nó. Tư thế + kích thước cập nhật mỗi tick ở `updateTint`.
    ///
    /// 🔴 LÀ CON CỦA `rootNode`, **✗ ĐỪNG GẮN VÀO `sceneView.pointOfView`.** Chú thích ở đúng
    /// chỗ này từng dạy điều ngược lại và đó chính là lỗi chủ app báo 2026-07-29: tấm phủ đỏ
    /// BIẾN MẤT HẲN. SceneKit chỉ vẽ cây con của `scene.rootNode`, mà node camera của ARSCNView
    /// do view tự quản và không bảo đảm nằm trong cây đó — cha không được vẽ thì con cũng không.
    /// Lỗi này COMPILE SẠCH nên CI không bắt được, chỉ lộ khi cầm máy thật.
    /// ⚠ Đổi lại: tư thế do tick 30Hz đặt nên trễ 0–33ms so với khung đang vẽ, KHÔNG "khớp từng
    /// khung" như chú thích cũ nói — đó là lý do tồn tại của `tintOversize`, đọc hằng số đó
    /// trước khi chỉnh bất cứ thứ gì ở đây.
    private let tintNode = SCNNode()
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
    /// TRẮNG (chủ app chốt 2026-07-28, trước là xanh lá): "trắng = đã quét", còn màu đỏ dồn
    /// hết cho nghĩa "chưa có trong file" (lưới đỏ + lớp phủ đỏ vùng chưa quét).
    ///
    /// `readsFromDepthBuffer = false` BẮT BUỘC từ khi có `depthMaskMaterial`: mặt fill ghi depth
    /// nằm TRÙNG mặt phẳng với chính các vạch lưới của nó — để lưới đọc depth là z-fighting nhấp
    /// nháy đúng nơi người quét đang nhìn. Tắt đọc depth giữ nguyên kiểu nhìn "xuyên" như cũ
    /// (trước giờ không ai ghi depth nên lưới vốn vẫn xuyên).
    private static let wireframeMaterial: SCNMaterial = {
        let m = SCNMaterial()
        m.fillMode = .lines                 // wireframe = "lưới"
        m.diffuse.contents = UIColor.white
        m.emission.contents = UIColor.white
        m.lightingModel = .constant          // không phụ thuộc đèn, luôn rõ
        m.isDoubleSided = true
        m.writesToDepthBuffer = false        // tránh tự che khuất khó nhìn
        m.readsFromDepthBuffer = false
        return m
    }()

    /// Vật liệu cho vùng CHƯA VÀO dữ liệu xuất (builder tạm tắt vì gián đoạn/mất định vị,
    /// hoặc mô hình đầy). ĐỎ = "chỗ này chưa được ghi — quét lại sau khi hồi phục".
    /// Trước đây overlay tô một màu tuốt nên người quét tưởng "có lưới = đã có trong file" và
    /// mất trắng các khu quét trong lúc builder tắt mà không hề hay biết.
    private static let unrecordedMaterial: SCNMaterial = {
        let m = SCNMaterial()
        m.fillMode = .lines
        m.diffuse.contents = UIColor.systemRed
        m.emission.contents = UIColor.systemRed
        m.lightingModel = .constant
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        m.readsFromDepthBuffer = false       // cùng lý do với wireframeMaterial
        return m
    }()

    /// Vật liệu "mặt nạ depth": vẽ CHÍNH các tam giác mesh nhưng KHÔNG ra màu
    /// (`colorBufferWriteMask = []`), chỉ ghi depth. Mục đích duy nhất: khoét lỗ lớp phủ đỏ
    /// `unscannedTint` — quad đỏ đọc depth, chỗ nào mesh đã ghi depth (gần hơn quad) thì đỏ
    /// bị loại, chỗ chưa có mesh thì đỏ hiện = "chưa quét tới". Render TRƯỚC mọi thứ
    /// (renderingOrder xem `maskRenderingOrder`).
    private static let depthMaskMaterial: SCNMaterial = {
        let m = SCNMaterial()
        m.fillMode = .fill
        m.colorBufferWriteMask = []
        m.writesToDepthBuffer = true
        m.isDoubleSided = true
        m.lightingModel = .constant
        return m
    }()

    /// Thứ tự render: mặt nạ depth trước (âm) → lưới (0, pass opaque) → quad đỏ (pass
    /// transparent, sau opaque). Quad thuộc pass transparent sẵn vì màu có alpha, nhưng vẫn
    /// đặt số dương cho rõ ý.
    private static let maskRenderingOrder = -10
    private static let tintRenderingOrder = 10
    /// Độ mờ lớp phủ đỏ. Chủ app chỉnh dần trên máy thật, mỗi lần đều thấy còn nhạt:
    /// 0.22 → 0.40 → 0.50 → 0.80 (2026-07-29) → **0.86** (2026-08-13, ông xin "đậm thêm 1 chút").
    /// ⚠ Ở 0.86 thì hình camera dưới vùng CHƯA QUÉT chỉ còn ~14% — cố ý, để vùng chưa quét đập
    /// vào mắt. Đổi lại người quét khó nhìn chi tiết trong vùng đó để nhắm máy; nếu thấy khó
    /// lia thì hạ lại, đây là hằng số một dòng và không ràng buộc gì khác.
    private static let tintAlpha: CGFloat = 0.86
    /// Màu tấm phủ. **✗ `UIColor.systemRed`** nữa (2026-08-13, chủ app: "màu đỏ cho nó đậm thêm
    /// 1 chút nhìn tươi hơn"): systemRed là #FF3B30 — G/B còn ~0.2 nên phủ dày lên hình camera
    /// ra đỏ GẠCH xỉn chứ không tươi. Hạ G/B gần 0 là tăng ĐỘ BÃO HOÀ (tươi) mà không phải tăng
    /// thêm độ mờ (thứ ăn nốt hình camera). Hai hằng số này chỉnh độc lập nhau: `tintAlpha` =
    /// che bao nhiêu, cái này = đỏ tươi cỡ nào.
    /// ⚠ ✗ đụng `unrecordedMaterial` (lưới ĐỎ "chưa được ghi") theo cho "đồng bộ" — hai vai khác
    /// hẳn nhau và lưới đỏ phải còn phân biệt được khi nằm cạnh tấm phủ.
    private static let tintColor = UIColor(red: 1.0, green: 0.04, blue: 0.06, alpha: 1)
    /// Quad đặt cách camera 40m: phải XA HƠN mọi mesh đang nhìn thấy (mesh xa hơn quad thì
    /// nằm sau nó, không khoét được → vùng ĐÃ quét bị phủ đỏ oan), nhưng phải GẦN HƠN mặt
    /// phẳng xa của camera (quá thì bị cắt sạch và tấm phủ biến mất hoàn toàn).
    ///
    /// 🔴 CHÚ THÍCH CŨ Ở ĐÂY TỪNG NÓI "trong zFar 50 của `updateCamera`" — SAI TỪ KHI GỘP VIEW:
    /// `updateCamera` đã bị xoá, lớp phủ không còn đặt ma trận chiếu nào, mặt phẳng xa giờ do
    /// ARSCNView/ARKit quyết và KHÔNG dòng nào trong repo đặt hay kiểm nó. Vì vậy `updateTint`
    /// KẸP giá trị này theo `zFar` THẬT đọc từ camera đang render. Mặc định của ARKit là 1000m
    /// nên bình thường không kẹp gì; kẹp chỉ để tấm phủ không bao giờ biến mất lặng lẽ nữa.
    private static let tintDistance: Float = 40
    /// Hệ số nới tấm phủ so với bề rộng frustum.
    ///
    /// 🔴 1.05 LÀ KHÔNG ĐỦ, ĐỪNG HẠ VỀ. Nới 5% KÍCH THƯỚC chỉ ra ~0,7° dư GÓC ngang
    /// (atan(1,05·tan14,92°) − 14,92°) — hai đại lượng khác nhau, chú thích đời trước lẫn lộn.
    /// Từ khi gộp view, tấm phủ không còn là con của node camera nên tư thế của nó do tick
    /// 30Hz của lớp phủ đặt, trễ 0–33ms so với khung ARSCNView đang vẽ; lia 60°/s là lệch tới
    /// 2°. Dư 0,7° → HỞ MỘT DẢI KHÔNG-ĐỎ ở mép màn phía đang lia tới, nhìn như "viền đã quét"
    /// giả và như rung mép. 1.3 cho ~4,2° dư, tức chịu được ~70ms trễ ở 60°/s.
    /// Gần như miễn phí: phần thừa nằm ngoài khung nhìn nên bị cắt trước khi tô pixel.
    private static let tintOversize: Float = 1.3

    /// 🔴 MẶT NẠ DEPTH CÓ SỔ RIÊNG, KHÔNG ĐI THEO TRẦN HIỂN THỊ. Review đối kháng 2026-07-29
    /// (5 lens độc lập cùng bắt): nếu mask là con của node hiển thị thì evictFarther/trimOverCap
    /// (trần `maxVerts` 600k) gỡ mask theo → vùng ĐÃ quét, ĐÃ vào file bị phủ đỏ "chưa quét tới"
    /// — nhà 2 tầng thật ~0.5–1.5M đỉnh nên đây là ca THƯỜNG GẶP, và tín hiệu sai chủ động còn
    /// tệ hơn không có tín hiệu. Vì vậy: node lưới (đắt — rasterize vạch) giữ trần 600k như cũ,
    /// còn mask (rẻ — chỉ ghi depth, không màu) sống theo anchor với ngân sách riêng bên dưới.
    private var maskNodes: [UUID: SCNNode] = [:]
    /// Geometry lưới đã dựng lần cuối — để anchor bị nhả khỏi trần hiển thị được NHẬN LẠI
    /// ngay bằng cache (sig không đổi thì không có gì kích hoạt rebuild nữa).
    private var wireGeos: [UUID: SCNGeometry] = [:]
    /// Tổng đỉnh đang có mặt nạ (sổ theo `anchorSigs`, không đo geometry thật).
    private var maskVerts = 0
    /// Ngân sách mask = trần XUẤT của mesh mode (MeshQuality.wholeHomePreset 2M). Vượt nó là
    /// mô hình cũng đầy → banner "Mô hình đã đầy — Dừng & Lưu" đã hiện; lớp phủ đỏ tắt hẳn
    /// (`disableMasking`) thay vì bắt đầu nói dối vì thiếu mask.
    private static let maskMaxVerts = 2_000_000
    private var maskingDisabled = false
    /// Trạng thái bật/tắt do SwiftUI quyết (xem `setVisible`).
    private var visible = false
    /// Đã có thứ khoét được tấm phủ đỏ. Một chiều trong mỗi vòng đời (chỉ `releaseAll` hạ
    /// xuống): mask bị gỡ hết về sau nghĩa là quanh đây thật sự không có gì đã quét, lúc đó phủ
    /// đỏ là ĐÚNG. Xem `refreshTintVisibility` và `openCarveGate`.
    private var hasCarvingMask = false
    /// Mốc tick ĐẦU TIÊN có ARFrame ≈ lúc ARKit trả khung camera đầu. Chỉ dùng cho ÂN HẠN KHỞI
    /// ĐỘNG ở cuối `updateMeshes` — đọc chú thích dài tại đó.
    /// 🔴 `releaseAll` CỐ Ý KHÔNG đặt lại mốc này (khác `lastMeshUpdate`): tắt/bật lưới ở phút
    /// thứ 10 thì máy đã chạy từ lâu, bắt chờ ân hạn lần nữa là giấu tín hiệu đỏ vô cớ.
    private var firstTickTimestamp: TimeInterval = 0
    /// Ân hạn khởi động của TẤM PHỦ ĐỎ. Trong quãng này, CHƯA có anchor nào thì tấm phủ IM.
    private static let warmupGraceSec: TimeInterval = 6
    /// Tập anchor của ĐỢT DỰNG LẠI sau `releaseAll` mà bản dựng chưa về.
    ///
    /// 🔴 VÌ SAO PHẢI ĐẾM CẢ ĐỢT chứ không mở cổng ở mask ĐẦU TIÊN: `releaseAll` xoá sạch nên
    /// khi bật lưới lại, CẢ N anchor cùng được xếp lên `buildQueue` (serial, .utility) trong
    /// đúng một nhịp. Mở cổng ở completion thứ nhất là tấm phủ hiện khi mới có 1/N mask —
    /// nguyên căn nhà VỪA QUÉT XONG bị tô đỏ "chưa quét tới" cho tới khi hàng rút hết.
    /// ⚠ ✗ GÁC BẰNG `inFlight.isEmpty`: lúc quét bình thường ARKit cập nhật anchor liên tục nên
    /// `inFlight` gần như luôn khác rỗng → tấm phủ nhấp nháy cả buổi.
    /// Dùng TẬP ID (không phải bộ đếm) để bản dựng của đợt SAU không trừ nhầm vào đợt này.
    private var rebuildBatch: Set<UUID> = []
    /// Đang ở LƯỢT `updateMeshes` ĐẦU TIÊN của một đợt dựng — lượt duy nhất được ghi vào
    /// `rebuildBatch`. Đóng sổ ngay cuối lượt đó, không thì anchor mới sinh trong lúc quét cứ
    /// nối thêm vào đợt và cổng không bao giờ mở.
    ///
    /// 🔴 KHỞI TẠO `true`, ĐỪNG ĐỔI VỀ `false`. Đợt dựng đầu tiên KHÔNG PHẢI lúc nào cũng là
    /// "màn quét sạch chưa có gì": `showScanMesh` là @AppStorage nên khách tắt lưới một lần là
    /// các phiên sau vào màn quét với lưới đang TẮT, quét cả chục phút (ARKit vẫn dựng anchor
    /// bình thường), rồi mới bật lưới lên để soi độ phủ. Lúc đó `releaseAll` chưa từng chạy, và
    /// nếu cờ này là `false` thì cổng mở ngay ở mask ĐẦU TIÊN → nguyên căn nhà vừa quét bị tô
    /// đỏ "chưa quét tới" cho tới khi hàng dựng rút hết. Khởi tạo `true` thì lượt đầu luôn được
    /// tính thành một đợt: không anchor nào → mở cổng ngay (đúng ca màn quét sạch); có anchor →
    /// chờ đợt rút hết (đúng ca vừa tả).
    private var countingRebuild = true
    /// Mask của anchor vừa CHẾT (ARKit gộp/tách) được giữ thêm một nhịp ân hạn rồi mới gỡ.
    /// Cùng lớp lỗi chớp-tín-hiệu với `anchorFirstSeen` của lưới: bản anchor THAY THẾ chỉ có
    /// depth SAU build nền (0.1–1.5s khi queue dồn) — gỡ mask cũ tức thì là vùng ĐÃ LƯU chớp
    /// đỏ mỗi cú loop closure, đúng lúc người quét cần tin màu đỏ nhất. Review vòng 2 bắt.
    private var dyingMasks: [(node: SCNNode, deadline: TimeInterval)] = []
    private static let maskLingerSec: TimeInterval = 1.5

    /// Nguồn sự thật "anchor nào ĐÃ vào dữ liệu xuất" + SỐ ĐỈNH đã ghi (từ
    /// ColorMeshBuilder.pieces). So số đỉnh chứ không chỉ ID: anchor phình to mà bị trần
    /// chặn có ID trùng nhưng bản trong file NHỎ hơn bản hiển thị → vẫn phải tô đỏ.
    /// nil (luồng RoomPlan cũ không dùng cơ chế này) → mọi lưới trắng, không tô đỏ "chưa ghi".
    var recordedCounts: (() -> [UUID: Int])?
    /// Item 2 PLAN-PHU-DU-DO-DUNG (chủ app chốt 03/08): TRẮNG còn cần "≥75% mẫu đỉnh nằm
    /// trong voxel ĐÃ CÓ ẢNH LƯU" (TextureCoverageGrid của TextureShotRecorder). Chưa đạt
    /// → GIẤU lưới + mặt nạ anchor đó (phủ đỏ hiện = "chưa xong chỗ này"). nil = luồng
    /// không có recorder → hành vi cũ nguyên vẹn.
    var photoCoverage: (() -> TextureCoverageGrid?)?
    /// Voxel-key MẪU THEO WORLD của từng anchor — lấy ~32 đỉnh lúc DỰNG geometry ở luồng
    /// nền (transform anchor gần như bất động — ARKit chỉ nhích dưới mm lúc khép vòng,
    /// voxel 25cm nuốt trọn; anchor đổi hình học là rebuild → key tươi lại). Sống qua
    /// evictWire như anchorSigs (mask còn khoét thì còn cần coverage), chết ở removeAnchor.
    private var anchorCoverageKeys: [UUID: [Int64]] = [:]
    /// Memo MỘT CHIỀU anchor đã đủ ảnh — tập voxel chỉ PHÌNH nên trắng rồi là trắng luôn
    /// (không nhấp nháy), và mỗi nhịp chỉ còn phải đo anchor CHƯA phủ.
    private var coveredAnchors: Set<UUID> = []
    /// X% mẫu đỉnh phải nằm trong voxel có ảnh. 0.75 theo plan (dải 70–85) — chỉnh bằng
    /// mắt trên máy thật nếu chớp trắng↔đỏ ở mép vùng đang quét.
    private static let coverageMinFraction: Float = 0.75
    /// Thời điểm anchor xuất hiện lần đầu — anchor mới được "ân hạn" 1.5s trước khi bị tô
    /// đỏ (builder tick 2–5Hz cần chút thời gian gom; không có ân hạn thì lưới mới nào
    /// cũng chớp đỏ rồi mới trắng, nhìn như lỗi).
    private var anchorFirstSeen: [UUID: TimeInterval] = [:]
    /// Timestamp frame gần nhất — cho materialFor dùng được cả ngoài updateMeshes
    /// (closure gán geometry ở main.async không còn frame trong scope).
    private var lastFrameTimestamp: TimeInterval = 0

    init(arSession: ARSession, maxVerts: Int = 150_000) {
        self.arSession = arSession
        self.maxVerts = maxVerts
        super.init()

        // Lớp phủ đỏ "chưa quét". Vật liệu dựng tại chỗ (không static như các vật liệu kia)
        // vì nó thuộc về đúng MỘT node sống cùng đối tượng này. Đọc depth (mặc định) là cốt
        // lõi của cơ chế khoét; không ghi depth để khỏi tự che chính mình ở khung sau.
        let tintPlane = SCNPlane(width: 1, height: 1)
        let tintMaterial = SCNMaterial()
        tintMaterial.diffuse.contents = Self.tintColor.withAlphaComponent(Self.tintAlpha)
        tintMaterial.lightingModel = .constant
        tintMaterial.writesToDepthBuffer = false
        tintPlane.materials = [tintMaterial]
        tintNode.geometry = tintPlane
        tintNode.renderingOrder = Self.tintRenderingOrder
        // Tấm phủ nằm trong CÂY CỦA CHÍNH LỚP PHỦ, tư thế cập nhật mỗi tick — xem `updateTint`.
        rootNode.addChildNode(tintNode)
    }

    /// Gắn lớp phủ vào ĐÚNG view đang vẽ hình camera. Sau lời gọi này, lưới được rasterize
    /// bằng chính camera của ARSCNView — tức bằng đúng ARFrame đã sinh ra ảnh nền.
    func attach(to view: ARSCNView) {
        sceneView = view
        view.scene.rootNode.addChildNode(rootNode)
    }

    /// Gỡ sạch khỏi scene (gọi ở `dismantleUIView`).
    /// ⚠ KHÔNG gỡ riêng `tintNode`: nó là con của `rootNode` nên đi theo; gỡ riêng là mồ côi
    /// vĩnh viễn, gắn view lại cũng không có tấm phủ nữa.
    func detach() {
        stop()
        rootNode.removeFromParentNode()
        sceneView = nil
    }

    /// Bật/tắt lớp phủ.
    ///
    /// 🔴 HÀM NÀY BỊ GỌI Ở **MỌI** LẦN `updateUIView`, tức mỗi lần body của `MeshScanFlowView`
    /// dựng lại (rất nhiều: `capReached`, `trackingLost`, `isInterrupted`… đều là @Published).
    /// Nên nó phải IDEMPOTENT và tuyệt đối không được ghi đè trạng thái do nơi khác quyết định.
    ///
    /// 🔴 ✗ GÁN THẲNG `tintNode.isHidden = !visible` Ở ĐÂY — ĐÓ LÀ LỖI CHẶN ĐÃ XẢY RA.
    /// Việc hiện tấm phủ đỏ do BA điều kiện quyết định, không phải một; đi qua
    /// `refreshTintVisibility()` là chỗ DUY NHẤT biết đủ cả ba. Gán thẳng ở đây thì chỉ cần
    /// một lần re-render sau khi `disableMasking()` chạy là tấm phủ sống lại mà không còn gì
    /// khoét nó → người quét nhìn cả thế giới qua tấm đỏ 86% cho tới hết buổi, tắt/bật lưới
    /// cũng không cứu được. (Đời trước không lộ vì tắt lưới là tháo hẳn view.)
    ///
    /// Tắt thì DỪNG display link + GIẢI PHÓNG hình học, đúng bằng hành vi cũ — xem `releaseAll`.
    func setVisible(_ visible: Bool) {
        self.visible = visible
        rootNode.isHidden = !visible
        refreshTintVisibility()
        if visible {
            start()
        } else if displayLink != nil {
            stop()
            releaseAll()
        }
    }

    /// 🔴 BẤT BIẾN DUY NHẤT QUYẾT ĐỊNH TẤM PHỦ ĐỎ CÓ ĐƯỢC HIỆN KHÔNG.
    /// Tấm phủ chỉ có nghĩa khi CÓ THỨ KHOÉT NÓ. Nếu hiện lúc chưa mask nào mang hình học thì
    /// nó tô đỏ 86% TOÀN màn hình và bảo người quét rằng cả căn nhà chưa được quét — đúng loại
    /// "tín hiệu sai chủ động" mà file này coi là tệ hơn không có tín hiệu.
    /// Ba ca phải cùng chặn, và trước đây mỗi ca được xử lý một kiểu nên hở:
    ///  • lưới đang tắt (`visible`),
    ///  • ngân sách mask đã cạn nên mọi mask bị xoá (`maskingDisabled` — cơ chế một chiều),
    ///  • VỪA dựng lại từ đầu, mask chưa kịp có hình học (`hasCarvingMask`): mask được tạo
    ///    RỖNG trong `updateMeshes` rồi mới nhận hình học ở completion của luồng nền
    ///    (0,1–1,5s, lâu hơn khi hàng dồn) — cửa sổ này có thật cả ở bản đang chạy.
    /// Gọi lại ở MỌI chỗ đổi một trong ba biến đó, và mỗi tick trong `updateTint`.
    private func refreshTintVisibility() {
        tintNode.isHidden = !visible || maskingDisabled || !hasCarvingMask
    }

    /// Mở cổng tấm phủ đỏ (một chiều tới lần `releaseAll` kế tiếp).
    private func openCarveGate() {
        guard !hasCarvingMask else { return }
        hasCarvingMask = true
        refreshTintVisibility()
    }

    /// Trả lại toàn bộ bộ nhớ hình học của lớp phủ, đưa về đúng trạng thái lúc mới dựng.
    ///
    /// 🔴 VÌ SAO PHẢI CÓ: đời trước, tắt lưới = SwiftUI tháo hẳn view = mọi node + `wireGeos`
    /// chết theo. Sau khi gộp vào ARSCNView thì renderer do Coordinator giữ, nên nếu chỉ `isHidden`
    /// thì hình học vẫn nằm nguyên trong RAM. Lưu ý `wireGeos` KHÔNG bị trần `maxVerts` chặn
    /// (trần chỉ áp cho node HIỂN THỊ) nên nó giữ geometry của MỌI anchor còn sống — tới ~2M
    /// đỉnh ≈ 70MB phía CPU cộng bản sao MTLBuffer phía GPU. Giữ nguyên khối đó xuyên qua
    /// `stopAndExport` + nén zip là chồng thêm vào ĐÚNG đỉnh RAM của cả app, chỗ bị iOS giết
    /// thì mất trắng buổi quét 10–30 phút.
    ///
    /// Bật lại lưới thì dựng lại từ đầu (ARKit báo lại toàn bộ anchor mỗi khung, `anchorSigs`
    /// rỗng nên mọi anchor được xếp dựng ngay tick sau) — đúng bằng hành vi cũ.
    /// Bản dựng đang bay ở luồng nền không hồi sinh được: completion có `guard anchorSigs[id] != nil`.
    private func releaseAll() {
        // 🔴 GỠ ĐÚNG NODE ĐANG THEO SỔ, ✗ `rootNode.childNodes.forEach` — `tintNode` cũng là
        // con của `rootNode`, quét sạch con là mất luôn tấm phủ đỏ và không có đường dựng lại.
        for node in anchorNodes.values { node.removeFromParentNode() }
        for node in maskNodes.values { node.removeFromParentNode() }
        for entry in dyingMasks { entry.node.removeFromParentNode() }
        dyingMasks.removeAll()
        anchorNodes.removeAll()
        maskNodes.removeAll()
        wireGeos.removeAll()
        anchorSigs.removeAll()
        anchorDists.removeAll()
        anchorFirstSeen.removeAll()
        anchorCoverageKeys.removeAll()
        coveredAnchors.removeAll()
        inFlight.removeAll()
        totalVerts = 0
        maskVerts = 0
        hasCarvingMask = false
        rebuildBatch.removeAll()
        countingRebuild = true
        // Trả nhịp về 0 để lần bật lại được dựng NGAY tick sau. `frame.timestamp` là mốc lớn
        // tăng dần nên 0 luôn qua được cổng `>= meshUpdateInterval`. Không reset thì tắt/bật
        // nhanh hơn nửa giây sẽ phải chờ hết quãng hãm mới bắt đầu dựng.
        lastMeshUpdate = 0
        // Đếm lại từ 0 nên ngân sách mask cũng bắt đầu lại — giống hệt việc dựng một view mới
        // ở đời trước. Không mở lại cờ này thì bật lưới lên chỉ có lưới trắng, vĩnh viễn không
        // còn tấm phủ đỏ dù mô hình đã rỗng.
        maskingDisabled = false
        refreshTintVisibility()
    }

    func start() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        // NHỊP CỐ ĐỊNH 30, không để dải 20–60. Dải rộng cho phép hệ thống tụt xuống 20 rồi
        // vọt lên 60 tuỳ tải, tức khoảng cách giữa hai lần cập nhật pose lúc dài lúc ngắn —
        // mắt đọc chuyển động không đều thành rung, ngay cả khi pose đã đúng.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30)
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
        let perfT0 = ScanPerfProfiler.tickBegin()
        defer { ScanPerfProfiler.tickEnd(.overlay, perfT0) }
        guard let frame = arSession?.currentFrame else { return }
        lastFrameTimestamp = frame.timestamp
        if firstTickTimestamp == 0 { firstTickTimestamp = frame.timestamp }
        updateTint(frame)
        updateAnchorPoses(frame)
        if frame.timestamp - lastMeshUpdate >= Self.meshUpdateInterval {
            lastMeshUpdate = frame.timestamp
            updateMeshes(frame)
        }
    }

    /// Cập nhật TƯ THẾ anchor mỗi tick (việc rẻ), tách khỏi việc dựng lại hình học (việc đắt,
    /// vẫn giữ nhịp `meshUpdateInterval`).
    ///
    /// ⚠ ĐỪNG ĐỌC ĐÂY NHƯ "BẢN VÁ CHỐNG RUNG". Đời đầu của hàm này mang một chú thích khẳng
    /// định rung là do pose bị hãm 0,5s — SAI, và review đối kháng đã bác: `ARMeshAnchor.transform`
    /// là gốc khối voxel trong world space, ARKit gán lúc tạo rồi gần như để yên; thứ nó cập
    /// nhật liên tục là HÌNH HỌC (đỉnh/mặt), không phải pose. Pose chỉ nhích ở các lần hiệu
    /// chỉnh trôi/khép vòng — rời rạc, biên độ dưới milimet, tức DƯỚI MỘT PIXEL.
    /// Giữ hàm này vì nó vẫn đúng và gần như miễn phí: sau một cú khép vòng, lưới bám lại vị
    /// trí đúng trong 1 khung thay vì tối đa 0,5 giây. Nhưng nó KHÔNG phải nguyên nhân rung —
    /// nguyên nhân thật xem chú thích ở đầu file.
    private func updateAnchorPoses(_ frame: ARFrame) {
        guard !anchorNodes.isEmpty || !maskNodes.isEmpty else { return }
        for anchor in frame.anchors {
            guard let mesh = anchor as? ARMeshAnchor else { continue }
            let id = mesh.identifier
            anchorNodes[id]?.simdTransform = mesh.transform
            maskNodes[id]?.simdTransform = mesh.transform
        }
    }

    // MARK: - Lớp phủ đỏ bám theo camera của ARSCNView

    /// 🔴 KHÔNG CÒN HÀM `updateCamera`. Đó là điểm mấu chốt của đợt gộp view: trước đây lớp
    /// phủ tự lái một camera SceneKit riêng bằng `frame.camera.viewMatrix` của khung MỚI NHẤT,
    /// trong khi ảnh nền do ARSCNView vẽ bằng khung mà NÓ đang xử lý → hai lớp lệch nhau 0–1
    /// khung và độ lệch đảo qua đảo lại = lưới rung khi lia máy. Nay lưới nằm trong scene của
    /// chính ARSCNView nên dùng chung `pointOfView` với ảnh nền: sai số đăng ký bằng 0 theo
    /// định nghĩa, không còn gì để lệch. ✗ ĐỪNG dựng lại camera riêng ở đây.
    ///
    /// Việc duy nhất còn lại là ĐẶT tấm phủ đỏ chắn ngang tầm nhìn và nới cho kín khung.
    ///
    /// 🔴 TẤM PHỦ LÀ CON CỦA `rootNode`, **KHÔNG** PHẢI CON CỦA `sceneView.pointOfView`.
    /// Đời đầu của bản gộp view gắn nó vào `pointOfView` cho "khỏi phải tự tính tư thế" — và
    /// TẤM PHỦ BIẾN MẤT HẲN (chủ app báo ngay 2026-07-29). Lý do: SceneKit chỉ vẽ cây con của
    /// `scene.rootNode`, mà node camera của ARSCNView do view tự quản và KHÔNG bảo đảm nằm
    /// trong cây đó — cha không được vẽ thì con cũng không. (Đời SCNView riêng không lộ vì lúc
    /// ấy chính code này `addChildNode(cameraNode)` vào scene của nó.)
    /// Nay tư thế tính tay từ ma trận camera của ARFrame: `viewMatrix(for:.portrait).inverse`
    /// là camera→world, nhân thêm phép tịnh tiến -Z một đoạn `distance` (đã kẹp theo mặt phẳng
    /// xa thật). Trễ một khung ở đây CHỊU ĐƯỢC — nhưng chỉ vì tấm phủ được nới dư theo
    /// `tintOversize` (đọc hằng số đó: 1.3, KHÔNG phải 1.05) và vì nó chỉ là một mảng màu
    /// phẳng — khác hẳn LƯỚI, thứ bắt buộc khớp từng pixel (xem chú thích đầu file).
    private func updateTint(_ frame: ARFrame) {
        // Hội tụ lại mỗi tick: rẻ (một phép gán Bool) và bảo đảm không đường nào quên gọi.
        refreshTintVisibility()
        guard let view = sceneView else { return }
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return }

        // KẸP theo mặt phẳng xa THẬT của camera đang render (xem chú ở `tintDistance`): vượt
        // nó là quad bị cắt sạch và tấm phủ biến mất không một dấu hiệu. `zFar` mặc định của
        // ARKit là 1000m nên thực tế không kẹp; đây là lưới an toàn, không phải tinh chỉnh.
        let far = Float(view.pointOfView?.camera?.zFar ?? 0)
        let distance = far > 1 ? min(Self.tintDistance, far * 0.8) : Self.tintDistance

        // Đặt tấm phủ cách camera `distance` theo hướng nhìn, cùng hướng xoay với camera.
        var offset = matrix_identity_float4x4
        offset.columns.3 = SIMD4<Float>(0, 0, -distance, 1)
        tintNode.simdTransform = frame.camera.viewMatrix(for: .portrait).inverse * offset

        // Bề rộng frustum tại khoảng cách d là 2d/m00 (m00 = projection[0][0]), cao là 2d/m11.
        // Nhân `tintOversize` cho dư mép — xem chú ở hằng số đó, dư quá ít là hở viền lúc lia.
        // Lấy m00/m11 từ ARFrame (chỉ phụ thuộc góc nhìn + tỉ lệ khung, KHÔNG phụ thuộc
        // zNear/zFar — nên hai số truyền vào đây không ràng buộc mặt phẳng xa thật, xem trên)
        // nên khớp với ma trận chiếu mà ARSCNView đang dùng.
        let projection = frame.camera.projectionMatrix(
            for: .portrait, viewportSize: size, zNear: 0.01, zFar: 50
        )
        let p00 = projection.columns.0.x
        let p11 = projection.columns.1.y
        if p00 > 0, p11 > 0 {
            // Gán scale SAU simdTransform: simdTransform vừa ghi đè cả phần scale.
            let halfSpan = 2 * Self.tintOversize * distance
            tintNode.simdScale = SIMD3(halfSpan / p00, halfSpan / p11, 1)
        }
    }

    // MARK: - Dựng lưới từ ARMeshAnchor (throttle; copy trên main, dựng geometry ở nền)

    private func updateMeshes(_ frame: ARFrame) {
        let c4 = frame.camera.transform.columns.3
        let camPos = SIMD3(c4.x, c4.y, c4.z)
        // Dọn anchor đã biến khỏi phiên TRƯỚC khi cộng sổ (pattern ColorMeshBuilder đã trả
        // giá — "đỉnh ma báo đầy oan"): ARKit GỘP anchor là bản thay thế xuất hiện CÙNG frame
        // với bản cũ biến mất. Cộng bản mới giữa vòng rồi cuối vòng mới trừ bản cũ thì
        // `maskVerts` vọt ma qua trần 2M → `disableMasking` oan, tint tắt lặng lẽ giữa phiên
        // trong khi banner "Mô hình đã đầy" (đếm theo builder, vốn dọn-trước-đếm-sau) không
        // hề hiện. Review vòng 2 (2026-07-29) bắt.
        let present = Set(frame.anchors.compactMap { ($0 as? ARMeshAnchor)?.identifier })
        for id in Array(anchorDists.keys) where !present.contains(id) {
            removeAnchor(id)
        }
        purgeDyingMasks(now: frame.timestamp)
        for anchor in frame.anchors {
            guard let mesh = anchor as? ARMeshAnchor else { continue }
            let id = mesh.identifier

            let a4 = mesh.transform.columns.3
            let dist = simd_distance(SIMD3(a4.x, a4.y, a4.z), camPos)
            anchorDists[id] = dist
            if anchorFirstSeen[id] == nil {
                anchorFirstSeen[id] = frame.timestamp
            }

            let vSource = mesh.geometry.vertices
            let fElement = mesh.geometry.faces
            let sig = MeshSig(v: vSource.count, f: fElement.count)

            // 1. Mặt nạ depth: MỌI anchor đều có (trừ khi ngân sách mask đã cạn) — kể cả
            //    anchor không được hiển thị lưới. Đây chính là chỗ tách "tín hiệu chưa quét"
            //    khỏi trần hiển thị (xem chú ở `maskNodes`).
            if !maskingDisabled {
                let mask: SCNNode
                if let existing = maskNodes[id] {
                    mask = existing
                } else {
                    mask = SCNNode()
                    mask.renderingOrder = Self.maskRenderingOrder
                    rootNode.addChildNode(mask)
                    maskNodes[id] = mask
                }
                mask.simdTransform = mesh.transform
            }

            // 2. Node lưới hiển thị — trần `maxVerts` như cũ. Vùng MỚI khi đã chạm trần: chỉ
            //    nhận nếu nhả được các vùng XA HƠN để lấy chỗ — lưới "đi theo" người quét thay
            //    vì tắt hẳn (lỗi cũ: quét lâu là mất lưới). KHÔNG `continue` khi bị từ chối:
            //    anchor không hiển thị vẫn phải đi tiếp xuống bước dựng geometry cho mask.
            var node = anchorNodes[id]
            if node == nil {
                let need = anchorSigs[id]?.v ?? sig.v
                if totalVerts + need <= maxVerts || evictFarther(than: dist, toFit: need) {
                    let created = SCNNode()
                    rootNode.addChildNode(created)
                    anchorNodes[id] = created
                    node = created
                    // Vào sổ NGAY khi node hiển thị ra đời — bất kể cache đã có hay chưa.
                    // Review vòng 2: cộng sổ bên trong `if let cached` thì anchor được nhận
                    // lại giữa lúc bản dựng ĐẦU TIÊN còn bay (cache chưa ghi) sẽ hiển thị
                    // NGOÀI SỔ (completion vẫn gán geometry vì node tồn tại) → totalVerts
                    // trôi ÂM vĩnh viễn mỗi lần dính, trần 600k mòn dần. Anchor mới toanh có
                    // anchorSigs nil → cộng 0, bước 3 cộng đủ sau.
                    totalVerts += anchorSigs[id]?.v ?? 0
                    // Anchor từng bị nhả khỏi trần nay được nhận lại: gán lại geometry từ
                    // cache ngay — sig không đổi thì bước 3 sẽ không rebuild cho nó nữa.
                    if let cached = wireGeos[id] {
                        created.geometry = cached
                    }
                }
            }
            // Pose cập nhật mỗi lần (rẻ). Hình học chỉ dựng lại khi ĐỔI và không đang dựng dở.
            node?.simdTransform = mesh.transform

            // 3. Dựng lại geometry khi anchor ĐỔI — chạy cho cả anchor chỉ-có-mask.
            let vLen = vSource.stride * vSource.count
            guard anchorSigs[id] != sig,
                  !inFlight.contains(id),
                  vSource.count > 0, fElement.count > 0, fElement.indexCountPerPrimitive == 3,
                  vSource.offset + vLen <= vSource.buffer.length
            else { continue }
            // Sổ đỉnh HIỂN THỊ chỉ cộng khi anchor đang có node lưới; sổ MASK cộng cho mọi
            // anchor (mask không bị evict nên ledger = tổng sig của maskNodes, không drift).
            if node != nil {
                totalVerts += sig.v - (anchorSigs[id]?.v ?? 0)
            }
            if !maskingDisabled {
                maskVerts += sig.v - (anchorSigs[id]?.v ?? 0)
                if maskVerts > Self.maskMaxVerts {
                    disableMasking()
                }
            }
            anchorSigs[id] = sig
            inFlight.insert(id)
            if countingRebuild { rebuildBatch.insert(id) }

            // Copy NHANH trên main (ARKit tái dụng MTLBuffer nên phải copy ngay tại đây)…
            let vBytes = Data(bytes: vSource.buffer.contents().advanced(by: vSource.offset), count: vLen)
            let iBytes = Data(bytes: fElement.buffer.contents(), count: fElement.buffer.length)
            let vCount = vSource.count
            let vStride = vSource.stride
            let fCount = fElement.count
            let bpi = fElement.bytesPerIndex
            // Transform chốt CÙNG LÚC với buffer — luồng nền tính voxel-key coverage theo
            // world mà không phải đọc lại anchor (item 2).
            let anchorTf = mesh.transform

            // …rồi DỰNG geometry ở nền, gán lại trên main. Nhờ vậy main thread không bị chiếm
            // → ARKit/RoomPlan không rớt frame (trước đây gây "đứng lại" + hủy bản quét + crash).
            buildQueue.async {
                let built = Self.makeGeometries(
                    vBytes: vBytes, vCount: vCount, vStride: vStride,
                    iBytes: iBytes, faceCount: fCount, bytesPerIndex: bpi,
                    transform: anchorTf
                )
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.inFlight.remove(id)   // luôn giải phóng dù dựng được hay không
                    // 🔴 TRỪ SỔ ĐỢT DỰNG LẠI VÔ ĐIỀU KIỆN, TRƯỚC MỌI `guard`. Bản dựng hỏng
                    // (`makeGeometries` trả nil khi lưới rỗng/chỉ số rác) hay anchor đã chết
                    // thì nó KHÔNG BAO GIỜ khoét được gì nữa — để id nằm lại trong sổ là cổng
                    // tấm phủ đỏ KẸT ĐÓNG tới hết phiên và người quét mất hẳn tín hiệu "chưa
                    // quét", im lặng, không báo gì. Đặt sau `guard` là đúng cái bẫy đó.
                    if self.rebuildBatch.remove(id) != nil,
                       self.rebuildBatch.isEmpty, !self.countingRebuild {
                        self.openCarveGate()
                    }
                    guard let built else { return }
                    // Anchor đã bị removeAnchor trong lúc bản dựng còn bay → DỪNG Ở ĐÂY,
                    // đừng cache: `wireGeos[id]` hồi sinh lúc này là entry mồ côi giữ
                    // geometry tới hết phiên (id đã rời anchorDists nên vòng dọn không bao
                    // giờ ghé lại — review vòng 2 bắt). `anchorSigs` sống qua evictWire
                    // nhưng chết ở removeAnchor nên nó chính là cờ "anchor còn sổ".
                    guard self.anchorSigs[id] != nil else { return }
                    // Cache lưới cho lần NHẬN LẠI sau khi bị nhả khỏi trần hiển thị — kể cả
                    // khi anchor hiện không có node lưới (bị trần từ chối lúc lên lịch dựng).
                    self.wireGeos[id] = built.wire
                    // Key coverage TƯƠI theo geometry mới; bỏ memo "đã phủ" của anchor này —
                    // anchor PHÌNH sang vùng chưa chụp mà giữ memo là trắng nói dối đúng
                    // chỗ đang quét dở. retint nhịp kế (≤0.5s) đo lại bằng key mới.
                    self.anchorCoverageKeys[id] = built.coverageKeys
                    self.coveredAnchors.remove(id)
                    if let node = self.anchorNodes[id] {
                        // Chọn vật liệu NGAY khi gán geometry mới — không đợi retint 0.5s.
                        // (makeGeometries gán trắng mặc định; anchor ĐỎ đang được ARKit cập
                        // nhật liên tục sẽ chớp trắng↔đỏ ~2Hz nếu chỉ dựa vào retint —
                        // đúng lúc người quét cần tín hiệu "chưa ghi" tin cậy nhất.)
                        if let recorded = self.recordedCounts?() {
                            built.wire.materials = [self.materialFor(id, recorded: recorded)]
                        }
                        node.geometry = built.wire
                    }
                    self.maskNodes[id]?.geometry = built.mask
                    // NGOÀI một đợt dựng đang chờ: mask có hình học là mở cổng ngay. Ca này
                    // xảy ra khi anchor MỚI xuất hiện lúc quét bình thường (đợt trước đã rút
                    // hết) — lúc đó cổng vốn đã mở nên `openCarveGate` là no-op; nó chỉ thật sự
                    // mở ở ca đợt đầu rỗng anchor rồi mới có anchor đầu tiên.
                    if self.rebuildBatch.isEmpty, !self.countingRebuild {
                        self.openCarveGate()
                    }
                }
            }
        }
        // ĐÓNG SỔ đợt dựng lại ngay cuối lượt ĐẦU sau `releaseAll`: từ lượt sau, anchor mới
        // sinh trong lúc quét không được nối thêm vào đợt (không thì cổng không bao giờ mở).
        if countingRebuild {
            countingRebuild = false
        }
        // KHÔNG XẾP ĐƯỢC BẢN DỰNG NÀO (chưa anchor nào tồn tại) — chú thích đời trước gộp ca này
        // làm một và mở cổng NGAY ("phủ đỏ khắp nơi là ĐÚNG SỰ THẬT"). Đúng về ngữ nghĩa, sai về
        // trải nghiệm, vì thực tế nó là HAI ca khác hẳn nhau:
        //  · MỚI BẤM QUÉT: ARKit đang khởi động (camera+LiDAR bật, VIO định vị ~1,6s đo được ở
        //    §STATE 10/08, rồi mới sinh mảnh mesh đầu) — tổng 2–4s. Mở cổng ở đây là tô ĐỎ KÍN
        //    2–4 giây đầu của MỌI buổi quét: khách chưa làm gì sai, chưa hụt chỗ nào, mà màn hình
        //    đã báo động và che 86% hình camera đúng lúc họ cần nhìn để nhắm máy. Chính là thứ
        //    chủ app báo 13/08 ("bấm quét 4 giây mới hiện lưới"). Trong quãng này tấm phủ IM, và
        //    `MeshScanFlowView` lấp chỗ trống bằng đếm ngược 3-2-1.
        //  · PHÒNG THẬT SỰ KHÔNG QUÉT ĐƯỢC GÌ (tối om, toàn kính): quá `warmupGraceSec` mà vẫn
        //    trắng tay thì đỏ khắp nơi lại ĐÚNG SỰ THẬT — phải nói, ✗ im luôn. Đó là lý do khối
        //    này chạy MỖI NHỊP chứ không nằm trong `if countingRebuild` (cờ đó chỉ đúng một lượt;
        //    nhét vào đấy là ca này không bao giờ được xét lại và tấm phủ chết vĩnh viễn).
        // 🔴 ✗ ĐỔI ĐIỀU KIỆN THÀNH `maskNodes.isEmpty`: mask được tạo RỖNG ở bước 1, TRƯỚC cổng
        // hình học ở bước 3 — anchor 0 tam giác (đúng trạng thái ARKit lúc khởi động) làm sổ mask
        // khác rỗng trong khi KHÔNG có gì khoét → đỏ kín y như cũ, mà lần này khó thấy hơn.
        // Đường mở cổng BÌNH THƯỜNG vẫn là hai chỗ trong completion của bản dựng (batch rút hết /
        // mask vừa nhận hình học) — cái ở đây chỉ là lưới cuối cho ca không-có-gì-để-dựng.
        // ⚠ `inFlight.isEmpty` KHÔNG mâu thuẫn với cảnh báo "✗ GÁC BẰNG `inFlight.isEmpty`" ở
        // `rebuildBatch`: cảnh báo đó nói về đường mở cổng LÚC QUÉT BÌNH THƯỜNG, khi ARKit cập nhật
        // anchor liên tục nên `inFlight` gần như luôn khác rỗng ⇒ gác kiểu đó là tấm phủ nhấp nháy
        // cả buổi. Ở ĐÂY khác hẳn: lưới cuối này chỉ chạy sau 6 giây TRẮNG TAY, và cổng MỘT CHIỀU
        // nên thêm điều kiện chỉ HOÃN được, ✗ tạo được đường bật/tắt. Có bản dựng đang bay nghĩa là
        // vừa tìm ra bề mặt thật — để completion mở cổng với mặt nạ ĐÃ khoét, thay vì đỏ kín màn
        // 0,1–1,5s rồi mới thủng đúng chỗ khách vừa quét được.
        if !hasCarvingMask, rebuildBatch.isEmpty, inFlight.isEmpty, !countingRebuild,
           frame.timestamp - firstTickTimestamp >= Self.warmupGraceSec {
            openCarveGate()
        }
        // (Việc dọn anchor vắng mặt đã chạy ở ĐẦU hàm — trước mọi phép cộng sổ, xem chú ở đó.)
        // Anchor cũ phình to có thể đẩy tổng vượt trần → tỉa vùng XA camera nhất
        trimOverCap()
        // Tô lưới theo trạng thái GHI THẬT (trắng = đã vào file, đỏ = chưa)
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
    ///
    /// Item 2 (03/08): thêm lượt GIẤU/HIỆN theo ảnh chụp. Anchor "sẽ trắng" (đã ghi hoặc
    /// đang ân hạn) mà CHƯA đủ ảnh → ẩn cả node lưới LẪN mask depth: phủ đỏ hiện lại =
    /// "chưa xong chỗ này" (chủ app chọn không thêm màu). Anchor ĐỎ không bao giờ bị giấu —
    /// vai mất-dữ-liệu phải luôn nhìn thấy. Đi theo SỔ MASK (superset: anchor bị evict
    /// wire vẫn còn mask đang khoét phủ đỏ — mask trắng oan là vùng thiếu ảnh trông như
    /// xong). Khi `maskingDisabled` (mô hình đầy, tint đã tắt hẳn) coverage NGỪNG áp:
    /// giấu lưới lúc không còn tấm phủ chỉ làm mất nốt tín hiệu — `disableMasking` đã
    /// hiện lại mọi node.
    private func retintForRecording() {
        guard let recorded = recordedCounts?() else { return }
        for (id, node) in anchorNodes {
            guard let geometry = node.geometry else { continue }
            let material = materialFor(id, recorded: recorded)
            if geometry.firstMaterial !== material {
                geometry.materials = [material]
            }
        }
        guard !maskingDisabled, let grid = photoCoverage?() else { return }
        for (id, mask) in maskNodes {
            let wouldBeWhite = materialFor(id, recorded: recorded) === Self.wireframeMaterial
            let hide = wouldBeWhite && !coveredForPhotos(id, grid: grid)
            if mask.isHidden != hide { mask.isHidden = hide }
            if let node = anchorNodes[id], node.isHidden != hide { node.isHidden = hide }
        }
    }

    /// "Đã đủ ảnh" cho một anchor — memo một chiều + ân hạn dùng CHUNG mốc `anchorFirstSeen`
    /// với vai đỏ (anchor mới có 1.5s để ảnh kịp lưu, không thì mọi lưới mới đều chớp
    /// ẩn→hiện). Chưa có key mẫu (bản dựng đầu còn bay) = coi như đủ — thà trắng sớm 0.5–1.5s
    /// còn hơn chớp; key về là nhịp sau đo thật.
    private func coveredForPhotos(_ id: UUID, grid: TextureCoverageGrid) -> Bool {
        if coveredAnchors.contains(id) { return true }
        if lastFrameTimestamp - (anchorFirstSeen[id] ?? lastFrameTimestamp) < 1.5 {
            return true
        }
        guard let keys = anchorCoverageKeys[id], !keys.isEmpty else { return true }
        let need = max(1, Int((Float(keys.count) * Self.coverageMinFraction).rounded(.up)))
        if grid.containedCount(of: keys) >= need {
            coveredAnchors.insert(id)
            return true
        }
        return false
    }

    /// Nhả PHẦN LƯỚI của các vùng XA camera hơn `dist` (xa nhất trước) cho tới khi đủ chỗ cho
    /// `needed` đỉnh. Trả về false nếu nhả hết vẫn không đủ (vùng mới xa hơn mọi vùng đang giữ
    /// → bỏ qua, nhờ vậy vùng vừa bị nhả không bị nhận lại ngay — không giật qua lại).
    /// 🔴 CHỈ nhả wire (`evictWire`), KHÔNG đụng mask — nhả mask là lớp phủ đỏ nói dối
    /// "chưa quét tới" trên vùng đã vào file (finding review 2026-07-29, 5 lens cùng bắt).
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
        for id in victims { evictWire(id) }
        return true
    }

    private func trimOverCap() {
        while totalVerts > maxVerts {
            guard let far = anchorDists
                .filter({ anchorNodes[$0.key] != nil })
                .max(by: { $0.value < $1.value })
            else { break }
            evictWire(far.key)
        }
    }

    /// Nhả riêng PHẦN LƯỚI HIỂN THỊ của một anchor (trần GPU). Mask + sig + cache geometry
    /// giữ nguyên: anchor vẫn khoét lớp phủ đỏ, và khi được nhận lại thì gán từ cache.
    /// KHÔNG đụng `inFlight` — bản dựng đang chạy cứ chạy, completion tự xử lý node nil.
    private func evictWire(_ id: UUID) {
        guard let node = anchorNodes.removeValue(forKey: id) else { return }
        node.removeFromParentNode()
        totalVerts -= anchorSigs[id]?.v ?? 0
    }

    /// Gỡ SẠCH một anchor đã biến khỏi phiên (ARKit gộp/tách anchor liên tục).
    private func removeAnchor(_ id: UUID) {
        evictWire(id)
        if let mask = maskNodes.removeValue(forKey: id) {
            // KHÔNG removeFromParentNode ngay — treo vào hàng ân hạn (xem `dyingMasks`).
            // Sổ `maskVerts` trừ NGAY để ngân sách không phụ thuộc hàng chờ; 1.5s render
            // ngoài sổ của một anchor sắp chết là sai số chấp nhận được.
            maskVerts -= anchorSigs[id]?.v ?? 0
            dyingMasks.append((node: mask, deadline: lastFrameTimestamp + Self.maskLingerSec))
        }
        wireGeos.removeValue(forKey: id)
        anchorSigs.removeValue(forKey: id)
        anchorCoverageKeys.removeValue(forKey: id)
        coveredAnchors.remove(id)
        // Anchor chết giữa đợt dựng lại vẫn phải rời sổ, không thì cổng tấm phủ kẹt mãi —
        // và nếu nó là thành viên CUỐI thì phải mở cổng luôn tại đây, vì sẽ không còn
        // completion nào về để làm việc đó.
        if rebuildBatch.remove(id) != nil, rebuildBatch.isEmpty, !countingRebuild {
            openCarveGate()
        }
        anchorDists.removeValue(forKey: id)
        anchorFirstSeen.removeValue(forKey: id)
        // Nhả luôn cờ đang-dựng: nếu anchor được nhận lại ngay, bản dựng mới không bị chặn.
        // (Queue nền serial + main FIFO nên bản dựng mới luôn gán SAU bản cũ — không lo ngược thứ tự.)
        inFlight.remove(id)
    }

    /// Gỡ các mask đã hết ân hạn. Gọi mỗi nhịp updateMeshes (0.5s) — độ trễ tối đa
    /// 1.5+0.5s vẫn nhỏ so với việc chớp đỏ trên vùng đã lưu.
    private func purgeDyingMasks(now: TimeInterval) {
        guard !dyingMasks.isEmpty else { return }
        var kept: [(node: SCNNode, deadline: TimeInterval)] = []
        for entry in dyingMasks {
            if now >= entry.deadline {
                entry.node.removeFromParentNode()
            } else {
                kept.append(entry)
            }
        }
        dyingMasks = kept
    }

    /// Ngân sách mask cạn (mô hình vượt trần xuất 2M — banner "Mô hình đã đầy" của
    /// MeshScanFlowView cũng đã hiện từ trước đó): tắt HẲN lớp phủ đỏ cho hết phiên,
    /// thay vì tiếp tục hiện một tín hiệu bắt đầu nói dối vì thiếu mask. Một chiều.
    private func disableMasking() {
        maskingDisabled = true
        refreshTintVisibility()
        for (_, node) in maskNodes {
            node.removeFromParentNode()
        }
        maskNodes.removeAll()
        for entry in dyingMasks {
            entry.node.removeFromParentNode()
        }
        dyingMasks.removeAll()
        // Item 2: coverage ngừng áp từ đây (tint đã tắt, giấu lưới chỉ mất nốt tín hiệu) —
        // HIỆN LẠI node đã giấu, không thì cờ isHidden mắc kẹt vĩnh viễn (vòng giấu/hiện
        // trong retint đi theo sổ mask, mà sổ vừa bị xoá sạch).
        for node in anchorNodes.values where node.isHidden {
            node.isHidden = false
        }
    }

    /// Dựng CẶP geometry từ dữ liệu ĐÃ copy (chạy ở luồng nền — không đụng buffer của ARKit
    /// nữa): `wire` là lưới nhìn thấy, `mask` là bản fill chỉ-ghi-depth để khoét lớp phủ đỏ.
    /// Hai geometry DÙNG CHUNG source/element (bất biến, SceneKit cho phép chia sẻ) nên bản
    /// thứ hai gần như miễn phí về bộ nhớ.
    /// `coverageKeys` (item 2): ~32 đỉnh mẫu rải đều → world qua `transform` → voxel-key,
    /// tính luôn ở nền để main chỉ còn tra Set khi đo "đã đủ ảnh".
    private static func makeGeometries(
        vBytes: Data, vCount: Int, vStride: Int,
        iBytes: Data, faceCount: Int, bytesPerIndex: Int,
        transform: simd_float4x4
    ) -> (wire: SCNGeometry, mask: SCNGeometry, coverageKeys: [Int64])? {
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

        var coverageKeys: [Int64] = []
        let sampleStep = max(1, verts.count / 32)
        var si = sampleStep / 2
        while si < verts.count {
            let v = verts[si]
            let w = transform * SIMD4<Float>(v.x, v.y, v.z, 1)
            if w.x.isFinite, w.y.isFinite, w.z.isFinite {
                coverageKeys.append(TextureCoverageGrid.key(SIMD3(w.x, w.y, w.z)))
            }
            si += sampleStep
        }

        let element = SCNGeometryElement(
            data: iBytes, primitiveType: .triangles,
            primitiveCount: faceCount, bytesPerIndex: bytesPerIndex
        )
        let source = SCNGeometrySource(vertices: verts)
        let wire = SCNGeometry(sources: [source], elements: [element])
        wire.materials = [Self.wireframeMaterial]
        let mask = SCNGeometry(sources: [source], elements: [element])
        mask.materials = [Self.depthMaskMaterial]
        return (wire: wire, mask: mask, coverageKeys: coverageKeys)
    }
}

// `MeshOverlayRepresentable` ĐÃ GỠ (2026-07-29). Lớp phủ không còn là một view riêng chồng
// lên hình camera — nó là các node nằm TRONG scene của ARSCNView, do
// `ARCameraViewRepresentable` dựng và nuôi. Xem chú thích đầu file để biết vì sao.
