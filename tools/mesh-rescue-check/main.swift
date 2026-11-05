// Checks Sources/Scan/MeshRescue.swift on synthetic walls and shots (CI, build.yml "Mesh rescue check"):
//   swiftc -O Sources/Scan/MeshRescue.swift tools/mesh-rescue-check/main.swift -o mrc && ./mrc
import Foundation
import simd

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print(ok ? "ok    \(what)" : "FAIL  \(what)")
    if !ok { failures += 1 }
}

func translation(_ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
    var m = matrix_identity_float4x4
    m.columns.3 = SIMD4(x, y, z, 1)
    return m
}

func rotationY(_ degrees: Float) -> simd_float4x4 {
    simd_float4x4(simd_quatf(angle: degrees * .pi / 180, axis: SIMD3(0, 1, 0)))
}

typealias Mesh = (vertices: [SIMD3<Float>], normals: [SIMD3<Float>], faces: [MeshRescue.Face])

/// Grid wall in the plane x = `x`, y 0…`height`, z `z0`…`z1`, spacing `step`, two triangles per cell,
/// facing +x (`facing` = 1) or -x (-1).
func wall(x: Float, z0: Float, z1: Float, facing: Float = 1, height: Float = 2.5, step: Float = 0.04) -> Mesh {
    let ny = Int((height / step).rounded()) + 1
    let nz = Int(((z1 - z0) / step).rounded()) + 1
    var v: [SIMD3<Float>] = []
    for iy in 0..<ny {
        for iz in 0..<nz {
            v.append(SIMD3(x, Float(iy) * step, z0 + Float(iz) * step))
        }
    }
    var f: [MeshRescue.Face] = []
    for iy in 0..<(ny - 1) {
        for iz in 0..<(nz - 1) {
            let a = UInt32(iy * nz + iz), b = a + 1, c = a + UInt32(nz), d = c + 1
            f.append((a, b, c))
            f.append((b, d, c))
        }
    }
    return (v, Array(repeating: SIMD3<Float>(facing, 0, 0), count: v.count), f)
}

func near(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ tol: Float = 1e-4) -> Bool { simd_distance(a, b) < tol }

func cells(_ meshes: [Mesh]) -> MeshRescue.Cells {
    var c = MeshRescue.Cells()
    for m in meshes { MeshRescue.add(m.vertices, m.normals, to: &c, stride: 2) }
    return c
}

// --- shots: A in the main map (never moves), B in a sub-map merged at t = 400, C refined by 6 cm
let firstA = translation(5.5, 0, 0)
let firstB = translation(5, 0, 0)
let merge = translation(0.02, 0.02, -0.26) * rotationY(3)
let shotA = MeshRescue.Shot(seenAt: 249, pose: firstA)
var shotB = MeshRescue.Shot(seenAt: 299, pose: firstB)
var shotB2 = MeshRescue.Shot(seenAt: 398, pose: translation(5.2, 0, 0))   // same sub-map, taken just before the merge
shotB2.update(merge * translation(5.2, 0, 0), at: 400)
shotB.update(translation(5.004, 0, 0), at: 350)              // < 1 cm: no history entry
check(shotB.poses.count == 1 && near(MeshRescue.position(shotB.now), SIMD3(5.004, 0, 0)), "sub-cm moves update now, not the history")
shotB.update(merge * firstB, at: 400)
check(shotB.poses.count == 2, "a merge adds a history entry")
check(near(MeshRescue.position(shotB.pose(at: 399)), MeshRescue.position(firstB)), "pose before the merge = capture pose")
check(near(MeshRescue.position(shotB.pose(at: 401)), MeshRescue.position(merge * firstB)), "pose after the merge = corrected pose")
var shotC = MeshRescue.Shot(seenAt: 499, pose: translation(-20, 0, 0))
shotC.update(translation(-20.06, 0, 0), at: 520)
let shots = [shotA, shotB, shotB2, shotC]
let c = SIMD3<Float>(6, 1, 0)

// --- correction: only a piece built in the sub-map, removed with the merge, comes back
if let m = MeshRescue.correction(builtFirst: 295, builtLast: 300, removedAt: 400.3, center: c, shots: shots) {
    check(near(MeshRescue.apply(m, c), MeshRescue.apply(merge, c)), "dropped at the merge: back by the sub-map's move")
} else {
    check(false, "dropped at the merge: qualifies")
}
check(MeshRescue.correction(builtFirst: 295, builtLast: 300, removedAt: 399, center: c, shots: shots) != nil,
      "removed up to 2 s before the merge still qualifies")
check(MeshRescue.correction(builtFirst: 295, builtLast: 300, removedAt: 395, center: c, shots: shots) == nil,
      "removed 5 s before the merge = ARKit's clean-up, not back")
check(MeshRescue.correction(builtFirst: 295, builtLast: 300, removedAt: 480, center: c, shots: shots) == nil,
      "removed long after the merge (kept, carved later) = not back")
check(MeshRescue.correction(builtFirst: 401, builtLast: 402, removedAt: 405, center: c, shots: shots) == nil,
      "built after the merge (already corrected) = not back")
check(MeshRescue.correction(builtFirst: 250, builtLast: 300, removedAt: 400.3, center: c, shots: shots) == nil,
      "built partly in the main map = not back")
check(MeshRescue.correction(builtFirst: 515, builtLast: 518, removedAt: 520.5, center: SIMD3(-21, 1, 0), shots: shots) == nil,
      "a 6 cm refinement = not back")
check(MeshRescue.correction(builtFirst: 295, builtLast: 300, removedAt: 400.3, center: SIMD3(30, 0, 0), shots: shots) == nil,
      "no shot within 8 m = not back")
if let s = MeshRescue.nearestShot(to: 300, center: c, shots: shots) {
    check(MeshRescue.movedAtRemoval(s, removedAt: 400.3, center: c), "movedAtRemoval sees the merge")
    check(!MeshRescue.movedAtRemoval(s, removedAt: 300, center: c), "movedAtRemoval is false without a move")
} else {
    check(false, "nearest shot found")
}

// --- coverage with normals: live wall at x = 0 facing +x, z 0…4 (and one at negative coordinates)
let live = wall(x: 0, z0: 0, z1: 4)
let liveNeg = wall(x: -5, z0: -4, z1: -1)
let liveCells = cells([live, liveNeg])
let plusX = SIMD3<Float>(1, 0, 0)
check(MeshRescue.covered(SIMD3(0.05, 1, 1), plusX, liveCells), "5 cm from live mesh, same facing = covered")
check(!MeshRescue.covered(SIMD3(0.05, 1, 1), -plusX, liveCells), "a thin wall's other face is not covered")
check(!MeshRescue.covered(SIMD3(0.35, 1, 1), plusX, liveCells), "35 cm from live mesh = not covered")
check(MeshRescue.covered(SIMD3(-5.03, 1, -2), plusX, liveCells), "negative coordinates are covered")
check(!MeshRescue.covered(SIMD3(-5.4, 1, -2), plusX, liveCells), "negative coordinates 40 cm away are not covered")
let shiftedWall = wall(x: 0.30, z0: 0, z1: 4)
check(MeshRescue.coveredShare(shiftedWall.vertices, shiftedWall.normals, translation(-0.30, 0, 0), liveCells, stride: 8) > 0.9,
      "the same wall once moved back counts as covered")
check(MeshRescue.coveredShare(shiftedWall.vertices, shiftedWall.normals, matrix_identity_float4x4, liveCells, stride: 8) < 0.1,
      "the same wall 30 cm away is not covered")

// --- place: cut what live mesh covers, keep the rest, move rigidly, compact
let onLive = wall(x: 0.04, z0: 1, z1: 3)
check(MeshRescue.place(vertices: onLive.vertices, normals: onLive.normals, faces: onLive.faces,
                       m: matrix_identity_float4x4, cells: liveCells, minFaces: 20) == nil,
      "a piece lying on live mesh is cut away entirely")
let backFace = wall(x: -0.10, z0: 1, z1: 3, facing: -1)
if let p = MeshRescue.place(vertices: backFace.vertices, normals: backFace.normals, faces: backFace.faces,
                            m: matrix_identity_float4x4, cells: liveCells, minFaces: 20) {
    check(p.faces.count == backFace.faces.count, "the other face of a 10 cm wall is kept whole")
} else {
    check(false, "the other face of a 10 cm wall is kept")
}
let away = wall(x: 3, z0: 0, z1: 2)
let turn = translation(0.1, 0, -0.2) * rotationY(90)
if let p = MeshRescue.place(vertices: away.vertices, normals: away.normals, faces: away.faces,
                            m: turn, cells: liveCells, minFaces: 20) {
    check(p.faces.count == away.faces.count && p.vertices.count == away.vertices.count, "a piece in empty space is kept whole")
    check(near(p.vertices[0], MeshRescue.apply(turn, away.vertices[0])), "kept vertices are moved by the correction")
    check(near(p.normals[0], SIMD3(0, 0, -1)), "normals are rotated, not translated")
    var withKept = liveCells
    MeshRescue.add(p.vertices, p.normals, to: &withKept, stride: 2)
    check(MeshRescue.place(vertices: away.vertices, normals: away.normals, faces: away.faces,
                           m: turn, cells: withKept, minFaces: 20) == nil,
          "a second copy of a piece already put back is cut away")
} else {
    check(false, "a piece in empty space is kept")
}
let half = wall(x: 0.02, z0: 3, z1: 6)
if let p = MeshRescue.place(vertices: half.vertices, normals: half.normals, faces: half.faces,
                            m: matrix_identity_float4x4, cells: liveCells, minFaces: 20) {
    check(p.faces.count > 0 && p.faces.count < half.faces.count, "a half-covered piece keeps only its uncovered part")
    var used = Array(repeating: false, count: p.vertices.count)
    var badFace = false
    for (a, b, c) in p.faces {
        for i in [a, b, c] {
            guard Int(i) < p.vertices.count else { badFace = true; continue }
            used[Int(i)] = true
        }
        var corners = 0
        for i in [a, b, c] where Int(i) < p.vertices.count && MeshRescue.covered(p.vertices[Int(i)], p.normals[Int(i)], liveCells) {
            corners += 1
        }
        if corners >= 2 { badFace = true }
    }
    check(!badFace, "no kept face has 2+ covered corners; indices in range")
    check(!used.contains(false), "no unused vertex left after compaction")
    check(p.vertices.allSatisfy { $0.z > 3.9 }, "kept part lies beyond the live wall's end")
} else {
    check(false, "a half-covered piece is kept in part")
}

print(failures == 0 ? "mesh rescue check: all passed" : "mesh rescue check: \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
