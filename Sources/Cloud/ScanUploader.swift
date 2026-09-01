import Foundation

/// Điều phối việc gửi 1 bản quét lên server Cedar247:
/// tạo scan → PUT từng file lên R2 (có tiến độ) → báo hoàn tất.
@MainActor
final class ScanUploader: ObservableObject {
    enum Phase: Equatable {
        case idle
        case preparing
        case uploading(fileName: String, index: Int, total: Int, fraction: Double)
        case finishing
        case done
        case failed(String)
    }

    @Published var phase: Phase = .idle

    /// 🔴 Ba loại của RoomPlan/video đã BỎ 11/08 (bản 2.5): `usdz`/`model.usdz`,
    /// `plan`/`floorplan.png`, `rooms`/`rooms.json`. Luồng mesh KHÔNG BAO GIỜ sinh ba file đó, mà
    /// `present` bên dưới đã lọc theo `fileExists` — nên bỏ chúng khỏi danh sách là **no-op với
    /// mọi bản quét đang tạo được**, ✗ đổi hợp đồng app↔server (server vẫn nhận `kinds` bất kỳ).
    /// ⚠ Bản quét CŨ trên máy có `model.usdz`/`floorplan.png` thì nay ba file đó KHÔNG được gửi
    /// lên nữa. Chấp nhận có chủ đích: đội vẽ đọc mesh trong `objzip`, và chủ app là người duy
    /// nhất còn giữ bản quét đời RoomPlan.
    static let fileKinds: [(kind: String, fileName: String)] = [
        ("obj", "model.obj"),
        ("mtl", "model.mtl"),
        ("mesh", "colored-mesh.ply"),
        ("objzip", "model-colored.zip"),   // mô hình màu OBJ+MTL đã nén
        ("video", "scan-video.mp4"),
    ]

    /// Trả về cloudScanId khi thành công, nil khi thất bại (phase = .failed).
    func upload(record: ScanRecord, folder: URL) async -> String? {
        phase = .preparing
        let fm = FileManager.default

        let present = Self.fileKinds.filter { fm.fileExists(atPath: folder.appendingPathComponent($0.fileName).path) }
        // Bản quét mesh có thể chỉ có model-colored.zip (objzip) hoặc PLY phao (video recorder
        // fail lặng lẽ vẫn upload được) — nên chấp nhận bất kỳ cái nào trong bốn.
        // (Vế `$0.kind == "usdz"` bỏ cùng RoomPlan 11/08.)
        guard present.contains(where: {
            $0.kind == "obj" || $0.kind == "video" || $0.kind == "mesh" || $0.kind == "objzip"
        }) else {
            phase = .failed(String(localized: "No scan files found for this scan."))
            return nil
        }

        // Báo cáo chất lượng (nếu có) gửi kèm ngay lúc tạo scan — đội vẽ thấy trên Kanban
        var quality: [String: Any]?
        if let data = try? Data(contentsOf: folder.appendingPathComponent("quality.json")),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            quality = obj
        }

        do {
            let created = try await APIClient.shared.createScan(
                name: record.name,
                roomCount: record.roomCount,
                areaSqm: record.areaSqm ?? 0,
                kinds: present.map(\.kind),
                // 🔴 CẮM CỨNG "mesh", ✗ đọc `ScanRecord` nữa: trường `captureType` đã xoá khỏi
                // model 11/08 cùng RoomPlan (lý do đầy đủ ở cuối `ScanRecord.swift`). Đây là
                // trường của HỢP ĐỒNG app↔server nên VẪN PHẢI GỬI — bỏ nó là đổi hợp đồng, phải
                // đi đường "SERVER TRƯỚC". Mọi bản quét app tạo ra từ 2026-07-20 đều là "mesh".
                captureType: "mesh",
                quality: quality
            )
            let slotByKind = Dictionary(uniqueKeysWithValues: created.uploads.map { ($0.kind, $0) })

            for (index, file) in present.enumerated() {
                guard let slot = slotByKind[file.kind] else { continue }
                let fileURL = folder.appendingPathComponent(file.fileName)
                phase = .uploading(fileName: file.fileName, index: index + 1, total: present.count, fraction: 0)
                try await APIClient.shared.uploadFile(
                    at: fileURL,
                    to: slot.putUrl,
                    contentType: slot.contentType
                ) { [weak self] fraction in
                    self?.phase = .uploading(fileName: file.fileName, index: index + 1, total: present.count, fraction: fraction)
                }
            }

            phase = .finishing
            _ = try await APIClient.shared.completeScan(scanId: created.scanId)
            phase = .done
            return created.scanId
        } catch {
            phase = .failed(error.localizedDescription)
            return nil
        }
    }
}
