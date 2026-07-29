import Foundation

/// Chuyển mô hình LiDAR CÓ MÀU (file .ply do ColorMeshBuilder xuất) sang gói ZIP chứa
/// OBJ + MTL (makeOBJZip) — dùng cho cả chế độ quét Mesh lẫn luồng RoomPlan.
/// OBJ mang MÀU THEO ĐỈNH (v x y z r g b), mở được CÓ MÀU trong MeshLab, CloudCompare
/// và (bật tay) trong Blender.
///
/// LƯU Ý: màu đỉnh trong OBJ là phi tiêu chuẩn — Blender khi RENDER lấy màu từ vật liệu
/// nên OBJ+MTL không tự ra màu khi render. Muốn Blender ra màu ngay, dùng GLBExporter.
///
/// Chạy NỀN (nặng ~10–20MB với 120k đỉnh). Chỉ đọc/ghi file, không đụng UIKit.
enum ColoredOBJExporter {
    enum ExportError: Error { case zipFailed }

    private static let mtlText = """
    # CedarScan material — màu nằm ở từng đỉnh (vertex colors), không dùng texture map.
    newmtl vertexcolor
    Ka 1.000 1.000 1.000
    Kd 1.000 1.000 1.000
    Ks 0.000 0.000 0.000
    d 1.0
    illum 1

    """

    /// Đọc PLY màu → ghi model.obj + model.mtl (+ model.glb khi `includeGLB`) vào 1 thư mục
    /// tạm rồi nén thành .zip tại `zipURL`. `includeGLB` cho chế độ quét Mesh: đội vẽ kéo
    /// model.glb vào Blender là CÓ MÀU ngay (OBJ màu-theo-đỉnh phi tiêu chuẩn — Blender
    /// render ra trắng); zip nặng thêm ~20–25MB/1M đỉnh, vẫn nhẹ so cap upload 500MB.
    /// `extraFiles`: file phụ đóng kèm cạnh model.obj (vd camera-track.json cho minimap) —
    /// copy theo đúng tên file gốc, hỏng không chặn zip. Phần tử là THƯ MỤC cũng được:
    /// `copyItem` copy đệ quy → zip mang nguyên thư mục con (texture-shots/ đi đường này).
    static func makeOBJZip(
        fromPLY plyURL: URL, to zipURL: URL, includeGLB: Bool = false, extraFiles: [URL] = []
    ) throws {
        let mesh = try ColoredMeshPLY.parse(plyURL)

        // MARK: - Ghi các file vào thư mục tạm rồi nén
        let fm = FileManager.default
        let work = fm.temporaryDirectory
            .appendingPathComponent("CedarScan-3D-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        try writeOBJ(mesh, to: work.appendingPathComponent("model.obj"))
        try Data(mtlText.utf8).write(to: work.appendingPathComponent("model.mtl"))
        if includeGLB {
            // GLB hỏng không chặn zip — OBJ vẫn là dữ liệu chính.
            try? GLBExporter.makeGLB(mesh: mesh, to: work.appendingPathComponent("model.glb"))
        }
        for extra in extraFiles {
            try? fm.copyItem(at: extra, to: work.appendingPathComponent(extra.lastPathComponent))
        }

        try zipDirectory(work, to: zipURL)
    }

    /// Ghi OBJ dạng STREAM (buffer ~1MB, màu theo đỉnh: v x y z r g b).
    /// Bản cũ gom hơn 1 triệu String rồi joined() — đỉnh RAM tạm ~200MB ở 450k đỉnh;
    /// stream giữ đỉnh ~20MB ở mọi mức nét và bỏ được cú khựng joined()+copy.
    private static func writeOBJ(_ mesh: ColoredMeshPLY.Mesh, to objURL: URL) throws {
        FileManager.default.createFile(atPath: objURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: objURL)
        defer { try? handle.close() }

        // 🔴 BUFFER LÀ `[UInt8]`, KHÔNG PHẢI `Data`, VÀ MỖI DÒNG ĐƯỢC GOM RIÊNG TRƯỚC KHI ĐỔ VÀO.
        // `Data.append(_ byte:)` KHÔNG phải phép ghi con trỏ: nó đi qua RangeReplaceableCollection
        // → `_Representation.replaceSubrange` (switch 4 nhánh) → `ensureUniqueReferenced()` →
        // `__DataStorage.replaceBytes` — một lời gọi thật xuyên module vào Foundation cho MỖI BYTE.
        // Ở nhà nguyên căn, ghi từng byte thẳng vào Data là ~250 TRIỆU lời gọi như vậy. Gom dòng
        // vào một mảng byte (append vào Array chỉ là bump con trỏ khi đã reserveCapacity) rồi đổ
        // MỘT lần cho cả dòng đưa con số đó về ~7,5 triệu.
        // (Bonus: `Data.removeAll(keepingCapacity:)` khi rỗng lại đặt biểu diễn về `.empty`, tức
        // mất luôn 1,2MB vừa reserve và phải mọc lại sau MỖI lần flush — Array không có tật này.)
        var buffer = [UInt8]()
        buffer.reserveCapacity(1_200_000)
        var line = [UInt8]()
        line.reserveCapacity(64)

        func flushIfNeeded(force: Bool = false) throws {
            if buffer.count >= 1_000_000 || (force && !buffer.isEmpty) {
                // Bọc `Data(...)` tường minh: `FileHandle.write(contentsOf:)` nhận `DataProtocol`
                // và `[UInt8]` có conform, nhưng máy này không compile được để chắc — một vòng CI
                // hỏng đắt hơn một lần memcpy 1MB.
                try handle.write(contentsOf: Data(buffer))
                buffer.removeAll(keepingCapacity: true)
            }
        }

        buffer.append(contentsOf: "# CedarScan colored LiDAR mesh\nmtllib model.mtl\no CedarScanMesh\nusemtl vertexcolor\n".utf8)
        for k in mesh.positions.indices {
            let p = mesh.positions[k]
            let c = mesh.colors[k]
            line.removeAll(keepingCapacity: true)
            line.append(0x76) // "v"
            appendFixed(Double(p.x), decimals: 4, to: &line)
            appendFixed(Double(p.y), decimals: 4, to: &line)
            appendFixed(Double(p.z), decimals: 4, to: &line)
            appendFixed(Double(c.r) / 255.0, decimals: 3, to: &line)
            appendFixed(Double(c.g) / 255.0, decimals: 3, to: &line)
            appendFixed(Double(c.b) / 255.0, decimals: 3, to: &line)
            line.append(0x0A) // "\n"
            buffer.append(contentsOf: line)
            try flushIfNeeded()
        }
        var i = 0
        while i < mesh.indices.count {
            // OBJ đánh chỉ số đỉnh từ 1
            line.removeAll(keepingCapacity: true)
            line.append(0x66) // "f"
            appendIndex(UInt64(mesh.indices[i]) + 1, to: &line)
            appendIndex(UInt64(mesh.indices[i + 1]) + 1, to: &line)
            appendIndex(UInt64(mesh.indices[i + 2]) + 1, to: &line)
            line.append(0x0A)
            buffer.append(contentsOf: line)
            try flushIfNeeded()
            i += 3
        }
        try flushIfNeeded(force: true)
    }

    // MARK: - Bộ in số tự viết (thay String(format:) — xem lý do bên dưới)

    /// Ghi " -12.3456" (dấu cách đứng trước, `decimals` chữ số thập phân) vào buffer byte.
    ///
    /// 🔴 VÌ SAO KHÔNG DÙNG `String(format:)`: nó là NÚT THẮT SỐ 1 của toàn bộ thời gian chờ
    /// sau khi bấm "Dừng & Lưu". Ở nhà nguyên căn (~2,5 triệu đỉnh sau khi chia nhỏ tam giác)
    /// đó là 2,5 triệu lời gọi đi qua CVarArg boxing + CFStringCreateWithFormatAndArguments +
    /// 6 lần đổi double→thập phân + cấp phát String, mỗi lời gọi ~1,5–3µs = 4–8 GIÂY, chạy
    /// MỘT LUỒNG trong khi vòng bake màu ngay trước đó đã dùng cả 6 nhân. Cộng thêm 5 triệu
    /// lần nội suy chuỗi cho dòng mặt.
    /// ⚠ KHÔNG HỨA CON SỐ TUYỆT ĐỐI: bộ in này bỏ được toàn bộ chi phí format của Foundation
    /// (ước rẻ hơn vài lần), nhưng máy dev là Windows nên chưa ai ĐO trên máy thật. Khi chủ app
    /// test, hãy bấm giờ màn "Đang dựng mô hình 3D…" trên cùng một căn để có số thật, rồi ghi
    /// lại đây thay cho câu ước lượng này.
    ///
    /// ĐỊNH DẠNG ĐẦU RA GIỮ NGUYÊN TỪNG BYTE so với "%.4f"/"%.3f" (cùng số chữ số, cùng dấu
    /// chấm, cùng dấu cách) nên đội vẽ nhận đúng file như cũ.
    /// ⚠ Khác biệt duy nhất, có chủ đích: chỗ làm tròn HOÀ chính xác (giá trị rơi đúng .00005)
    /// printf làm tròn về số chẵn còn hàm này làm tròn ra xa số 0 → lệch tối đa 0,05mm, dưới
    /// nhiễu đo của ARKit (~1cm) hai bậc. Giá trị không hữu hạn (NaN/inf từ mesh hỏng) ghi ra
    /// 0 thay vì chuỗi "nan" — parser OBJ của đội vẽ không phải đọc rác.
    private static func appendFixed(_ value: Double, decimals: Int, to buffer: inout [UInt8]) {
        buffer.append(0x20) // " "
        var v = value
        if !v.isFinite { v = 0 }
        let negative = v < 0
        if negative { v = -v }
        var scale: UInt64 = 1
        for _ in 0..<decimals { scale *= 10 }
        let scaled = (v * Double(scale)).rounded()
        // Van chặn tràn: toạ độ điên rồ (mesh hỏng) không được phép sinh số rác hay crash.
        guard scaled >= 0, scaled < 9_000_000_000_000_000 else {
            buffer.append(0x30) // "0"
            buffer.append(0x2E) // "."
            for _ in 0..<decimals { buffer.append(0x30) }
            return
        }
        let total = UInt64(scaled)
        // Bỏ dấu trừ khi kết quả làm tròn về đúng 0 ("-0.0000" đọc được nhưng thừa và khó soi).
        if negative, total != 0 { buffer.append(0x2D) } // "-"
        appendDigits(total / scale, to: &buffer)
        buffer.append(0x2E) // "."
        appendDigits(total % scale, width: decimals, to: &buffer)
    }

    /// Ghi " 12345" (dấu cách đứng trước) — dùng cho chỉ số đỉnh của dòng mặt.
    private static func appendIndex(_ value: UInt64, to buffer: inout [UInt8]) {
        buffer.append(0x20)
        appendDigits(value, to: &buffer)
    }

    /// Ghi các chữ số thập phân của `value`, không cấp phát: tìm luỹ thừa 10 lớn nhất rồi
    /// bóc từng chữ số. `width > 0` thì đệm số 0 ở đầu cho đủ độ rộng (phần thập phân).
    private static func appendDigits(_ value: UInt64, width: Int = 0, to buffer: inout [UInt8]) {
        var divisor: UInt64 = 1
        if width > 0 {
            for _ in 1..<max(width, 1) { divisor *= 10 }
        } else {
            var rest = value
            while rest >= 10 {
                divisor *= 10
                rest /= 10
            }
        }
        var rest = value
        while divisor > 0 {
            let digit = rest / divisor
            buffer.append(UInt8(48 + digit))
            rest -= digit * divisor
            divisor /= 10
        }
    }

    // MARK: - Nén thư mục thành .zip (dùng NSFileCoordinator, không cần thư viện ngoài)

    private static func zipDirectory(_ directory: URL, to zipURL: URL) throws {
        let fm = FileManager.default
        var coordError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(
            readingItemAt: directory, options: .forUploading, error: &coordError
        ) { tempZipURL in
            do {
                if fm.fileExists(atPath: zipURL.path) {
                    try fm.removeItem(at: zipURL)
                }
                // tempZipURL chỉ hợp lệ TRONG closure này — phải copy ra ngay.
                try fm.copyItem(at: tempZipURL, to: zipURL)
            } catch {
                copyError = error
            }
        }
        if let coordError { throw coordError }
        if let copyError { throw copyError }
        guard fm.fileExists(atPath: zipURL.path) else { throw ExportError.zipFailed }
    }
}
