import SwiftUI

/// Thanh % cho màn "Đang dựng mô hình 3D…" sau khi bấm Dừng & Lưu.
/// Chủ app 10/08: *"sau khi quét xong nó bảo chờ 1 lát thì nên hiển thị kiểu thanh chạy theo
/// kiểu % … chứ đừng ghi 1 lát làm khách hàng mất kiên nhẫn."*
///
/// 🔴 TOÀN BỘ FILE NÀY LÀ ĐỒ ĐO, KHÔNG PHẢI ĐƯỜNG DỮ LIỆU. Không byte nào của bản giao
/// (`model-colored.zip` và ruột của nó, `colored-mesh.ply`, `scan-video.mp4`,
/// `camera-track.json`, `texture-shots/`, `mesh-preview.bin`) được phép phụ thuộc vào nó.
/// Mọi hàm xuất chỉ NHẬN THÊM một closure báo số và gọi nó ở vài mốc; xoá hết các lời gọi đó
/// đi là code chạy y hệt bản 1.4. Ai thấy mình đang đọc `ScanSaveProgress` để QUYẾT ĐỊNH một
/// việc gì (bỏ bước, đổi thứ tự, chọn định dạng) thì đã đi sai đường.

/// Một CHẶNG của "Dừng & Lưu", theo ĐÚNG thứ tự chạy thật:
/// `MeshScanController.stopAndExport` (3 chặng đầu) rồi `ScanStore.saveMeshScan` (3 chặng sau).
///
/// 🔴 `rawValue` LÀ THỨ TỰ CHẠY, và `ScanSaveProgress` dựa vào đó để không bao giờ lùi nhãn:
/// báo cáo đi từ luồng nền qua `Task { @MainActor }` nên hoàn toàn có thể tới SAU khi chặng
/// kế đã bắt đầu. ✗ chèn case vào giữa hay đánh lại số nếu không rà lại cả chuỗi gọi.
enum SaveStage: Int, CaseIterable, Sendable {
    /// `recorder.finish()` (đóng file .mp4) + `texShots.finish()` (nén nốt ≤3 ảnh + shots.json).
    case finishingCapture = 0
    /// `ColorMeshBuilder.exportColoredPLY`: gộp mảnh → (chia tam giác + bake màu, chỉ đường
    /// KHÔNG lưu-nhanh) → ghi ~100MB PLY.
    case buildingMesh = 1
    /// `ColorMeshBuilder.exportPreviewMesh` — `mesh-preview.bin` cho trình xem 3D trong app.
    case previewMesh = 2
    /// `ColoredMeshPLY.parse` ở đầu `makeOBJZip` (đọc lại PLY vừa ghi).
    case readingMesh = 3
    /// `ColoredOBJExporter.writeOBJ` (+ GLB khi có màu-đỉnh).
    case writingModel = 4
    /// Chép `texture-shots/` + `zipDirectory` (NSFileCoordinator `.forUploading`).
    case packaging = 5

    /// 🔴 TRỌNG SỐ LÀ ƯỚC LƯỢNG THEO CẤU TRÚC, **CHƯA AI BẤM GIỜ TRÊN MÁY THẬT** —
    /// SESSION-HANDOFF §Nhả bộ nhớ lúc lưu vẫn ghi "Chưa ai ĐO thời gian lưu thật trên máy".
    /// Cơ sở của bộ số dưới đây, cho ĐƯỜNG THƯỜNG (lưu nhanh, nhà nguyên căn ~2,5 triệu đỉnh):
    /// đóng video/ảnh vài giây · dựng+ghi PLY và ghi OBJ là hai vòng lặp hàng triệu bước ·
    /// đọc lại PLY là một lượt quét 100MB · nén là DEFLATE ~300MB.
    /// ⇒ Lần đầu chạy trên máy thật: bấm giờ TỪNG NHÃN chặng rồi chỉnh đúng bảng này,
    /// KHÔNG cần đụng chỗ nào khác.
    /// ⚠ Đường KHÔNG lưu-nhanh (<30 ảnh texture) dồn gần hết thời gian vào `.buildingMesh`
    /// (bake màu 150 triệu vòng lọc) nên bảng này lệch hẳn — chấp nhận: đó là đường phao.
    var weight: Double {
        switch self {
        case .finishingCapture: return 8
        case .buildingMesh: return 42
        case .previewMesh: return 5
        case .readingMesh: return 6
        case .writingModel: return 24
        case .packaging: return 15
        }
    }

    /// Mốc đầu của chặng trên thanh 0…1 (tổng `weight` = 100 — kiểm bằng `Self.allCases`).
    var start: Double {
        var sum = 0.0
        for stage in SaveStage.allCases where stage.rawValue < rawValue {
            sum += stage.weight
        }
        return sum / 100
    }

    /// `min(1, …)`: cộng dồn số thực có thể cho 1.0000000000000002 ở chặng cuối, và một
    /// `ProgressView(value:)` vượt `total` là hành vi không ai muốn phải đi tra.
    var end: Double { min(1, start + weight / 100) }

    /// Chặng KHÔNG tự báo được phần trăm bên trong → thanh đứng yên suốt chặng, và màn hình
    /// hiện thêm một vòng xoay nhỏ để khách biết máy vẫn đang chạy.
    /// 🔴 ✗ "chữa" bằng cách cho thanh tự bò theo thời gian: đó là bịa số, và khi nó bò tới
    /// mốc rồi đứng lại thì khách mất tin vào cả thanh. Chỗ tệ nhất là `.packaging`
    /// (`NSFileCoordinator(.forUploading)` KHÔNG có API tiến độ nào cả) — nếu muốn nó chạy
    /// thật thì phải đổi bộ nén, mà đổi bộ nén là đổi FILE GIAO. ✗ làm.
    var showsSpinner: Bool {
        switch self {
        case .buildingMesh, .writingModel: return false
        case .finishingCapture, .previewMesh, .readingMesh, .packaging: return true
        }
    }

    /// Nhãn NGẮN cho khách — nói việc đang làm, ✗ tên file/tên hàm.
    var label: String {
        switch self {
        case .finishingCapture: return L.t("Finishing the video…", "Đang hoàn tất video…")
        // ✗ "Đang dựng mô hình 3D…" ở đây: đó là TIÊU ĐỀ cố định của màn chờ, lặp lại là
        // khách nhìn thấy đúng một câu hai lần suốt 40% thời gian.
        case .buildingMesh: return L.t("Merging the mesh…", "Đang gom lưới…")
        case .previewMesh: return L.t("Preparing the 3D preview…", "Đang tạo bản xem nhanh…")
        case .readingMesh: return L.t("Preparing the file…", "Đang chuẩn bị tệp…")
        case .writingModel: return L.t("Writing the 3D file…", "Đang ghi tệp 3D…")
        case .packaging: return L.t("Compressing…", "Đang nén gói dữ liệu…")
        }
    }
}

/// Đường báo tiến độ từ luồng NỀN về màn hình.
///
/// 🔴 CỐ Ý LÀ MỘT CLOSURE `@Sendable` TRẦN, ✗ tham chiếu tới `ColorMeshBuilder`/`ScanStore`.
/// Vòng lưu có kỷ luật bộ nhớ rất chặt (§Nhả bộ nhớ lúc lưu): kho khung màu phải CHẾT trước
/// khi cấp phát `Data` của PLY. Một closure giữ builder (hay `pieces`/`keyframes`/
/// `SamplerStore`) sẽ kéo dài tuổi thọ của chúng qua đúng đỉnh RAM đó — đúng cái bẫy mà
/// `SamplerStore` sinh ra để tránh. Closure này chỉ giữ MỘT `weak` tới hộp số ~40 byte.
typealias SaveStageReport = @Sendable (SaveStage, Double) -> Void

/// Hộp số cho thanh %. Sống trong `MeshScanFlowView` (`@StateObject`), chết cùng màn quét.
///
/// BẤT BIẾN: `fraction` chỉ TĂNG, `stage` chỉ ĐI TỚI. Báo cáo tới muộn (hoặc lệch thứ tự vì
/// mỗi lần báo là một `Task` riêng) chỉ bị bỏ qua, không bao giờ kéo thanh lùi.
@MainActor
final class ScanSaveProgress: ObservableObject {
    @Published private(set) var fraction: Double = 0
    @Published private(set) var stage: SaveStage = .finishingCapture

    /// Ngưỡng công bố. Màn hình chỉ hiện SỐ NGUYÊN phần trăm nên nhích dưới 0,4% là re-render
    /// không ai thấy — mà mỗi lần re-render là một lượt dựng lại body của `MeshScanFlowView`
    /// (kéo theo `updateUIView` của ARSCNView). Chặn ở đây giữ cả buổi lưu dưới ~250 lượt.
    private static let publishStep = 0.004

    /// `localFraction` là 0…1 TRONG chặng; hộp này lo việc quy về thang chung.
    func report(_ stage: SaveStage, _ localFraction: Double) {
        let clamped = min(max(localFraction, 0), 1)
        let value = min(stage.end, stage.start + clamped * (stage.end - stage.start))
        let movedOn = stage.rawValue > self.stage.rawValue
        // ✗ bỏ vế `movedOn`: chặng mới bắt đầu ở đúng mốc kết của chặng cũ nên `value` bằng
        // `fraction`, không qua nổi ngưỡng công bố — nhãn sẽ kẹt ở chặng trước tới khi có
        // báo cáo đủ lớn, mà chặng câm (`showsSpinner`) thì không bao giờ có.
        guard movedOn || value >= fraction + Self.publishStep else { return }
        if movedOn { self.stage = stage }
        fraction = max(fraction, value)
    }

    /// Gọi trước mỗi lần lưu. Hôm nay view chỉ lưu một lần trong đời nên đây là dây an toàn
    /// cho đường "Quét thêm" nếu sau này ai đó dùng lại cùng một view.
    func reset() {
        fraction = 0
        stage = .finishingCapture
    }

    /// Đầu thu để trao cho các hàm xuất chạy nền.
    /// `weak self`: closure này bị giữ suốt vòng lưu (trong `queue.async` của builder và trong
    /// `Task.detached` nén zip) — giữ mạnh thì màn quét bị đóng giữa chừng vẫn kéo hộp số sống
    /// tới hết. Hộp chết thì báo cáo rơi vào hư không, đúng ý.
    nonisolated func reporter() -> SaveStageReport {
        { [weak self] stage, value in
            // `Task { @MainActor in … }` chứ ✗ `DispatchQueue.main.async`: khuôn đã dùng ở
            // `AddressCompleter` (callback nonisolated của MapKit) và compile sạch ở CI này.
            // `guard let self` (✗ `self?.report(…)`) để thân Task là NHIỀU câu lệnh: closure
            // một-biểu-thức trả `()?` sẽ suy ra `Task<Void?, Never>` — chạy đúng nhưng là loại
            // suy diễn không ai muốn phải đọc lại.
            Task { @MainActor in
                guard let self else { return }
                self.report(stage, value)
            }
        }
    }
}
