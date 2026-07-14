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

    static let fileKinds: [(kind: String, fileName: String)] = [
        ("usdz", "model.usdz"),
        ("obj", "model.obj"),
        ("mtl", "model.mtl"),
        ("mesh", "colored-mesh.ply"),
        ("video", "scan-video.mp4"),
        ("plan", "floorplan.png"),
        ("rooms", "rooms.json"),
    ]

    /// Trả về cloudScanId khi thành công, nil khi thất bại (phase = .failed).
    func upload(record: ScanRecord, folder: URL) async -> String? {
        phase = .preparing
        let fm = FileManager.default

        let present = Self.fileKinds.filter { fm.fileExists(atPath: folder.appendingPathComponent($0.fileName).path) }
        // Quét RoomPlan cần mô hình 3D; quét VIDEO chỉ cần video; quét MESH có thể chỉ có
        // PLY (video recorder fail lặng lẽ vẫn phải upload được mesh).
        guard present.contains(where: {
            $0.kind == "usdz" || $0.kind == "obj" || $0.kind == "video" || $0.kind == "mesh"
        }) else {
            phase = .failed(L.t("No scan files found for this scan.", "Không tìm thấy file của bản quét này."))
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
                captureType: record.captureType ?? "lidar",
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
