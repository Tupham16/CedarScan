import Foundation
import simd
import CMeshOptimizer

/// Grey 3D preview (`mesh-preview.bin`) by QUADRIC EDGE COLLAPSE — meshoptimizer 1.3, vendored in
/// `Packages/MeshOptimizer`. Main path since 2.75; `ColorMeshBuilder.clusterPreview` is only the
/// fallback when this returns nil (owner 30/09, SESSION-HANDOFF §STATE "GREY 3D PREVIEW HOLES").
///
/// Why clustering had to go: a voxel weld merges the two faces of any wall thinner than the voxel
/// into one sheet carrying triangles of BOTH windings and flips small triangles; with `.back`
/// culling (`MeshPreviewView.sharedCullMode`) those walls read as torn and holed. An edge collapse
/// only merges vertices joined by an edge, so the two faces of a partition stay two surfaces.
/// Measured offline on three owner scans (1.55M / 1.10M / 0.46M vertices, extra see-through area
/// vs the full mesh, top / 30° views): clustering 4.5/3.0 · 4.1/3.4 · 2.4/1.9 points → this
/// 0.6/0.4 · 0.4/0.3 · 0.1/0.0.
///
/// 🔴 `scratch_mesh-holes/mirror2.py` (root checkout) repeats these steps in the same order with the
/// same library calls, so it feeds meshoptimizer the same bytes as the app does — that is how the
/// numbers above were measured. Change a step here ⇒ change it there and re-measure.
///  1. WELD on the 0.1 mm grid of the delivery OBJ (`ColoredOBJExporter` writes 4 decimals with the
///     same `.rounded()`). ARKit anchors repeat their seam vertices; unwelded, every seam is two
///     touching borders that simplify separately and open into cracks.
///  2. STAGE A per 4 m cell, vertices shared by two cells locked, each cell cut to twice the
///     final share. One call on the whole house peaks at ~260 MB inside meshoptimizer (1.55M
///     vertices); cells keep it at ~15 MB, and stage B then works on ~0.2M vertices (~35 MB).
///  3. STAGE B on the whole stage-A mesh, target moved until the vertex count lands in
///     [0.9, 1] × budget (≤ 3 passes; a pathological mesh may stay above it — soft budget).
///  4. Normals from the result's own faces (area-weighted).
/// Positions are never moved: every output vertex is a welded input vertex (≤ 0.05 mm off).
///
/// Runs on `ColorMeshBuilder.queue` (background), AFTER `exportColoredPLY` — see `exportPreviewMesh`.
enum PreviewSimplifier {
    struct Result {
        let positions: [SIMD3<Float>]
        let normals: [SIMD3<Float>]
        let indices: [UInt32]
    }

    /// 10 000 steps per metre = the 4 decimals `ColoredOBJExporter.appendFixed` writes, same rounding.
    private static let gridPerMetre: Double = 10_000
    /// Farther than this from the scan origin = garbage vertex, dropped with its faces. Also keeps
    /// two grid points from rounding to one Float (Float spacing reaches 0.1 mm near 800 m): equal
    /// positions would reach meshoptimizer as attribute seams, a path this caller never exercises.
    private static let maxCoordinate: Float = 500
    /// Stage A cell edge (metres). ARKit anchors are ~2 m chunks, a cell holds ≤ ~0.2M triangles
    /// on the measured houses.
    private static let cellSize: Float = 4
    /// Vertices per triangle of the simplified result, measured 0.63–0.69 on the three scans
    /// (plenty of open borders) — sizes the first stage-B target.
    private static let firstVertexPerTriangle: Double = 0.7
    /// Stage A keeps this many times the first stage-B target, so stage B still chooses globally
    /// where detail goes (offline: 2× and 3× gave the same holes, 2× less RAM).
    private static let stageASlack: Double = 2
    private static let maxPasses = 3
    /// Input guard, far above the 2M `wholeHomePreset` cap: every index here is a UInt32.
    private static let maxInputVertices = 50_000_000

    /// `vertexLists[k]` / `faceLists[k]` = one ARKit anchor piece, in `buildPreview`'s sorted-key
    /// order (the order of model.obj). nil = could not build; the caller falls back to clustering.
    static func build(
        vertexLists: [[SIMD3<Float>]],
        faceLists: [[(UInt32, UInt32, UInt32)]],
        budget: Int
    ) -> Result? {
        guard budget > 0, vertexLists.count == faceLists.count else { return nil }
        var total = 0
        for list in vertexLists { total += list.count }
        guard total > 0, total <= maxInputVertices else { return nil }

        // 1. Quantise, then weld identical grid points (the library hashes the 12 grid bytes).
        //    Invalid vertices all get one sentinel point that no kept face references.
        var grid = [Int32](repeating: .min, count: total * 3)
        var valid = [Bool](repeating: false, count: total)
        var n = 0
        for list in vertexLists {
            for p in list {
                if p.x.isFinite, p.y.isFinite, p.z.isFinite,
                   abs(p.x) <= maxCoordinate, abs(p.y) <= maxCoordinate, abs(p.z) <= maxCoordinate {
                    grid[n * 3] = Int32((Double(p.x) * gridPerMetre).rounded())
                    grid[n * 3 + 1] = Int32((Double(p.y) * gridPerMetre).rounded())
                    grid[n * 3 + 2] = Int32((Double(p.z) * gridPerMetre).rounded())
                    valid[n] = true
                }
                n += 1
            }
        }
        var remap = [UInt32](repeating: 0, count: total)
        let welded = grid.withUnsafeBytes { gb in
            remap.withUnsafeMutableBufferPointer { rb in
                meshopt_generateVertexRemap(rb.baseAddress, nil, total, gb.baseAddress, total, 12)
            }
        }
        guard welded > 0, welded <= total else { return nil }
        var positions = [Float](repeating: 0, count: welded * 3)
        for i in 0..<total {
            let o = Int(remap[i]) * 3
            positions[o] = Float(Double(grid[i * 3]) / gridPerMetre)
            positions[o + 1] = Float(Double(grid[i * 3 + 1]) / gridPerMetre)
            positions[o + 2] = Float(Double(grid[i * 3 + 2]) / gridPerMetre)
        }
        grid = []

        // 2. Stage A cells: each welded vertex's 4 m cell, block ids in first-seen vertex order.
        var vertexBlock = [Int32](repeating: 0, count: welded)
        var blockCount = 0
        do {
            var blockOfCell = [Int64: Int32]()
            var lastKey = Int64.min
            var lastBlock: Int32 = 0
            for v in 0..<welded {
                let key = cellKey(positions[v * 3], positions[v * 3 + 1], positions[v * 3 + 2])
                if key != lastKey {
                    if let known = blockOfCell[key] {
                        lastBlock = known
                    } else {
                        lastBlock = Int32(blockOfCell.count)
                        blockOfCell[key] = lastBlock
                    }
                    lastKey = key
                }
                vertexBlock[v] = lastBlock
            }
            blockCount = blockOfCell.count
        }

        // 3. Faces (welded, degenerate and invalid dropped): a face belongs to the cell of its
        //    FIRST corner; a vertex used by faces of two cells is locked in stage A.
        var faceCount = [Int](repeating: 0, count: blockCount)
        var owner = [Int32](repeating: -1, count: welded)
        var lock = [UInt8](repeating: 0, count: welded)
        let lockFlag = UInt8(meshopt_SimplifyVertex_Lock)
        var totalTris = 0
        var usedVerts = 0
        func claim(_ v: Int, _ block: Int32) {
            if owner[v] < 0 {
                owner[v] = block
                usedVerts += 1
            } else if owner[v] != block {
                lock[v] = lockFlag
            }
        }
        forEachFace(faceLists, vertexLists, valid, remap) { a, b, c in
            let block = vertexBlock[Int(a)]
            faceCount[Int(block)] += 1
            totalTris += 1
            claim(Int(a), block)
            claim(Int(b), block)
            claim(Int(c), block)
        }
        owner = []
        guard totalTris > 0 else { return nil }
        let firstTarget = min(totalTris, Int(Double(budget) / firstVertexPerTriangle))
        let staged = usedVerts > budget && totalTris > Int(Double(firstTarget) * stageASlack)

        // Index buffer in cell order when staged (stable: piece order inside a cell), else piece order.
        var starts = [Int](repeating: 0, count: staged ? blockCount : 1)
        if staged {
            var sum = 0
            for block in 0..<blockCount {
                starts[block] = sum
                sum += faceCount[block]
            }
        }
        var indices = [UInt32](repeating: 0, count: totalTris * 3)
        do {
            var cursor = starts
            forEachFace(faceLists, vertexLists, valid, remap) { a, b, c in
                let block = staged ? Int(vertexBlock[Int(a)]) : 0
                let o = cursor[block] * 3
                indices[o] = a
                indices[o + 1] = b
                indices[o + 2] = c
                cursor[block] += 1
            }
        }
        remap = []
        valid = []
        vertexBlock = []

        // Small scan: already inside the budget, keep every welded triangle.
        if usedVerts <= budget {
            guard let whole = compact(positions: positions, vertexCount: welded,
                                      indices: indices, indexCount: indices.count)
            else { return nil }
            return finish(whole.positions, whole.indices)
        }

        // 4. Stage A → the mesh stage B starts from.
        let stage: (positions: [Float], indices: [UInt32])
        if staged {
            let ratio = min(1.0, stageASlack * Double(firstTarget) / Double(totalTris))
            var largest = 0
            for count in faceCount { largest = max(largest, count) }
            var scratch = [UInt32](repeating: 0, count: largest * 3)
            var kept = [UInt32]()
            kept.reserveCapacity(min(indices.count, Int(Double(indices.count) * ratio) + 3 * blockCount + 3))
            let options = UInt32(meshopt_SimplifySparse) | UInt32(meshopt_SimplifyErrorAbsolute)
            for block in 0..<blockCount where faceCount[block] > 0 {
                let start = starts[block] * 3
                let count = faceCount[block] * 3
                let target = Int(Double(faceCount[block]) * ratio) * 3
                let written = indices.withUnsafeBufferPointer { ib in
                    positions.withUnsafeBufferPointer { pb in
                        lock.withUnsafeBufferPointer { lb in
                            scratch.withUnsafeMutableBufferPointer { sb in
                                meshopt_simplifyWithAttributes(
                                    sb.baseAddress, ib.baseAddress! + start, count,
                                    pb.baseAddress, welded, 12,
                                    nil, 0, nil, 0, lb.baseAddress,
                                    target, Float.greatestFiniteMagnitude, options, nil
                                )
                            }
                        }
                    }
                }
                guard written >= 0, written <= count, written % 3 == 0 else { return nil }
                kept.append(contentsOf: scratch[0..<written])
            }
            scratch = []
            indices = []
            lock = []
            guard let built = compact(positions: positions, vertexCount: welded,
                                      indices: kept, indexCount: kept.count)
            else { return nil }
            stage = built
        } else {
            lock = []
            guard let built = compact(positions: positions, vertexCount: welded,
                                      indices: indices, indexCount: indices.count)
            else { return nil }
            stage = built
            indices = []
        }
        positions = []

        // 5. Stage B: move the target until the result lands in [0.9, 1] × budget. Best = the
        //    largest result inside the budget, else the smallest one above it.
        let stageVerts = stage.positions.count / 3
        let stageTris = stage.indices.count / 3
        guard stageTris > 0 else { return nil }
        var target = min(stageTris, firstTarget)
        var out = [UInt32](repeating: 0, count: stage.indices.count)
        var best: (positions: [Float], indices: [UInt32])?
        var bestVerts = 0
        let options = UInt32(meshopt_SimplifyErrorAbsolute)
        for _ in 0..<maxPasses {
            let written = stage.indices.withUnsafeBufferPointer { ib in
                stage.positions.withUnsafeBufferPointer { pb in
                    out.withUnsafeMutableBufferPointer { ob in
                        meshopt_simplify(
                            ob.baseAddress, ib.baseAddress, stageTris * 3,
                            pb.baseAddress, stageVerts, 12,
                            target * 3, Float.greatestFiniteMagnitude, options, nil
                        )
                    }
                }
            }
            guard written > 0, written <= stageTris * 3, written % 3 == 0,
                  let result = compact(positions: stage.positions, vertexCount: stageVerts,
                                       indices: out, indexCount: written)
            else { return nil }
            let verts = result.positions.count / 3
            let tris = written / 3
            let better: Bool
            if best == nil {
                better = true
            } else if verts <= budget {
                better = bestVerts > budget || verts > bestVerts
            } else {
                better = bestVerts > budget && verts < bestVerts
            }
            if better {
                best = result
                bestVerts = verts
            }
            if verts <= budget && (verts * 10 >= budget * 9 || target >= stageTris) { break }
            // Vertices shrink slower than triangles as the mesh coarsens (more border per
            // triangle), hence the 1.25 power; r·√√r keeps it to IEEE-exact operations so the
            // Windows harness computes the same integer.
            let r = Double(budget) / Double(verts)
            let scale = min(1.3, r * r.squareRoot().squareRoot())
            target = max(1, min(stageTris, Int(Double(tris) * scale * 0.99)))
        }
        guard let chosen = best else { return nil }
        return finish(chosen.positions, chosen.indices)
    }

    /// Calls `body` with the WELDED corners of every kept face, pieces in order.
    private static func forEachFace(
        _ faceLists: [[(UInt32, UInt32, UInt32)]],
        _ vertexLists: [[SIMD3<Float>]],
        _ valid: [Bool],
        _ remap: [UInt32],
        _ body: (UInt32, UInt32, UInt32) -> Void
    ) {
        var base = 0
        for k in faceLists.indices {
            let count = vertexLists[k].count
            for f in faceLists[k] {
                let a = Int(f.0), b = Int(f.1), c = Int(f.2)
                // ARKit index buffers have handed this app garbage before — see the same guard in
                // `ColorMeshBuilder.subdivideLargeTriangles`.
                guard a < count, b < count, c < count else { continue }
                guard valid[base + a], valid[base + b], valid[base + c] else { continue }
                let ra = remap[base + a], rb = remap[base + b], rc = remap[base + c]
                guard ra != rb, rb != rc, ra != rc else { continue }
                body(ra, rb, rc)
            }
            base += count
        }
    }

    /// Exact 4 m cell of a point — ✗ a hash (a collision would weld two far cells into one
    /// block, harmless here but a pain to reason about). Coordinates are within ±500 m (or the
    /// invalid sentinel), so every field stays far inside its 21 bits.
    private static func cellKey(_ x: Float, _ y: Float, _ z: Float) -> Int64 {
        let cx = Int64((x / cellSize).rounded(.down)) + (1 << 20)
        let cy = Int64((y / cellSize).rounded(.down)) + (1 << 20)
        let cz = Int64((z / cellSize).rounded(.down)) + (1 << 20)
        return (cx << 42) | (cy << 21) | cz
    }

    /// Keeps only the vertices `indices[0..<indexCount]` use, renumbered in first-use order.
    private static func compact(
        positions: [Float], vertexCount: Int, indices: [UInt32], indexCount: Int
    ) -> (positions: [Float], indices: [UInt32])? {
        guard indexCount > 0, indexCount <= indices.count, positions.count == vertexCount * 3 else {
            return nil
        }
        var remap = [UInt32](repeating: 0, count: vertexCount)
        let used = indices.withUnsafeBufferPointer { ib in
            remap.withUnsafeMutableBufferPointer { rb in
                meshopt_optimizeVertexFetchRemap(rb.baseAddress, ib.baseAddress, indexCount, vertexCount)
            }
        }
        guard used > 0, used <= vertexCount else { return nil }
        var outPositions = [Float](repeating: 0, count: used * 3)
        for v in 0..<vertexCount where remap[v] != .max {
            let o = Int(remap[v]) * 3
            outPositions[o] = positions[v * 3]
            outPositions[o + 1] = positions[v * 3 + 1]
            outPositions[o + 2] = positions[v * 3 + 2]
        }
        var outIndices = [UInt32](repeating: 0, count: indexCount)
        for i in 0..<indexCount {
            outIndices[i] = remap[Int(indices[i])]
        }
        return (outPositions, outIndices)
    }

    /// Packs the result and gives every vertex the area-weighted normal of its faces (winding =
    /// ARKit's, so these point the same way as the scan's own normals — into the rooms).
    private static func finish(_ flat: [Float], _ indices: [UInt32]) -> Result? {
        let count = flat.count / 3
        guard count > 0, !indices.isEmpty, indices.count % 3 == 0 else { return nil }
        var positions = [SIMD3<Float>]()
        positions.reserveCapacity(count)
        for v in 0..<count {
            positions.append(SIMD3(flat[v * 3], flat[v * 3 + 1], flat[v * 3 + 2]))
        }
        var normals = [SIMD3<Float>](repeating: .zero, count: count)
        var i = 0
        while i + 2 < indices.count {
            let a = Int(indices[i]), b = Int(indices[i + 1]), c = Int(indices[i + 2])
            let n = simd_cross(positions[b] - positions[a], positions[c] - positions[a])
            normals[a] += n
            normals[b] += n
            normals[c] += n
            i += 3
        }
        for v in 0..<count {
            let len = simd_length(normals[v])
            // Only sliver-only vertices land here; a zero normal would shade pure black.
            normals[v] = len > 1e-12 && len.isFinite ? normals[v] / len : SIMD3<Float>(0, 1, 0)
        }
        return Result(positions: positions, normals: normals, indices: indices)
    }
}
