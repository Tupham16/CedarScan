import simd

/// Geometry of the mesh rescue (05/11, #LS-MW30FJAA2, owner board item A). When ARKit merges a sub-map
/// back into the main map it moves plain anchors but never mesh, and on a big merge it can drop the
/// sub-map's mesh altogether (§TRAPS #57). `ColorMeshBuilder` keeps what ARKit removes; these rules pick
/// the pieces that went with such a merge and put back what ARKit emptied, where the corrected map has it.
/// No ARKit or app types here: `tools/mesh-rescue-check` compiles this file alone in CI.
enum MeshRescue {
    typealias Face = (UInt32, UInt32, UInt32)

    struct Piece {
        var vertices: [SIMD3<Float>]
        var normals: [SIMD3<Float>]
        var faces: [Face]
    }

    /// A texture-shot anchor (`TextureShotRecorder.anchorName`): first seen at `seenAt` (pose = capture
    /// pose `m` in shots.json); `poses` = its pose after each move of ≥ 1 cm / ~0.3°, `now` = latest.
    struct Shot {
        let seenAt: Double
        private(set) var poses: [(t: Double, m: simd_float4x4)]
        private(set) var now: simd_float4x4
        /// Real map corrections are a handful per scan; past this the last entry is replaced.
        static let maxPoses = 64

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
            guard simd_distance(MeshRescue.position(last), MeshRescue.position(m)) >= 0.01 || turned >= 0.01 else { return }
            if poses.count >= Self.maxPoses { poses.removeLast() }
            poses.append((t: t, m: m))
        }

        /// Pose at time `t` (the first pose before `seenAt`).
        func pose(at t: Double) -> simd_float4x4 {
            var p = poses[0].m
            for entry in poses where entry.t <= t { p = entry.m }
            return p
        }
    }

    /// How long before / after its removal a piece's sub-map must have moved (server-tunable,
    /// ScanQualityConfig `meshRescueBeforeSec` / `meshRescueAfterSec`): the removal went with that
    /// correction, not with ARKit's own clean-up (a replaced chunk, carved noise).
    struct Window {
        var before: Double
        var after: Double
        static let standard = Window(before: 10, after: 2)
    }

    /// Coverage voxel. With the 27-cell neighbourhood, live mesh within ~10–20 cm and facing within 60°
    /// covers a point (the correction landed 4–8 cm from re-scanned mesh on 05/11).
    static let voxel: Float = 0.10
    /// A shot further than this in time or space from a piece says nothing about the piece's sub-map.
    static let maxShotGap: Double = 20
    static let maxShotDistance: Float = 8
    /// The piece's sub-map moved at least this since the piece was built (ordinary map refinement moves
    /// shots 0–7 cm; the 05/11 merge 26–51 cm; merges that kept their mesh 10–24 cm)…
    static let minShift: Float = 0.15
    /// …and at least this inside the window around the piece's removal.
    static let minEventShift: Float = 0.10
    /// The shots nearest the piece's first and last update agree on its correction within this: it lived
    /// in one sub-map (a piece built partly in correct coordinates differs by ≥ `minShift`).
    static let sameSubMap: Float = 0.10
    /// Whole piece skipped when live mesh covers more of it than this where it sat (ARKit replaced it
    /// there) or a piece already put back covers more of it after the move (a duplicate).
    static let maxCovered: Float = 0.5
    /// Below this many qualifying vertices in all, nothing goes back: a drop takes whole rooms (05/11:
    /// hundreds of thousands); a person or a door carved at the moment of a merge is a few thousand.
    static let minEventVertices = 20_000

    /// The shot nearest in time to `t` within `maxShotGap` s and `maxShotDistance` m of `center`, preferring
    /// one first seen at or before `t` (a shot first seen after a merge has no history before it).
    static func nearestShot(to t: Double, center: SIMD3<Float>, shots: [Shot]) -> Shot? {
        var before: Shot?
        var after: Shot?
        for s in shots where abs(s.seenAt - t) <= maxShotGap
            && simd_distance(position(s.poses[0].m), center) <= maxShotDistance {
            if s.seenAt <= t {
                if before.map({ s.seenAt > $0.seenAt }) ?? true { before = s }
            } else if after.map({ s.seenAt < $0.seenAt }) ?? true {
                after = s
            }
        }
        return before ?? after
    }

    /// Did the piece's sub-map move around the piece's removal? Final once `removedAt + window.after` has
    /// passed.
    static func movedAtRemoval(_ s: Shot, removedAt: Double, center: SIMD3<Float>, window: Window) -> Bool {
        let move = s.pose(at: removedAt + window.after) * s.pose(at: removedAt - window.before).inverse
        return shift(move, at: center) >= minEventShift
    }

    /// Correction to put a removed piece back, or nil when it does not qualify (see the constants above).
    /// ARKit moves a whole sub-map rigidly (05/11: one transform for every shot of 348–507 s), so the move
    /// of the shot nearest the piece's last update since that update is the piece's.
    static func correction(
        builtFirst: Double, builtLast: Double, removedAt: Double, center: SIMD3<Float>, shots: [Shot],
        window: Window
    ) -> simd_float4x4? {
        guard let s = nearestShot(to: builtLast, center: center, shots: shots),
              let s0 = nearestShot(to: builtFirst, center: center, shots: shots) else { return nil }
        let m = s.now * s.pose(at: builtLast).inverse
        let m0 = s0.now * s0.pose(at: builtFirst).inverse
        guard shift(m, at: center) >= minShift,
              movedAtRemoval(s, removedAt: removedAt, center: center, window: window),
              simd_distance(apply(m, center), apply(m0, center)) <= sameSubMap else { return nil }
        return m
    }

    struct Job {
        let piece: Piece
        let m: simd_float4x4
        /// Correction at the piece's centre, metres.
        let shift: Float
    }

    struct Outcome {
        /// Index into the jobs → the piece to add to the model.
        var placed: [(job: Int, piece: Piece)] = []
        /// Vertices not put back: qualifying total under `minEventVertices` · live mesh where the whole
        /// piece sat · a piece already put back covers it · cut away (live mesh where a vertex sat or goes,
        /// or < `minFaces` faces left) · vertex cap.
        var smallEvent = 0
        var inPlace = 0
        var duplicate = 0
        var cut = 0
        var capped = 0
        /// Largest correction of a piece put back, metres.
        var maxShift: Float = 0
    }

    /// The Stop-time pass: largest first, each qualifying piece is skipped when ARKit replaced it in place
    /// or a piece already put back duplicates it, else moved and cut to what ARKit emptied (no live mesh
    /// where a vertex sat, none where it goes), within `room` vertices. Pieces put back never trim each
    /// other (a drop is many neighbouring chunks: trimming would crack every seam).
    static func putBack(_ jobs: [Job], live: [Piece], room: Int, minFaces: Int = 20) -> Outcome {
        var out = Outcome()
        let total = jobs.reduce(0) { $0 + $1.piece.vertices.count }
        guard total >= minEventVertices else {
            out.smallEvent = total
            return out
        }
        var liveCells = Cells()
        for p in live { add(p.vertices, p.normals, to: &liveCells, stride: 2) }
        var rescuedCells = Cells()
        var used = 0
        let order = jobs.indices.sorted { jobs[$0].piece.vertices.count > jobs[$1].piece.vertices.count }
        for i in order {
            let job = jobs[i]
            let v = job.piece.vertices
            let n = job.piece.normals
            if coveredShare(v, n, matrix_identity_float4x4, liveCells, stride: 4) > maxCovered {
                out.inPlace += v.count
                continue
            }
            if coveredShare(v, n, job.m, rescuedCells, stride: 4) > maxCovered {
                out.duplicate += v.count
                continue
            }
            guard let p = place(job.piece, m: job.m, cells: liveCells, minFaces: minFaces) else {
                out.cut += v.count
                continue
            }
            out.cut += v.count - p.vertices.count
            guard used + p.vertices.count <= room else {
                out.capped += p.vertices.count
                continue
            }
            used += p.vertices.count
            out.maxShift = max(out.maxShift, job.shift)
            add(p.vertices, p.normals, to: &rescuedCells, stride: 2)
            out.placed.append((job: i, piece: p))
        }
        return out
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

    /// Occupied voxels → sum of the normals in them.
    typealias Cells = [Int64: SIMD3<Float>]

    /// Adds every `stride`-th vertex.
    static func add(_ vertices: [SIMD3<Float>], _ normals: [SIMD3<Float>], to cells: inout Cells, stride: Int) {
        for i in Swift.stride(from: 0, to: min(vertices.count, normals.count), by: stride) {
            cells[key(cell(vertices[i])), default: SIMD3(0, 0, 0)] += normals[i]
        }
    }

    /// Mesh at or next to `p` facing within ~60° of `n` (a thin wall's other face, or the floor under a
    /// wall, does not count).
    static func covered(_ p: SIMD3<Float>, _ n: SIMD3<Float>, _ cells: Cells) -> Bool {
        let c = cell(p)
        for dx in -1...1 {
            for dy in -1...1 {
                for dz in -1...1 {
                    if let sum = cells[key(c &+ SIMD3(Int64(dx), Int64(dy), Int64(dz)))],
                       simd_dot(sum, n) > 0.5 * simd_length(sum) {
                        return true
                    }
                }
            }
        }
        return false
    }

    /// Share of every `stride`-th vertex, moved by `m`, that `cells` cover (0 for no vertices).
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

    /// `piece` moved by `m` (rigid), keeping only what `cells` cover neither where it sat nor where it
    /// goes: faces with 2+ covered corners and the vertices only those faces used are dropped. nil =
    /// fewer than `minFaces` faces left.
    static func place(_ piece: Piece, m: simd_float4x4, cells: Cells, minFaces: Int) -> Piece? {
        let r = rotation(m)
        let count = min(piece.vertices.count, piece.normals.count)
        let moved = (0..<count).map { apply(m, piece.vertices[$0]) }
        let turned = (0..<count).map { r * piece.normals[$0] }
        let hit = (0..<count).map {
            covered(piece.vertices[$0], piece.normals[$0], cells) || covered(moved[$0], turned[$0], cells)
        }
        var remap = [Int32](repeating: -1, count: count)
        var out = Piece(vertices: [], normals: [], faces: [])
        func index(_ i: Int) -> UInt32 {
            if remap[i] < 0 {
                remap[i] = Int32(out.vertices.count)
                out.vertices.append(moved[i])
                out.normals.append(turned[i])
            }
            return UInt32(remap[i])
        }
        for (a, b, c) in piece.faces {
            let ia = Int(a), ib = Int(b), ic = Int(c)
            guard ia < count, ib < count, ic < count else { continue }
            var corners = 0
            if hit[ia] { corners += 1 }
            if hit[ib] { corners += 1 }
            if hit[ic] { corners += 1 }
            guard corners < 2 else { continue }
            out.faces.append((index(ia), index(ib), index(ic)))
        }
        return out.faces.count >= minFaces ? out : nil
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
