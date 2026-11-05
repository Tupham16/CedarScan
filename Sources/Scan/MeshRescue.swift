import simd

/// Geometry of the mesh rescue (05/11, #LS-MW30FJAA2, owner board item A). When ARKit merges a sub-map
/// back into the main map it moves plain anchors but never mesh, and on a big merge it can drop the
/// sub-map's mesh altogether (§TRAPS #57). `ColorMeshBuilder` keeps what ARKit removes; these rules pick
/// the pieces that went with such a merge and put them back where the corrected map has them.
/// No ARKit or app types here: `tools/mesh-rescue-check` compiles this file alone in CI.
enum MeshRescue {
    typealias Face = (UInt32, UInt32, UInt32)

    /// A texture-shot anchor (`TextureShotRecorder.anchorName`): first seen at `seenAt` (pose = capture
    /// pose `m` in shots.json); `poses` = its pose after each move of ≥ 1 cm / ~0.1°, `now` = latest.
    struct Shot {
        let seenAt: Double
        private(set) var poses: [(t: Double, m: simd_float4x4)]
        private(set) var now: simd_float4x4

        init(seenAt: Double, pose: simd_float4x4) {
            self.seenAt = seenAt
            poses = [(t: seenAt, m: pose)]
            now = pose
        }

        mutating func update(_ m: simd_float4x4, at t: Double) {
            now = m
            guard let last = poses.last?.m else { return }
            let turned = simd_length(last.columns.0 - m.columns.0) + simd_length(last.columns.1 - m.columns.1)
                + simd_length(last.columns.2 - m.columns.2)
            if simd_distance(MeshRescue.position(last), MeshRescue.position(m)) >= 0.01 || turned >= 0.003 {
                poses.append((t: t, m: m))
            }
        }

        /// Pose at time `t` (the first pose before `seenAt`).
        func pose(at t: Double) -> simd_float4x4 {
            var p = poses[0].m
            for entry in poses where entry.t <= t { p = entry.m }
            return p
        }
    }

    /// Coverage voxel. With the 27-cell neighbourhood, live mesh within ~10–20 cm and facing the same way
    /// covers a point (the correction landed 4–8 cm from re-scanned mesh on 05/11).
    static let voxel: Float = 0.10
    /// A shot further than this in time or space from a piece says nothing about the piece's sub-map.
    static let maxShotGap: Double = 20
    static let maxShotDistance: Float = 8
    /// The piece's sub-map moved at least this since the piece was built (ordinary map refinement moves
    /// shots 0–7 cm; the 05/11 merge 26–51 cm; merges that kept their mesh 10–24 cm).
    static let minShift: Float = 0.15
    /// …and at least this within `eventBefore` s before to `eventAfter` s after the piece's removal: the
    /// removal went with that correction, not with ARKit's own clean-up (a replaced chunk, carved noise).
    static let minEventShift: Float = 0.10
    static let eventBefore: Double = 10
    static let eventAfter: Double = 2
    /// The shots nearest the piece's first and last update agree on its correction within this: the piece
    /// lived in one sub-map (else part of it was built in correct coordinates).
    static let sameSubMap: Float = 0.03
    /// Live mesh covering more than this of the piece where it sat (uncorrected) = ARKit replaced it there.
    static let coveredInPlace: Float = 0.5

    /// The shot first seen nearest in time to `t`, within `maxShotGap` s and `maxShotDistance` m of `center`.
    static func nearestShot(to t: Double, center: SIMD3<Float>, shots: [Shot]) -> Shot? {
        var best: Shot?
        var bestGap = maxShotGap
        for s in shots {
            let gap = abs(s.seenAt - t)
            guard gap <= bestGap, simd_distance(position(s.poses[0].m), center) <= maxShotDistance else { continue }
            best = s
            bestGap = gap
        }
        return best
    }

    /// Did the piece's sub-map move around the piece's removal? Decided once `removedAt + eventAfter` has
    /// passed; before that it may still turn true.
    static func movedAtRemoval(_ s: Shot, removedAt: Double, center: SIMD3<Float>) -> Bool {
        let move = s.pose(at: removedAt + eventAfter) * s.pose(at: removedAt - eventBefore).inverse
        return shift(move, at: center) >= minEventShift
    }

    /// Correction to put a removed piece back, or nil when it does not qualify (see the constants above).
    /// ARKit moves a whole sub-map rigidly (05/11: one transform for every shot of 348–507 s), so the move
    /// of the shot nearest the piece's last update since that update is the piece's.
    static func correction(
        builtFirst: Double, builtLast: Double, removedAt: Double, center: SIMD3<Float>, shots: [Shot]
    ) -> simd_float4x4? {
        guard let s = nearestShot(to: builtLast, center: center, shots: shots),
              let s0 = nearestShot(to: builtFirst, center: center, shots: shots) else { return nil }
        let m = s.now * s.pose(at: builtLast).inverse
        let m0 = s0.now * s0.pose(at: builtFirst).inverse
        guard shift(m, at: center) >= minShift,
              movedAtRemoval(s, removedAt: removedAt, center: center),
              simd_distance(apply(m, center), apply(m0, center)) <= sameSubMap else { return nil }
        return m
    }

    static func position(_ m: simd_float4x4) -> SIMD3<Float> {
        SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }

    /// How far `m` moves `p`, metres.
    static func shift(_ m: simd_float4x4, at p: SIMD3<Float>) -> Float {
        simd_distance(apply(m, p), p)
    }

    static func apply(_ m: simd_float4x4, _ p: SIMD3<Float>) -> SIMD3<Float> {
        let q = m * SIMD4<Float>(p, 1)
        return SIMD3(q.x, q.y, q.z)
    }

    static func rotation(_ m: simd_float4x4) -> simd_float3x3 {
        simd_float3x3(
            SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
            SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
            SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        )
    }

    /// Occupied voxels → sum of the normals in them, every `stride`-th vertex.
    typealias Cells = [Int64: SIMD3<Float>]

    static func add(_ vertices: [SIMD3<Float>], _ normals: [SIMD3<Float>], to cells: inout Cells, stride: Int) {
        for i in Swift.stride(from: 0, to: min(vertices.count, normals.count), by: stride) {
            cells[key(cell(vertices[i])), default: SIMD3(0, 0, 0)] += normals[i]
        }
    }

    /// Live mesh at or next to `p` facing the same way as `n` (a thin wall's other face does not count).
    static func covered(_ p: SIMD3<Float>, _ n: SIMD3<Float>, _ cells: Cells) -> Bool {
        let c = cell(p)
        for dx in -1...1 {
            for dy in -1...1 {
                for dz in -1...1 {
                    if let sum = cells[key(c &+ SIMD3(Int64(dx), Int64(dy), Int64(dz)))], simd_dot(sum, n) > 0 {
                        return true
                    }
                }
            }
        }
        return false
    }

    /// Share of every `stride`-th vertex, moved by `m`, that live mesh covers (0 for no vertices).
    static func coveredShare(
        _ vertices: [SIMD3<Float>], _ normals: [SIMD3<Float>], _ m: simd_float4x4, _ cells: Cells, stride: Int
    ) -> Float {
        let r = rotation(m)
        var hit = 0
        var n = 0
        for i in Swift.stride(from: 0, to: min(vertices.count, normals.count), by: stride) {
            n += 1
            if covered(apply(m, vertices[i]), r * normals[i], cells) { hit += 1 }
        }
        return n == 0 ? 0 : Float(hit) / Float(n)
    }

    /// A kept piece moved by `m` (rigid), without the faces live mesh covers (2+ covered corners) and the
    /// vertices only those faces used. nil = fewer than `minFaces` faces left.
    static func place(
        vertices: [SIMD3<Float>], normals: [SIMD3<Float>], faces: [Face],
        m: simd_float4x4, cells: Cells, minFaces: Int
    ) -> (vertices: [SIMD3<Float>], normals: [SIMD3<Float>], faces: [Face])? {
        let r = rotation(m)
        let count = min(vertices.count, normals.count)
        let moved = (0..<count).map { apply(m, vertices[$0]) }
        let turned = (0..<count).map { r * normals[$0] }
        let hit = (0..<count).map { covered(moved[$0], turned[$0], cells) }
        var remap = [Int32](repeating: -1, count: count)
        var outV: [SIMD3<Float>] = []
        var outN: [SIMD3<Float>] = []
        var outF: [Face] = []
        func index(_ i: Int) -> UInt32 {
            if remap[i] < 0 {
                remap[i] = Int32(outV.count)
                outV.append(moved[i])
                outN.append(turned[i])
            }
            return UInt32(remap[i])
        }
        for (a, b, c) in faces {
            let ia = Int(a), ib = Int(b), ic = Int(c)
            guard ia < count, ib < count, ic < count else { continue }
            var corners = 0
            if hit[ia] { corners += 1 }
            if hit[ib] { corners += 1 }
            if hit[ic] { corners += 1 }
            guard corners < 2 else { continue }
            outF.append((index(ia), index(ib), index(ic)))
        }
        return outF.count >= minFaces ? (outV, outN, outF) : nil
    }

    /// Voxel coordinates, clamped to the 21-bit fields of `key` (±105 km at 10 cm).
    static func cell(_ p: SIMD3<Float>) -> SIMD3<Int64> {
        let limit: Float = 1_048_575
        func axis(_ v: Float) -> Int64 {
            let c = (v / voxel).rounded(.down)
            return c.isFinite ? Int64(min(max(c, -limit), limit)) : 0
        }
        return SIMD3(axis(p.x), axis(p.y), axis(p.z))
    }

    /// Exact packing (no hash): three signed 21-bit fields, as `ColorMeshBuilder.cellKey`.
    static func key(_ c: SIMD3<Int64>) -> Int64 {
        ((c.x & 0x1F_FFFF) << 42) | ((c.y & 0x1F_FFFF) << 21) | (c.z & 0x1F_FFFF)
    }
}
