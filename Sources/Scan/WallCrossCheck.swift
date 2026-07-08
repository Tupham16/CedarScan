import Foundation
import RoomPlan
import simd

/// Kiểm tra chéo từng bức tường RoomPlan với đám mây điểm LiDAR thô (ARMeshAnchor).
/// RoomPlan đôi khi "vẽ" tường lệch vài cm so với thực tế — mesh thô là bằng chứng độc lập.
/// Chạy 1 lần lúc Hoàn tất & Lưu, trên queue nền, ~<2s với 120k đỉnh.
enum WallCrossCheck {
    private struct WallSlab {
        let id: UUID
        let center: SIMD3<Float>
        let rotT: simd_float3x3      // đưa điểm world về hệ local tường (x dọc tường, y cao, z vuông góc)
        let axis: SIMD3<Float>       // trục dọc tường (world) — dùng khử tường trùng
        let normal: SIMD3<Float>     // pháp tuyến tường (world)
        let halfW: Float
        let height: Float
        let aabbMin: SIMD3<Float>
        let aabbMax: SIMD3<Float>
        var points: [SIMD3<Float>] = []
    }

    static func run(
        rooms: [CapturedRoom],
        meshPieces: [[SIMD3<Float>]],
        config cfg: ScanQualityConfig = .current
    ) async -> [WallCheckResult] {
        guard !rooms.isEmpty, !meshPieces.isEmpty else { return [] }
        let pieces = meshPieces
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: compute(rooms: rooms, pieces: pieces, cfg: cfg))
            }
        }
    }

    private static func compute(
        rooms: [CapturedRoom], pieces: [[SIMD3<Float>]], cfg: ScanQualityConfig
    ) -> [WallCheckResult] {
        let band = Float(cfg.wallBand)
        let edge = Float(cfg.wallEdgeMargin)
        let vert = Float(cfg.wallVerticalMargin)

        // B1. Dựng slab cho từng tường (bỏ tường cong — không so bằng mặt phẳng được)
        var slabs: [WallSlab] = []
        for room in rooms {
            for wall in room.walls {
                if wall.curve != nil { continue }
                let halfW = wall.dimensions.x / 2
                let height = wall.dimensions.y
                guard halfW > edge + 0.05, height > 2 * vert + 0.1 else { continue }
                let m = wall.transform
                let xAxis = simd_normalize(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z))
                let yAxis = simd_normalize(SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z))
                let zAxis = simd_normalize(SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
                let center = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
                let ext = abs(xAxis) * halfW + abs(yAxis) * (height / 2) + abs(zAxis) * (band + 0.02)
                slabs.append(WallSlab(
                    id: wall.identifier,
                    center: center,
                    rotT: simd_float3x3(xAxis, yAxis, zAxis).transpose,
                    axis: xAxis,
                    normal: zAxis,
                    halfW: halfW,
                    height: height,
                    aabbMin: center - ext,
                    aabbMax: center + ext
                ))
            }
        }
        guard !slabs.isEmpty else { return [] }

        // B1b. Khử tường TRÙNG giữa 2 phòng (tường chung xuất hiện 2 lần khi ghép nhà):
        // cùng hướng (<5°) + cùng mặt phẳng (<8cm) + khoảng tâm dọc tường chồng lên nhau
        // → giữ bản DÀI hơn. Không khử thì bản còn lại bị "đói" điểm → unverified oan.
        var kept: [WallSlab] = []
        for slab in slabs.sorted(by: { $0.halfW > $1.halfW }) {
            let isDuplicate = kept.contains { k in
                abs(simd_dot(k.normal, slab.normal)) > 0.996
                    && abs(simd_dot(k.normal, slab.center - k.center)) < 0.08
                    && abs(simd_dot(k.axis, slab.center - k.center)) < k.halfW + slab.halfW
            }
            if !isDuplicate { kept.append(slab) }
        }

        // B2. Gom điểm mesh — mỗi đỉnh gán cho tường GẦN NHẤT theo |q.z|
        // (không phụ thuộc thứ tự mảng; tường góc giao nhau không tranh điểm sai)
        for piece in pieces {
            for p in piece {
                var bestIdx = -1
                var bestZ = Float.greatestFiniteMagnitude
                var bestQ = SIMD3<Float>(repeating: 0)
                for i in kept.indices {
                    if p.x < kept[i].aabbMin.x || p.x > kept[i].aabbMax.x { continue }
                    if p.y < kept[i].aabbMin.y || p.y > kept[i].aabbMax.y { continue }
                    if p.z < kept[i].aabbMin.z || p.z > kept[i].aabbMax.z { continue }
                    let q = kept[i].rotT * (p - kept[i].center)
                    guard abs(q.z) <= band,
                          abs(q.x) <= kept[i].halfW - edge,
                          q.y >= -kept[i].height / 2 + vert,
                          q.y <= kept[i].height / 2 - vert else { continue }
                    if abs(q.z) < bestZ {
                        bestZ = abs(q.z)
                        bestIdx = i
                        bestQ = q
                    }
                }
                if bestIdx >= 0 {
                    kept[bestIdx].points.append(bestQ)
                }
            }
        }

        // B3. Đánh giá từng tường
        return kept.map { evaluate(slab: $0, cfg: cfg) }
    }

    private static func evaluate(slab: WallSlab, cfg: ScanQualityConfig) -> WallCheckResult {
        let unverified = WallCheckResult(
            id: slab.id.uuidString, wallClass: .unverified,
            offsetCm: 0, angleDeg: 0, coveragePct: 0,
            lengthM: round2(Double(slab.halfW * 2))
        )
        guard slab.points.count >= cfg.wallMinPoints else { return unverified }

        // Độ phủ: lưới 0.2m trên mặt tường, ô "có" nếu ≥3 điểm
        let cell: Float = 0.2
        let usableW = 2 * (slab.halfW - Float(cfg.wallEdgeMargin))
        let usableH = slab.height - 2 * Float(cfg.wallVerticalMargin)
        let cols = max(1, Int(ceil(usableW / cell)))
        let rows = max(1, Int(ceil(usableH / cell)))
        var cellCounts = [Int](repeating: 0, count: cols * rows)
        for q in slab.points {
            let cx = min(cols - 1, max(0, Int((q.x + usableW / 2) / cell)))
            let cy = min(rows - 1, max(0, Int((q.y + usableH / 2) / cell)))
            cellCounts[cy * cols + cx] += 1
        }
        let coverage = Double(cellCounts.filter { $0 >= 3 }.count) / Double(cols * rows)
        guard coverage >= cfg.wallMinCoverage else {
            var r = unverified
            r.coveragePct = round1(coverage * 100)
            return r
        }

        // RANSAC tìm mặt phẳng trội trong slab (loại điểm đồ đạc/rèm lọt vào band)
        let sample = subsample(slab.points, max: 5000)
        guard sample.count >= 3 else { return unverified }   // config từ xa sai cũng không được crash
        var bestInliers = 0
        var bestPlane: (n: SIMD3<Float>, d: Float)?
        for _ in 0..<64 {
            let a = sample[Int.random(in: 0..<sample.count)]
            let b = sample[Int.random(in: 0..<sample.count)]
            let c = sample[Int.random(in: 0..<sample.count)]
            let n = simd_cross(b - a, c - a)
            let len = simd_length(n)
            guard len > 1e-6 else { continue }
            let normal = n / len
            let d = -simd_dot(normal, a)
            var inliers = 0
            for p in sample where abs(simd_dot(normal, p) + d) <= 0.03 {
                inliers += 1
            }
            if inliers > bestInliers {
                bestInliers = inliers
                bestPlane = (normal, d)
            }
        }
        guard let plane = bestPlane, bestInliers >= max(50, sample.count / 5) else {
            return unverified
        }
        let inlierRatio = Double(bestInliers) / Double(sample.count)
        let inliers = slab.points.filter { abs(simd_dot(plane.n, $0) + plane.d) <= 0.03 }
        guard inliers.count >= cfg.wallMinPoints / 2 else { return unverified }

        // Tinh chỉnh LSQ: fit z = a·x + b·y + c trên inliers (mặt tường RoomPlan là z=0
        // trong hệ local nên bài toán luôn well-conditioned)
        var sxx: Double = 0, sxy: Double = 0, syy: Double = 0
        var sx: Double = 0, sy: Double = 0, sz: Double = 0
        var sxz: Double = 0, syz: Double = 0
        for q in inliers {
            let x = Double(q.x), y = Double(q.y), z = Double(q.z)
            sxx += x * x; sxy += x * y; syy += y * y
            sx += x; sy += y; sz += z
            sxz += x * z; syz += y * z
        }
        let n = Double(inliers.count)
        // Giải hệ 3x3 (Cramer): [sxx sxy sx; sxy syy sy; sx sy n] · [a b c] = [sxz syz sz]
        // (tách nhỏ từng minor — biểu thức gộp làm Swift type-check quá lâu, CI fail)
        let m00: Double = syy * n - sy * sy
        let m01: Double = sxy * n - sy * sx
        let m02: Double = sxy * sy - syy * sx
        let det: Double = sxx * m00 - sxy * m01 + sx * m02
        var a: Double = 0
        var b: Double = 0
        var c: Double = 0
        if abs(det) > 1e-9 {
            let a1: Double = sxz * m00
            let a2: Double = sxy * (syz * n - sz * sy)
            let a3: Double = sx * (syz * sy - syy * sz)
            a = (a1 - a2 + a3) / det
            let b1: Double = sxx * (syz * n - sz * sy)
            let b2: Double = sxz * m01
            let b3: Double = sx * (sxy * sz - syz * sx)
            b = (b1 - b2 + b3) / det
            let c1: Double = sxx * (syy * sz - sy * syz)
            let c2: Double = sxy * (sxy * sz - sx * syz)
            let c3: Double = sxz * m02
            c = (c1 - c2 + c3) / det
        } else {
            c = sz / n
        }

        let angleDeg = atan(sqrt(a * a + b * b)) * 180 / .pi
        let offset = abs(c)
        // Residual so với mặt phẳng VỪA FIT (độ gồ ghề bề mặt) — không so với mặt RoomPlan,
        // nếu không tường lệch đều/nghiêng sẽ bị p90 phạt ĐÚP với offset/angle.
        var residAbs: [Float] = []
        residAbs.reserveCapacity(inliers.count)
        for q in inliers {
            let zq: Double = Double(q.z)
            let xTerm: Double = a * Double(q.x)
            let yTerm: Double = b * Double(q.y)
            let predicted: Double = xTerm + yTerm + c
            residAbs.append(Float(abs(zq - predicted)))
        }
        residAbs.sort()
        let p90 = Double(residAbs[min(residAbs.count - 1, Int(Double(residAbs.count) * 0.9))])

        var wallClass: WallCheckResult.Class
        if offset <= cfg.wallOffsetOK && angleDeg <= cfg.wallAngleOK && p90 <= cfg.wallResidOK {
            wallClass = .ok
        } else if offset <= cfg.wallOffsetSuspect && angleDeg <= cfg.wallAngleSuspect
                    && p90 <= cfg.wallResidSuspect {
            wallClass = .suspect
        } else {
            wallClass = .misaligned
        }
        // Mesh không phẳng (nhiều đồ che tường) → độ tin thấp, tối đa chỉ dám nói "nghi ngờ"
        if inlierRatio < 0.4 && wallClass == .misaligned {
            wallClass = .suspect
        }

        return WallCheckResult(
            id: slab.id.uuidString,
            wallClass: wallClass,
            offsetCm: round1(offset * 100),
            angleDeg: round1(angleDeg),
            coveragePct: round1(coverage * 100),
            lengthM: round2(Double(slab.halfW * 2))
        )
    }

    private static func subsample(_ points: [SIMD3<Float>], max limit: Int) -> [SIMD3<Float>] {
        guard points.count > limit else { return points }
        let stride = points.count / limit
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(limit)
        var i = 0
        while i < points.count {
            out.append(points[i])
            i += stride
        }
        return out
    }

    private static func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
    private static func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
}
