import simd

/// Geometry of the mesh rescue (05/11, #LS-MW30FJAA2, owner board item A). When ARKit merges a sub-map
/// back into the main map it moves plain anchors but never mesh, and on a big merge it can drop the
/// sub-map's mesh altogether (§TRAPS #57). `ColorMeshBuilder` keeps what ARKit removes; at Stop these
/// functions move each kept piece by its sub-map's correction and cut what live mesh already covers.
/// No ARKit or app types here: `tools/mesh-rescue-check` compiles this file alone in CI.
enum MeshRescue {
    /// A texture-shot anchor (`TextureShotRecorder.anchorName`): its pose when the builder first saw it
    /// (= capture pose `m` in shots.json) and its pose now (`m2` once the scan stops).
    struct Shot {
        let seenAt: Double
        let first: simd_float4x4
        var now: simd_float4x4
    }

    typealias Face = (UInt32, UInt32, UInt32)

    /// Coverage voxel. With the 27-cell neighbourhood, live mesh within ~10–20 cm covers a point (the
    /// correction landed 4–8 cm from re-scanned mesh on 05/11).
    static let voxel: Float = 0.10
    /// A shot further than this in time or space from a piece says nothing about the piece's sub-map.
    static let maxShotGap: Double = 20
    static let maxShotDistance: Float = 8
    /// Below this the piece's sub-map was not corrected: ARKit removed it for its own reasons (a chunk
    /// merge, carved noise) and it stays dropped, as before the rescue. On 05/11 the merge moved 26–51 cm;
    /// ordinary map refinement moves shots 0–7 cm.
    static let minShift: Float = 0.05
    /// A kept piece this covered by live mesh is a replaced chunk: drop it.
    static let coveredToDrop: Float = 0.9

    /// Correction ARKit has applied since a piece was built: the move of the shot first seen nearest in
    /// time to the piece's last update. ARKit moves a whole sub-map rigidly (05/11: one transform for every
    /// shot of 348–507 s), so that shot's move is the piece's. nil = no shot within `maxShotGap` s and
    /// `maxShotDistance` m.
    static func correction(builtAt: Double, center: SIMD3<Float>, shots: [Shot]) -> simd_float4x4? {
        var best: Shot?
        var bestGap = maxShotGap
        for s in shots {
            let gap = abs(s.seenAt - builtAt)
            guard gap <= bestGap, simd_distance(position(s.first), center) <= maxShotDistance else { continue }
            best = s
            bestGap = gap
        }
        guard let s = best else { return nil }
        return s.now * s.first.inverse
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

    /// Occupied voxels of `meshes`, every `stride`-th vertex.
    static func cells(_ meshes: [[SIMD3<Float>]], stride: Int) -> Set<Int64> {
        var out = Set<Int64>()
        for vertices in meshes {
            for i in Swift.stride(from: 0, to: vertices.count, by: stride) {
                out.insert(key(cell(vertices[i])))
            }
        }
        return out
    }

    /// An occupied voxel at `p` or next to it.
    static func covered(_ p: SIMD3<Float>, _ cells: Set<Int64>) -> Bool {
        let c = cell(p)
        for dx in -1...1 {
            for dy in -1...1 {
                for dz in -1...1 where cells.contains(key(c &+ SIMD3(Int64(dx), Int64(dy), Int64(dz)))) {
                    return true
                }
            }
        }
        return false
    }

    /// Share of every `stride`-th vertex, moved by `m`, that live mesh covers (0 for no vertices).
    static func coveredShare(_ vertices: [SIMD3<Float>], _ m: simd_float4x4, _ cells: Set<Int64>, stride: Int) -> Float {
        var hit = 0
        var n = 0
        for i in Swift.stride(from: 0, to: vertices.count, by: stride) {
            n += 1
            if covered(apply(m, vertices[i]), cells) { hit += 1 }
        }
        return n == 0 ? 0 : Float(hit) / Float(n)
    }

    /// A kept piece moved by `m` (rigid), without the faces live mesh covers (2+ covered corners) and the
    /// vertices only those faces used. nil = fewer than `minFaces` faces left.
    static func place(
        vertices: [SIMD3<Float>], normals: [SIMD3<Float>], faces: [Face],
        m: simd_float4x4, cells: Set<Int64>, minFaces: Int
    ) -> (vertices: [SIMD3<Float>], normals: [SIMD3<Float>], faces: [Face])? {
        let r = simd_float3x3(
            SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
            SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
            SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        )
        let moved = vertices.map { apply(m, $0) }
        let hit = moved.map { covered($0, cells) }
        var remap = [Int32](repeating: -1, count: moved.count)
        var outV: [SIMD3<Float>] = []
        var outN: [SIMD3<Float>] = []
        var outF: [Face] = []
        func index(_ i: Int) -> UInt32 {
            if remap[i] < 0 {
                remap[i] = Int32(outV.count)
                outV.append(moved[i])
                outN.append(i < normals.count ? r * normals[i] : SIMD3(0, 1, 0))
            }
            return UInt32(remap[i])
        }
        for (a, b, c) in faces {
            let ia = Int(a), ib = Int(b), ic = Int(c)
            guard ia < moved.count, ib < moved.count, ic < moved.count else { continue }
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
