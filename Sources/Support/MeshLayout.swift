import Foundation
import simd

/// Floors + main wall direction of the GREY PREVIEW, for the 3D viewer's floor buttons and Top
/// view (owner 30/09, `PLAN-XEM-3D-TANG-MAU.md`). Computed on the phone when the viewer opens,
/// from `mesh-preview.bin` (ARKit world, metres, Y up). No server data, so it works before the
/// scan is ordered.
///
/// Floors = port of order-webapp `src/lib/mesh-area.ts` `findFloorLevels`, same constants:
/// up-facing triangles (winding normal n.y/|n| > 0.9) add their area to 0.25 m bins of centroid
/// height; bins by area (desc, tie: lower first) down to 15% of the best; a bin is a floor when
/// it is ≥ 2 m from every floor already taken. ✗ server floors (`plan-transform.json` z_floor):
/// 0.4–0.6 m off the mesh on #LS-MTR8E4ZI5 (−4.83 / −0.88 vs −5.25 / −1.50 here).
/// Band of floor i = [level_i − 0.3, level_{i+1} − 0.3), top floor open (= `plan-floors.ts`
/// `floorBand` for auto floors).
///
/// Wall angle = area-weighted histogram of wall-normal angle mod 90° (|n.y| < 0.2), 0.5° bins,
/// smoothed ±3 bins (#LS-MTR8E4ZI5: 8.25° vs workstation `rotate_deg` 7.64°).
/// Offline mirror of this file: `PLAN-GIAO-DIEN-mockups/m9/render.py` (same steps).
struct MeshLayout {
    static let floorBin: Double = 0.25
    static let floorMinFraction: Double = 0.15
    static let floorMinGap: Double = 2
    static let bandBelow: Float = 0.3
    /// Open end of a clip band. Finite on purpose: it goes into a shader uniform.
    static let openEnd: Float = 1_000_000

    /// Floor heights, world Y, ascending. Floor buttons only when ≥ 2.
    let floors: [Float]
    /// Main wall direction θ, radians in [0, π/2): wall normals in XZ sit at θ mod 90°.
    let wallAngle: Float
    /// 1–99% of the vertices along r = (cos θ, sin θ) and f = (−sin θ, cos θ), world (x, z).
    let along: ClosedRange<Float>
    let across: ClosedRange<Float>
    let minY: Float

    /// No preview geometry (textured-only scan, or analysis failed): no floors, not
    /// straightened, bounding-box footprint.
    init(boundsMin: SIMD3<Float>, boundsMax: SIMD3<Float>) {
        floors = []
        wallAngle = 0
        along = Self.span(boundsMin.x, boundsMax.x)
        across = Self.span(boundsMin.z, boundsMax.z)
        minY = boundsMin.y.isFinite ? boundsMin.y : 0
    }

    /// ✗ `a...b` straight: a NaN or a > b traps in `ClosedRange.init`.
    private static func span(_ a: Float, _ b: Float) -> ClosedRange<Float> {
        guard a.isFinite, b.isFinite else { return 0...0 }
        return min(a, b)...max(a, b)
    }

    private init(floors: [Float], wallAngle: Float, along: ClosedRange<Float>,
                 across: ClosedRange<Float>, minY: Float) {
        self.floors = floors
        self.wallAngle = wallAngle
        self.along = along
        self.across = across
        self.minY = minY
    }

    /// Clip band, world Y, for `floor` (nil = All).
    func band(_ floor: Int?) -> (lo: Float, hi: Float) {
        guard let i = floor, floors.indices.contains(i) else { return (-Self.openEnd, Self.openEnd) }
        let hi = i + 1 < floors.count ? floors[i + 1] - Self.bandBelow : Self.openEnd
        return (floors[i] - Self.bandBelow, hi)
    }

    /// Plane Top view frames and pans on: the floor shown; All = the top floor (seen from above,
    /// the top floor covers the ones below).
    func topBase(_ floor: Int?) -> Float {
        if let i = floor, floors.indices.contains(i) { return floors[i] }
        return floors.last ?? minY
    }

    /// `nonisolated` + `async` ON PURPOSE (SE-0338): called from the viewer's `@MainActor`
    /// `.task`, it runs on the cooperative pool. ~0.2M triangles + two sorts of ~0.1M floats.
    /// Indices were range-checked by `MeshPreviewFile.readSync`; positions were not (only the
    /// bounds), so every triangle is checked finite before an `Int(...)` conversion can trap.
    static func analyse(_ d: MeshPreviewFile.Decoded) async -> MeshLayout? {
        let vertexCount = d.vertexCount
        let triangleCount = d.triangleCount
        guard vertexCount > 0, triangleCount > 0,
              d.indexData.count >= triangleCount * 12,
              d.raw.count >= d.positionOffset + vertexCount * 12
        else { return nil }

        var positions = [SIMD3<Double>]()
        positions.reserveCapacity(vertexCount)
        d.raw.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress else { return }
            for i in 0..<vertexCount {
                let o = d.positionOffset + i * 12
                positions.append(SIMD3<Double>(
                    Double(base.loadUnaligned(fromByteOffset: o, as: Float.self)),
                    Double(base.loadUnaligned(fromByteOffset: o + 4, as: Float.self)),
                    Double(base.loadUnaligned(fromByteOffset: o + 8, as: Float.self))
                ))
            }
        }
        guard positions.count == vertexCount else { return nil }

        var bins: [Int: Double] = [:]
        var wallHist = [Double](repeating: 0, count: 180)
        d.indexData.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress else { return }
            for t in 0..<triangleCount {
                let o = t * 12
                let ia = Int(base.loadUnaligned(fromByteOffset: o, as: UInt32.self))
                let ib = Int(base.loadUnaligned(fromByteOffset: o + 4, as: UInt32.self))
                let ic = Int(base.loadUnaligned(fromByteOffset: o + 8, as: UInt32.self))
                guard ia < vertexCount, ib < vertexCount, ic < vertexCount else { continue }
                let a = positions[ia], b = positions[ib], c = positions[ic]
                let n = simd_cross(b - a, c - a)
                // Same as mesh-area.ts: plain sqrt of the sum of squares.
                let len = (n.x * n.x + n.y * n.y + n.z * n.z).squareRoot()
                guard len > 1e-12, len.isFinite else { continue }
                if n.y / len > 0.9 {
                    let q = (((a.y + b.y + c.y) / 3) / floorBin).rounded(.down)
                    if q.isFinite, abs(q) < 1_000_000 {
                        bins[Int(q), default: 0] += 0.5 * len
                    }
                }
                if abs(n.y) / len < 0.2 {
                    var deg = atan2(n.z, n.x) * 180 / .pi
                    deg = deg.truncatingRemainder(dividingBy: 90)
                    if deg < 0 { deg += 90 }
                    // Area weight (×2, like render.py); the scale does not move the peak.
                    wallHist[min(max(Int(deg / 0.5), 0), 179)] += len
                }
            }
        }

        // findFloorLevels
        let order = bins.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        var levels: [Double] = []
        if let best = order.first?.value {
            for (bin, area) in order {
                if area < floorMinFraction * best { break }
                let y = Double(bin) * floorBin
                if levels.allSatisfy({ abs(y - $0) >= floorMinGap }) { levels.append(y) }
            }
        }
        levels.sort()

        // Main wall direction: circular ±3-bin window, first maximum.
        var theta: Double = 0
        if wallHist.contains(where: { $0 > 0 }) {
            var bestK = 0
            var bestSum = -1.0
            for k in 0..<180 {
                var sum = 0.0
                for j in -3...3 { sum += wallHist[(k + j + 180) % 180] }
                if sum > bestSum {
                    bestSum = sum
                    bestK = k
                }
            }
            theta = (Double(bestK) * 0.5 + 0.25) * .pi / 180
        }

        // Footprint along the straightened axes, 1–99% of vertices (strays through windows out).
        let r = SIMD2<Double>(cos(theta), sin(theta))
        let f = SIMD2<Double>(-sin(theta), cos(theta))
        var alongValues = [Float]()
        var acrossValues = [Float]()
        alongValues.reserveCapacity(vertexCount)
        acrossValues.reserveCapacity(vertexCount)
        for p in positions where p.x.isFinite && p.z.isFinite {
            alongValues.append(Float(p.x * r.x + p.z * r.y))
            acrossValues.append(Float(p.x * f.x + p.z * f.y))
        }
        guard !alongValues.isEmpty else { return nil }
        alongValues.sort()
        acrossValues.sort()

        return MeshLayout(
            floors: levels.map { Float($0) },
            wallAngle: Float(theta),
            along: percentile(alongValues, 0.01)...percentile(alongValues, 0.99),
            across: percentile(acrossValues, 0.01)...percentile(acrossValues, 0.99),
            minY: d.boundsMin.y
        )
    }

    /// Nearest-rank percentile of a SORTED, non-empty array.
    private static func percentile(_ sorted: [Float], _ q: Double) -> Float {
        let i = Int((Double(sorted.count - 1) * q).rounded())
        return sorted[min(max(i, 0), sorted.count - 1)]
    }
}
